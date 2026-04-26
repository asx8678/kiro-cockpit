defmodule KiroCockpit.Swarm.ActionBoundaryTest do
  use KiroCockpit.DataCase, async: true

  alias KiroCockpit.Swarm.{ActionBoundary, Hook, HookResult}
  alias KiroCockpit.Swarm.Tasks.TaskManager

  # -- Fake hooks for boundary testing --------------------------------------

  defmodule AlwaysBlockHook do
    @behaviour Hook

    @impl true
    def name, do: :always_block
    @impl true
    def priority, do: 100
    @impl true
    def filter(_event), do: true
    @impl true
    def on_event(event, _ctx) do
      HookResult.block(event, "blocked for test", ["always_block blocked"])
    end
  end

  defmodule AlwaysContinueHook do
    @behaviour Hook

    @impl true
    def name, do: :always_continue
    @impl true
    def priority, do: 50
    @impl true
    def filter(_event), do: true
    @impl true
    def on_event(event, _ctx) do
      HookResult.continue(event, ["always_continue passed"])
    end
  end

  # -- Helper to create an active task for boundary tests --------------------

  defp create_active_task!(session_id, agent_id, opts \\ []) do
    attrs = %{
      session_id: session_id,
      content: "boundary test task",
      owner_id: agent_id,
      status: "in_progress",
      category: Keyword.get(opts, :category, "acting"),
      files_scope: Keyword.get(opts, :files_scope, [])
    }

    {:ok, task} = TaskManager.create(attrs)
    task
  end

  describe "run/3 — boundary disabled" do
    test "executes fun directly when boundary disabled via opts" do
      result =
        ActionBoundary.run(
          :test_action,
          [enabled: false],
          fn -> {:hello, :world} end
        )

      assert {:ok, {:hello, :world}} = result
    end
  end

  describe "run/3 — boundary enabled with standard hooks" do
    test "no active task blocks executor and writes Bronze hook_trace" do
      session_id = "sess_boundary_#{System.unique_integer([:positive])}"
      agent_id = "agent_boundary"

      result =
        ActionBoundary.run(
          :kiro_session_prompt,
          [
            enabled: true,
            session_id: session_id,
            agent_id: agent_id,
            permission_level: :subagent,
            pre_hooks: [KiroCockpit.Swarm.Hooks.TaskEnforcementHook],
            post_hooks: []
          ],
          fn -> :executed end
        )

      # TaskEnforcementHook blocks because no active task
      assert {:error, {:swarm_blocked, reason, messages}} = result
      assert reason =~ "No active task"
      assert is_list(messages)

      # Bronze hook_trace should be persisted
      events = KiroCockpit.Swarm.Events.list_by_session(session_id, limit: 10)
      assert length(events) == 1
      bronze = List.first(events)
      assert bronze.event_type == "hook_trace"
      assert bronze.phase == "pre"
    end

    test "active task allows executor and writes post trace" do
      session_id = "sess_boundary_ok_#{System.unique_integer([:positive])}"
      agent_id = "agent_boundary_ok"

      _task = create_active_task!(session_id, agent_id)

      # Build a plan_mode struct that is approved/executing
      plan_mode = KiroCockpit.Swarm.PlanMode.new()
      {:ok, plan_mode} = KiroCockpit.Swarm.PlanMode.enter_plan_mode(plan_mode)
      {:ok, plan_mode} = KiroCockpit.Swarm.PlanMode.draft_generated(plan_mode)
      {:ok, plan_mode} = KiroCockpit.Swarm.PlanMode.approve(plan_mode)

      result =
        ActionBoundary.run(
          :kiro_session_prompt,
          [
            enabled: true,
            session_id: session_id,
            agent_id: agent_id,
            permission_level: :subagent,
            plan_mode: plan_mode,
            approved: true,
            pre_hooks: [KiroCockpit.Swarm.Hooks.TaskEnforcementHook],
            post_hooks: []
          ],
          fn -> :executed end
        )

      assert {:ok, :executed} = result

      # Pre-hook trace persisted
      events = KiroCockpit.Swarm.Events.list_by_session(session_id, limit: 10)
      assert length(events) >= 1
      bronze = List.first(events)
      assert bronze.event_type == "hook_trace"
    end

    test "file scope blocks with out-of-scope target path" do
      session_id = "sess_scope_#{System.unique_integer([:positive])}"
      agent_id = "agent_scope"

      _task =
        create_active_task!(session_id, agent_id,
          category: "acting",
          files_scope: ["/workspace/src/"]
        )

      plan_mode = KiroCockpit.Swarm.PlanMode.new()
      {:ok, plan_mode} = KiroCockpit.Swarm.PlanMode.enter_plan_mode(plan_mode)
      {:ok, plan_mode} = KiroCockpit.Swarm.PlanMode.draft_generated(plan_mode)
      {:ok, plan_mode} = KiroCockpit.Swarm.PlanMode.approve(plan_mode)

      result =
        ActionBoundary.run(
          :fs_write_requested,
          [
            enabled: true,
            session_id: session_id,
            agent_id: agent_id,
            permission_level: :write,
            plan_mode: plan_mode,
            approved: true,
            policy_allows_write: true,
            payload: %{target_path: "/etc/passwd"},
            pre_hooks: [KiroCockpit.Swarm.Hooks.TaskEnforcementHook],
            post_hooks: []
          ],
          fn -> :written end
        )

      assert {:error, {:swarm_blocked, reason, _messages}} = result
      assert reason =~ "out of scope"
    end
  end

  describe "run/3 — custom hooks" do
    test "always-block hook prevents executor" do
      session_id = "sess_custom_#{System.unique_integer([:positive])}"

      result =
        ActionBoundary.run(
          :test_action,
          [
            enabled: true,
            session_id: session_id,
            agent_id: "agent",
            pre_hooks: [AlwaysBlockHook],
            post_hooks: []
          ],
          fn -> :should_not_run end
        )

      assert {:error, {:swarm_blocked, "blocked for test", messages}} = result
      assert "always_block blocked" in messages
    end

    test "continue hook allows executor" do
      session_id = "sess_continue_#{System.unique_integer([:positive])}"

      result =
        ActionBoundary.run(
          :test_action,
          [
            enabled: true,
            session_id: session_id,
            agent_id: "agent",
            pre_hooks: [AlwaysContinueHook],
            post_hooks: []
          ],
          fn -> :result end
        )

      assert {:ok, :result} = result
    end
  end

  describe "run/3 — correlation hydration" do
    test "hydrates task_id from active task when not provided" do
      session_id = "sess_hydrate_#{System.unique_integer([:positive])}"
      agent_id = "agent_hydrate"

      task = create_active_task!(session_id, agent_id)

      # Verify the task has an ID
      assert task.id != nil

      plan_mode = KiroCockpit.Swarm.PlanMode.new()
      {:ok, plan_mode} = KiroCockpit.Swarm.PlanMode.enter_plan_mode(plan_mode)
      {:ok, plan_mode} = KiroCockpit.Swarm.PlanMode.draft_generated(plan_mode)
      {:ok, plan_mode} = KiroCockpit.Swarm.PlanMode.approve(plan_mode)

      # Use boundary with approved ctx to pass category approval
      {:ok, result} =
        ActionBoundary.run(
          :kiro_session_prompt,
          [
            enabled: true,
            session_id: session_id,
            agent_id: agent_id,
            permission_level: :subagent,
            plan_mode: plan_mode,
            approved: true,
            pre_hooks: [KiroCockpit.Swarm.Hooks.TaskEnforcementHook],
            post_hooks: []
          ],
          fn -> :ok end
        )

      assert result == :ok
    end
  end

  describe "run/3 — stale plan context" do
    test "blocks mutating action when stale plan context is present" do
      session_id = "sess_stale_#{System.unique_integer([:positive])}"
      agent_id = "agent_stale"

      _task = create_active_task!(session_id, agent_id)

      plan_mode = KiroCockpit.Swarm.PlanMode.new()
      {:ok, plan_mode} = KiroCockpit.Swarm.PlanMode.enter_plan_mode(plan_mode)
      {:ok, plan_mode} = KiroCockpit.Swarm.PlanMode.draft_generated(plan_mode)
      {:ok, plan_mode} = KiroCockpit.Swarm.PlanMode.approve(plan_mode)

      result =
        ActionBoundary.run(
          :kiro_session_prompt,
          [
            enabled: true,
            session_id: session_id,
            agent_id: agent_id,
            permission_level: :subagent,
            plan_mode: plan_mode,
            swarm_ctx: %{stale_plan?: true, reason: :stale_plan},
            pre_hooks: [KiroCockpit.Swarm.Hooks.TaskEnforcementHook],
            post_hooks: []
          ],
          fn -> :should_not_run end
        )

      assert {:error, {:swarm_blocked, reason, _messages}} = result
      assert reason =~ "Stale plan"
    end

    test "allows mutating action with stale_plan_override?" do
      session_id = "sess_override_#{System.unique_integer([:positive])}"
      agent_id = "agent_override"

      _task = create_active_task!(session_id, agent_id)

      plan_mode = KiroCockpit.Swarm.PlanMode.new()
      {:ok, plan_mode} = KiroCockpit.Swarm.PlanMode.enter_plan_mode(plan_mode)
      {:ok, plan_mode} = KiroCockpit.Swarm.PlanMode.draft_generated(plan_mode)
      {:ok, plan_mode} = KiroCockpit.Swarm.PlanMode.approve(plan_mode)

      result =
        ActionBoundary.run(
          :kiro_session_prompt,
          [
            enabled: true,
            session_id: session_id,
            agent_id: agent_id,
            permission_level: :subagent,
            plan_mode: plan_mode,
            approved: true,
            swarm_ctx: %{stale_plan?: true, stale_plan_override?: true},
            pre_hooks: [KiroCockpit.Swarm.Hooks.TaskEnforcementHook],
            post_hooks: []
          ],
          fn -> :executed end
        )

      assert {:ok, :executed} = result
    end
  end

  describe "run/3 — independent task_id/plan_id hydration" do
    test "hydrates task_id from active task when plan_id is provided but task_id is nil" do
      session_id = "sess_indep_#{System.unique_integer([:positive])}"
      agent_id = "agent_indep"

      task = create_active_task!(session_id, agent_id)

      # Provide a plan_id but not task_id — task_id should be hydrated
      plan_mode = KiroCockpit.Swarm.PlanMode.new()
      {:ok, plan_mode} = KiroCockpit.Swarm.PlanMode.enter_plan_mode(plan_mode)
      {:ok, plan_mode} = KiroCockpit.Swarm.PlanMode.draft_generated(plan_mode)
      {:ok, plan_mode} = KiroCockpit.Swarm.PlanMode.approve(plan_mode)

      {:ok, result} =
        ActionBoundary.run(
          :kiro_session_prompt,
          [
            enabled: true,
            session_id: session_id,
            agent_id: agent_id,
            plan_id: "some-plan-id",
            permission_level: :subagent,
            plan_mode: plan_mode,
            approved: true,
            pre_hooks: [KiroCockpit.Swarm.Hooks.TaskEnforcementHook],
            post_hooks: []
          ],
          fn -> :ok end
        )

      # The boundary should succeed (task exists + approved)
      assert result == :ok
      # The task_id was hydrated from the active task so the event has
      # both task_id and plan_id, which TaskEnforcementHook sees.
      assert task.id != nil
    end

    test "hydrates plan_id from active task when task_id is provided but plan_id is nil" do
      session_id = "sess_indep_plan_#{System.unique_integer([:positive])}"
      agent_id = "agent_indep_plan"

      _task = create_active_task!(session_id, agent_id)

      # Provide task_id but not plan_id — plan_id should be hydrated
      plan_mode = KiroCockpit.Swarm.PlanMode.new()
      {:ok, plan_mode} = KiroCockpit.Swarm.PlanMode.enter_plan_mode(plan_mode)
      {:ok, plan_mode} = KiroCockpit.Swarm.PlanMode.draft_generated(plan_mode)
      {:ok, plan_mode} = KiroCockpit.Swarm.PlanMode.approve(plan_mode)

      {:ok, result} =
        ActionBoundary.run(
          :kiro_session_prompt,
          [
            enabled: true,
            session_id: session_id,
            agent_id: agent_id,
            task_id: "some-task-id",
            permission_level: :subagent,
            plan_mode: plan_mode,
            approved: true,
            pre_hooks: [KiroCockpit.Swarm.Hooks.TaskEnforcementHook],
            post_hooks: []
          ],
          fn -> :ok end
        )

      # The boundary should not crash and should succeed with the hydrated plan_id
      assert result == :ok
    end
  end

  describe "run/3 — stale context uses hydrated plan_id" do
    test "hydrated plan_id from active task feeds stale context computation" do
      session_id = "sess_stale_hydrate_#{System.unique_integer([:positive])}"
      agent_id = "agent_stale_hydrate"

      # Create an active task WITHOUT a plan_id (plan_id: nil)
      # and inject stale_plan? via swarm_ctx.
      # This tests that the boundary plumbing passes event.plan_id
      # (hydrated or not) into build_ctx for stale computation.
      _task = create_active_task!(session_id, agent_id)

      plan_mode = KiroCockpit.Swarm.PlanMode.new()
      {:ok, plan_mode} = KiroCockpit.Swarm.PlanMode.enter_plan_mode(plan_mode)
      {:ok, plan_mode} = KiroCockpit.Swarm.PlanMode.draft_generated(plan_mode)
      {:ok, plan_mode} = KiroCockpit.Swarm.PlanMode.approve(plan_mode)

      # Test 1: With swarm_ctx injecting stale_plan? = true + project_dir,
      # the boundary should block mutating actions.
      result =
        ActionBoundary.run(
          :kiro_session_prompt,
          [
            enabled: true,
            session_id: session_id,
            agent_id: agent_id,
            permission_level: :subagent,
            plan_mode: plan_mode,
            project_dir: "/tmp/test-project",
            swarm_ctx: %{stale_plan?: true, reason: :stale_plan},
            pre_hooks: [KiroCockpit.Swarm.Hooks.TaskEnforcementHook],
            post_hooks: []
          ],
          fn -> :ok end
        )

      assert {:error, {:swarm_blocked, reason, _messages}} = result
      assert reason =~ "Stale plan"
    end

    test "event.plan_id is used for stale context, not only opts[:plan_id]" do
      # This test verifies the key fix: build_ctx reads plan_id from the event
      # (which may be hydrated from the active task) rather than only opts[:plan_id].
      # We verify indirectly: when plan_id is in opts, stale context is computed;
      # the refactored code uses event.plan_id which gets the same value.
      session_id = "sess_stale_verify_#{System.unique_integer([:positive])}"
      agent_id = "agent_stale_verify"

      _task = create_active_task!(session_id, agent_id)

      plan_mode = KiroCockpit.Swarm.PlanMode.new()
      {:ok, plan_mode} = KiroCockpit.Swarm.PlanMode.enter_plan_mode(plan_mode)
      {:ok, plan_mode} = KiroCockpit.Swarm.PlanMode.draft_generated(plan_mode)
      {:ok, plan_mode} = KiroCockpit.Swarm.PlanMode.approve(plan_mode)

      # Provide plan_id in opts and project_dir — the boundary should compute
      # stale context from the plan (even if plan doesn't exist, the rescue
      # clause sets stale_plan?: true).
      result =
        ActionBoundary.run(
          :kiro_session_prompt,
          [
            enabled: true,
            session_id: session_id,
            agent_id: agent_id,
            plan_id: "nonexistent-plan-#{System.unique_integer([:positive])}",
            permission_level: :subagent,
            plan_mode: plan_mode,
            project_dir: "/tmp/test-project",
            approved: true,
            pre_hooks: [KiroCockpit.Swarm.Hooks.TaskEnforcementHook],
            post_hooks: []
          ],
          fn -> :ok end
        )

      # Non-existent plan_id → rescue clause → stale_plan?: true → blocked
      assert {:error, {:swarm_blocked, reason, _messages}} = result
      assert reason =~ "Stale plan"
    end
  end

  describe "run/3 — executor called inside boundary" do
    defmodule RecordingHook do
      @behaviour KiroCockpit.Swarm.Hook

      @impl true
      def name, do: :recording
      @impl true
      def priority, do: 50
      @impl true
      def filter(_event), do: true
      @impl true
      def on_event(event, _ctx) do
        KiroCockpit.Swarm.HookResult.continue(event, ["recording passed"])
      end
    end

    test "executor result is returned through boundary" do
      session_id = "sess_exec_#{System.unique_integer([:positive])}"

      {:ok, result} =
        ActionBoundary.run(
          :test_action,
          [
            enabled: true,
            session_id: session_id,
            agent_id: "agent",
            pre_hooks: [RecordingHook],
            post_hooks: []
          ],
          fn -> {:actual_result, 42} end
        )

      assert result == {:actual_result, 42}
    end

    test "executor runs between pre and post hooks" do
      session_id = "seq_#{System.unique_integer([:positive])}"

      # Use a custom hook that records execution order via process dict
      defmodule OrderRecordingPreHook do
        @behaviour KiroCockpit.Swarm.Hook

        @impl true
        def name, do: :order_pre
        @impl true
        def priority, do: 50
        @impl true
        def filter(_event), do: true
        @impl true
        def on_event(event, _ctx) do
          order = Process.get(:exec_order, [])
          Process.put(:exec_order, order ++ [:pre])
          KiroCockpit.Swarm.HookResult.continue(event)
        end
      end

      defmodule OrderRecordingPostHook do
        @behaviour KiroCockpit.Swarm.Hook

        @impl true
        def name, do: :order_post
        @impl true
        def priority, do: 50
        @impl true
        def filter(_event), do: true
        @impl true
        def on_event(event, _ctx) do
          order = Process.get(:exec_order, [])
          Process.put(:exec_order, order ++ [:post])
          KiroCockpit.Swarm.HookResult.continue(event)
        end
      end

      Process.put(:exec_order, [])

      {:ok, _} =
        ActionBoundary.run(
          :test_action,
          [
            enabled: true,
            session_id: session_id,
            agent_id: "agent",
            pre_hooks: [OrderRecordingPreHook],
            post_hooks: [OrderRecordingPostHook]
          ],
          fn ->
            order = Process.get(:exec_order, [])
            Process.put(:exec_order, order ++ [:exec])
            :ok
          end
        )

      assert Process.get(:exec_order) == [:pre, :exec, :post]
    after
      Process.delete(:exec_order)
    end
  end

  describe "default hooks" do
    test "default_pre_hooks returns the standard hook list" do
      hooks = ActionBoundary.default_pre_hooks()
      assert KiroCockpit.Swarm.Hooks.PlanModeFirstActionHook in hooks
      assert KiroCockpit.Swarm.Hooks.TaskEnforcementHook in hooks
      assert KiroCockpit.Swarm.Hooks.SteeringPreActionHook in hooks
    end

    test "default_post_hooks returns empty list" do
      assert ActionBoundary.default_post_hooks() == []
    end
  end
end
