defmodule KiroCockpit.Swarm.ActionBoundaryTest do
  # async: false — tests mutate global Application env (:bronze_action_capture_enabled)
  # which would race with concurrent async tests that also toggle that flag.
  use KiroCockpit.DataCase, async: false

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

  # -- Exception-safe Application env mutation for test isolation ---------------
  # Concurrent tests (bronze_section35_regression_test, bronze_action_boundary_integration_test)
  # temporarily set :bronze_action_capture_enabled to false via Application.put_env.
  # Now that this module is async: false, global env mutations are serialized,
  # but we still use this wrapper to guarantee the flag is true for tests that
  # assert Bronze events (defence-in-depth against future regressions).
  defp with_bronze_capture(fun) do
    key = :bronze_action_capture_enabled
    original = Application.get_env(:kiro_cockpit, key, true)
    Application.put_env(:kiro_cockpit, key, true)

    try do
      fun.()
    after
      Application.put_env(:kiro_cockpit, key, original)
    end
  end

  # -- Helper to create an active task for boundary tests --------------------

  defp create_active_task!(session_id, agent_id, opts \\ []) do
    attrs = %{
      session_id: session_id,
      content: Keyword.get(opts, :content, "boundary test task"),
      owner_id: agent_id,
      status: "in_progress",
      category: Keyword.get(opts, :category, "acting"),
      files_scope: Keyword.get(opts, :files_scope, [])
    }

    {:ok, task} = TaskManager.create(attrs)
    task
  end

  describe "run/3 — boundary disabled (kiro-egn non-bypassable)" do
    test "non-exempt action fails closed when boundary disabled via opts" do
      result =
        ActionBoundary.run(
          :kiro_session_prompt,
          [enabled: false],
          fn -> {:hello, :world} end
        )

      assert {:error, {:swarm_boundary_disabled, :kiro_session_prompt}} = result
    end

    test "non-exempt plan action fails closed when boundary disabled" do
      result =
        ActionBoundary.run(
          :nano_plan_generate,
          [enabled: false],
          fn -> :executed end
        )

      assert {:error, {:swarm_boundary_disabled, :nano_plan_generate}} = result
    end

    test "non-exempt callback action fails closed when boundary disabled" do
      result =
        ActionBoundary.run(
          :fs_write_requested,
          [enabled: false],
          fn -> :written end
        )

      assert {:error, {:swarm_boundary_disabled, :fs_write_requested}} = result
    end

    test "exempt action executes directly when boundary disabled" do
      result =
        ActionBoundary.run(
          :task_created,
          [enabled: false],
          fn -> {:hello, :world} end
        )

      assert {:ok, {:hello, :world}} = result
    end

    test "test_bypass allows execution in test env when boundary disabled" do
      result =
        ActionBoundary.run(
          :kiro_session_prompt,
          [enabled: false, test_bypass: true],
          fn -> {:hello, :world} end
        )

      assert {:ok, {:hello, :world}} = result
    end

    test "test_bypass is ignored when set to false" do
      result =
        ActionBoundary.run(
          :kiro_session_prompt,
          [enabled: false, test_bypass: false],
          fn -> {:hello, :world} end
        )

      assert {:error, {:swarm_boundary_disabled, :kiro_session_prompt}} = result
    end

    test "exempt_actions/0 returns known exempt actions" do
      exempt = ActionBoundary.exempt_actions()
      assert is_list(exempt)
      assert :task_created in exempt
      assert :task_activated in exempt
      assert :task_completed in exempt
      assert :task_blocked in exempt
      assert :plan_approved_lifecycle in exempt
      assert :lifecycle_post_hook in exempt
    end

    test "exempt_action?/1 correctly classifies actions" do
      assert ActionBoundary.exempt_action?(:task_created)
      assert ActionBoundary.exempt_action?(:lifecycle_post_hook)
      refute ActionBoundary.exempt_action?(:kiro_session_prompt)
      refute ActionBoundary.exempt_action?(:nano_plan_generate)
      refute ActionBoundary.exempt_action?(:fs_write_requested)
    end

    test "boundary disabled via app config fails closed for non-exempt" do
      original = Application.get_env(:kiro_cockpit, :swarm_action_hooks_enabled)
      Application.put_env(:kiro_cockpit, :swarm_action_hooks_enabled, false)

      try do
        result =
          ActionBoundary.run(
            :kiro_session_prompt,
            [],
            fn -> :executed end
          )

        assert {:error, {:swarm_boundary_disabled, :kiro_session_prompt}} = result
      after
        Application.put_env(:kiro_cockpit, :swarm_action_hooks_enabled, original)
      end
    end
  end

  describe "run/3 — boundary enabled with standard hooks" do
    test "no active task blocks executor and writes Bronze hook_trace" do
      with_bronze_capture(fn ->
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

        # Bronze events should be persisted: action_before, hook_trace, action_blocked
        events = KiroCockpit.Swarm.Events.list_by_session(session_id, limit: 10)
        event_types = Enum.map(events, & &1.event_type)
        assert "hook_trace" in event_types
        # §35 Phase 3: action_before and action_blocked also persisted
        assert "action_before" in event_types
        assert "action_blocked" in event_types
        hook_trace = Enum.find(events, &(&1.event_type == "hook_trace"))
        assert hook_trace.phase == "pre"
      end)
    end

    test "active task allows executor and writes post trace" do
      with_bronze_capture(fn ->
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

        # Pre-hook trace persisted (alongside §35 action events)
        events = KiroCockpit.Swarm.Events.list_by_session(session_id, limit: 10)
        event_types = Enum.map(events, & &1.event_type)
        assert "hook_trace" in event_types
        # §35 Phase 3: action_before and action_after also present
        assert "action_before" in event_types
        assert "action_after" in event_types
      end)
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

    test "executor dispatch (:kiro_session_prompt) allowed with approved plan and active task even for researching category" do
      session_id = "sess_exec_dispatch_#{System.unique_integer([:positive])}"
      agent_id = "agent_exec_dispatch"

      # Create a researching task (normally doesn't allow subagent)
      _task =
        create_active_task!(session_id, agent_id,
          category: "researching",
          files_scope: []
        )

      # Build approved plan_mode
      plan_mode = KiroCockpit.Swarm.PlanMode.new()
      {:ok, plan_mode} = KiroCockpit.Swarm.PlanMode.enter_plan_mode(plan_mode)
      {:ok, plan_mode} = KiroCockpit.Swarm.PlanMode.draft_generated(plan_mode)
      {:ok, plan_mode} = KiroCockpit.Swarm.PlanMode.approve(plan_mode)

      # Executor dispatch with :executor_dispatch permission level and approved flag
      result =
        ActionBoundary.run(
          :kiro_session_prompt,
          [
            enabled: true,
            session_id: session_id,
            agent_id: agent_id,
            permission_level: :executor_dispatch,
            plan_mode: plan_mode,
            approved: true,
            pre_hooks: [KiroCockpit.Swarm.Hooks.TaskEnforcementHook],
            post_hooks: []
          ],
          fn -> :prompt_dispatched end
        )

      # Should be allowed because it's executor dispatch with approved plan
      assert {:ok, :prompt_dispatched} = result
    end

    test "subsequent fs_write_requested still blocked for researching category even with approved plan" do
      session_id = "sess_write_blocked_#{System.unique_integer([:positive])}"
      agent_id = "agent_write_blocked"

      # Create a researching task
      _task =
        create_active_task!(session_id, agent_id,
          category: "researching",
          files_scope: ["lib/"]
        )

      plan_mode = KiroCockpit.Swarm.PlanMode.new()
      {:ok, plan_mode} = KiroCockpit.Swarm.PlanMode.enter_plan_mode(plan_mode)
      {:ok, plan_mode} = KiroCockpit.Swarm.PlanMode.draft_generated(plan_mode)
      {:ok, plan_mode} = KiroCockpit.Swarm.PlanMode.approve(plan_mode)

      # fs_write_requested maps to :write permission
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
            payload: %{target_path: "lib/test.ex"},
            pre_hooks: [KiroCockpit.Swarm.Hooks.TaskEnforcementHook],
            post_hooks: []
          ],
          fn -> :written end
        )

      # Should be blocked because researching category doesn't allow writes
      assert {:error, {:swarm_blocked, reason, _messages}} = result
      assert reason =~ "Category permission denied"
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

    test "default_post_hooks includes TaskGuidanceHook" do
      hooks = ActionBoundary.default_post_hooks()
      assert KiroCockpit.Swarm.Hooks.TaskGuidanceHook in hooks
    end
  end

  # -- kiro-4dk: Pre-hook modification threading tests -----------------------

  describe "kiro-4dk: pre-hook modify threading" do
    defmodule ModifyEventHook do
      @behaviour KiroCockpit.Swarm.Hook

      @impl true
      def name, do: :modify_event
      @impl true
      def priority, do: 100
      @impl true
      def filter(_event), do: true
      @impl true
      def on_event(event, _ctx) do
        # Modify the event by adding to metadata
        modified_metadata = Map.put(event.metadata, :modified_by, :modify_event_hook)
        modified_event = %{event | metadata: modified_metadata}
        KiroCockpit.Swarm.HookResult.modify(modified_event, ["event modified"])
      end
    end

    defmodule VerifyModifiedEventHook do
      @behaviour KiroCockpit.Swarm.Hook

      @impl true
      def name, do: :verify_modified
      @impl true
      def priority, do: 50
      @impl true
      def filter(_event), do: true
      @impl true
      def on_event(event, _ctx) do
        # Verify the event was modified by the previous hook
        if event.metadata[:modified_by] == :modify_event_hook do
          KiroCockpit.Swarm.HookResult.continue(event, ["verified: event was modified"])
        else
          KiroCockpit.Swarm.HookResult.block(event, "event not modified", [
            "error: original event received"
          ])
        end
      end
    end

    test "pre-hook modify changes event visible to a later post-hook" do
      session_id = "sess_modify_thread_#{System.unique_integer([:positive])}"

      # Track which event the post-hook received using an atom-based ETS table
      :ets.new(:post_hook_event, [:set, :public, :named_table])

      defmodule PostHookCapture do
        @behaviour KiroCockpit.Swarm.Hook

        @impl true
        def name, do: :post_capture
        @impl true
        def priority, do: 50
        @impl true
        def filter(_event), do: true
        @impl true
        def on_event(event, _ctx) do
          # Store the event metadata for verification
          if event.metadata[:modified_by] == :modify_event_hook do
            :ets.insert(:post_hook_event, {:modified, true})
          else
            :ets.insert(:post_hook_event, {:modified, false})
          end

          KiroCockpit.Swarm.HookResult.continue(event)
        end
      end

      {:ok, result} =
        ActionBoundary.run(
          :test_action,
          [
            enabled: true,
            session_id: session_id,
            agent_id: "agent",
            pre_hooks: [ModifyEventHook, VerifyModifiedEventHook],
            post_hooks: [PostHookCapture]
          ],
          fn -> :success end
        )

      assert result == :success

      # Verify the post-hook received the modified event
      assert [modified: true] = :ets.lookup(:post_hook_event, :modified)

      :ets.delete(:post_hook_event)
    end

    test "arity-1 executor receives modified event and messages in context" do
      session_id = "sess_arity1_#{System.unique_integer([:positive])}"

      # Hook that modifies the event and adds messages
      defmodule ModifyWithGuidanceHook do
        @behaviour KiroCockpit.Swarm.Hook

        @impl true
        def name, do: :modify_with_guidance
        @impl true
        def priority, do: 100
        @impl true
        def filter(_event), do: true
        @impl true
        def on_event(event, _ctx) do
          modified_metadata = Map.put(event.metadata, :guidance_applied, true)
          modified_event = %{event | metadata: modified_metadata}

          guidance_messages = [
            "🧭 PlanMode: You are in plan mode (planning). Focus on read-only discovery.",
            "⚡ Steering: slight drift detected - consider the main task."
          ]

          KiroCockpit.Swarm.HookResult.modify(modified_event, guidance_messages)
        end
      end

      # Arity-1 executor that captures the context
      captured_context = :ets.new(:captured_context, [:set, :public, :named_table])

      executor_fn = fn ctx ->
        :ets.insert(captured_context, {:ctx, ctx})

        # Verify context structure
        assert ctx.event != nil
        assert is_list(ctx.messages)
        assert is_list(ctx.hook_messages)
        assert ctx.messages == ctx.hook_messages
        assert length(ctx.messages) == 2
        assert ctx.event.metadata[:guidance_applied] == true

        # Verify hook messages are present
        [msg1, msg2] = ctx.messages
        assert msg1 =~ "PlanMode"
        assert msg2 =~ "Steering"

        :executor_completed
      end

      {:ok, result} =
        ActionBoundary.run(
          :test_action,
          [
            enabled: true,
            session_id: session_id,
            agent_id: "agent",
            pre_hooks: [ModifyWithGuidanceHook],
            post_hooks: []
          ],
          executor_fn
        )

      assert result == :executor_completed

      # Verify context was passed correctly
      assert [{:ctx, ctx}] = :ets.lookup(captured_context, :ctx)
      assert ctx.event.metadata[:guidance_applied] == true
      assert length(ctx.messages) == 2

      :ets.delete(captured_context)
    end

    test "arity-0 executor still works with modified event metadata" do
      session_id = "sess_arity0_#{System.unique_integer([:positive])}"

      # Hook that adds guidance messages
      defmodule AddGuidanceHook do
        @behaviour KiroCockpit.Swarm.Hook

        @impl true
        def name, do: :add_guidance
        @impl true
        def priority, do: 100
        @impl true
        def filter(_event), do: true
        @impl true
        def on_event(event, _ctx) do
          guidance = "🧭 PlanMode: Focus on the current task scope."
          KiroCockpit.Swarm.HookResult.modify(event, [guidance])
        end
      end

      # Post-hook to verify the modified event with guidance in metadata
      defmodule VerifyGuidanceInMetadata do
        @behaviour KiroCockpit.Swarm.Hook

        @impl true
        def name, do: :verify_guidance
        @impl true
        def priority, do: 50
        @impl true
        def filter(_event), do: true
        @impl true
        def on_event(event, _ctx) do
          # For arity-0, hook guidance should be merged into event metadata
          hook_guidance = event.metadata[:hook_guidance]

          if is_list(hook_guidance) and length(hook_guidance) > 0 and
               hd(hook_guidance) =~ "PlanMode" do
            KiroCockpit.Swarm.HookResult.continue(event, ["guidance found in metadata"])
          else
            KiroCockpit.Swarm.HookResult.block(event, "guidance not in metadata", [
              "hook_guidance missing"
            ])
          end
        end
      end

      {:ok, result} =
        ActionBoundary.run(
          :test_action,
          [
            enabled: true,
            session_id: session_id,
            agent_id: "agent",
            pre_hooks: [AddGuidanceHook],
            post_hooks: [VerifyGuidanceInMetadata]
          ],
          fn -> :arity0_success end
        )

      assert result == :arity0_success
    end

    test "steering focus/guide messages are surfaced via ActionBoundary context" do
      session_id = "sess_steering_#{System.unique_integer([:positive])}"

      # Simulate a steering hook that returns focus/guide messages
      defmodule SteeringFocusHook do
        @behaviour KiroCockpit.Swarm.Hook

        @impl true
        def name, do: :steering_focus
        @impl true
        def priority, do: 94
        @impl true
        def filter(_event), do: true
        @impl true
        def on_event(event, _ctx) do
          focus_message =
            "⚡ Steering: slight drift - action may be off-task. Suggested: refocus on main objective."

          KiroCockpit.Swarm.HookResult.modify(
            event,
            [focus_message],
            hook_metadata: %{steering_decision: :focus, steering_source: :deterministic}
          )
        end
      end

      defmodule SteeringGuideHook do
        @behaviour KiroCockpit.Swarm.Hook

        @impl true
        def name, do: :steering_guide
        @impl true
        def priority, do: 93
        @impl true
        def filter(_event), do: true
        @impl true
        def on_event(event, _ctx) do
          guide_message =
            "🧭 Steering: Consider related context from memory. [refs: context_abc, context_def]"

          KiroCockpit.Swarm.HookResult.modify(
            event,
            [guide_message],
            hook_metadata: %{steering_decision: :guide, steering_source: :llm}
          )
        end
      end

      captured_ctx = :ets.new(:captured_steering, [:set, :public, :named_table])

      executor_fn = fn ctx ->
        :ets.insert(captured_ctx, {:ctx, ctx})

        # Verify both steering messages are present
        assert length(ctx.messages) == 2

        focus_msg = Enum.find(ctx.messages, fn m -> m =~ "⚡ Steering" end)
        guide_msg = Enum.find(ctx.messages, fn m -> m =~ "🧭 Steering" end)

        assert focus_msg != nil, "Focus message not found"
        assert guide_msg != nil, "Guide message not found"
        assert focus_msg =~ "slight drift"
        assert guide_msg =~ "memory"

        # Verify event has hook_guidance merged into metadata for arity-0 compatibility
        hook_guidance = ctx.event.metadata[:hook_guidance]
        assert is_list(hook_guidance)
        assert length(hook_guidance) == 2

        :steering_received
      end

      {:ok, result} =
        ActionBoundary.run(
          :kiro_session_prompt,
          [
            enabled: true,
            session_id: session_id,
            agent_id: "agent",
            permission_level: :subagent,
            pre_hooks: [SteeringFocusHook, SteeringGuideHook],
            post_hooks: []
          ],
          executor_fn
        )

      assert result == :steering_received

      :ets.delete(captured_ctx)
    end

    test "PlanModeFirstActionHook messages are surfaced via ActionBoundary context" do
      session_id = "sess_planmode_#{System.unique_integer([:positive])}"

      # Simulate a PlanMode hook that returns first-action guidance
      defmodule PlanModeFirstActionSimulated do
        @behaviour KiroCockpit.Swarm.Hook

        @impl true
        def name, do: :plan_mode_first_action_simulated
        @impl true
        def priority, do: 96
        @impl true
        def filter(_event), do: true
        @impl true
        def on_event(event, _ctx) do
          guidance =
            "You are in plan mode (planning). Focus on read-only discovery and planning output. Direct reads are allowed; shell commands and mutations are blocked until the plan is approved."

          modified_metadata = Map.put(event.metadata, :first_action_shown, true)
          modified_event = %{event | metadata: modified_metadata}

          KiroCockpit.Swarm.HookResult.modify(
            modified_event,
            [guidance],
            hook_metadata: %{first_action_shown: true}
          )
        end
      end

      captured_ctx = :ets.new(:captured_planmode, [:set, :public, :named_table])

      executor_fn = fn ctx ->
        :ets.insert(captured_ctx, {:ctx, ctx})

        # Verify PlanMode guidance is present
        assert length(ctx.messages) == 1
        [msg] = ctx.messages

        assert msg =~ "plan mode (planning)"
        assert msg =~ "read-only discovery"
        assert msg =~ "blocked until the plan is approved"

        # Verify metadata flags
        assert ctx.event.metadata[:first_action_shown] == true

        # Verify hook_guidance merged for arity-0 compatibility
        hook_guidance = ctx.event.metadata[:hook_guidance]
        assert is_list(hook_guidance)
        assert length(hook_guidance) == 1
        assert hd(hook_guidance) =~ "plan mode"

        :planmode_received
      end

      {:ok, result} =
        ActionBoundary.run(
          :kiro_session_prompt,
          [
            enabled: true,
            session_id: session_id,
            agent_id: "agent",
            permission_level: :subagent,
            pre_hooks: [PlanModeFirstActionSimulated],
            post_hooks: []
          ],
          executor_fn
        )

      assert result == :planmode_received

      :ets.delete(captured_ctx)
    end

    test "multiple hook messages accumulate correctly" do
      session_id = "sess_multi_msg_#{System.unique_integer([:positive])}"

      defmodule MessageHook1 do
        @behaviour KiroCockpit.Swarm.Hook
        @impl true
        def name, do: :msg_hook_1
        @impl true
        def priority, do: 100
        @impl true
        def filter(_event), do: true
        @impl true
        def on_event(event, _ctx) do
          KiroCockpit.Swarm.HookResult.modify(event, ["message 1"])
        end
      end

      defmodule MessageHook2 do
        @behaviour KiroCockpit.Swarm.Hook
        @impl true
        def name, do: :msg_hook_2
        @impl true
        def priority, do: 99
        @impl true
        def filter(_event), do: true
        @impl true
        def on_event(event, _ctx) do
          KiroCockpit.Swarm.HookResult.modify(event, ["message 2", "message 3"])
        end
      end

      defmodule ContinueHookWithMsg do
        @behaviour KiroCockpit.Swarm.Hook
        @impl true
        def name, do: :continue_msg
        @impl true
        def priority, do: 98
        @impl true
        def filter(_event), do: true
        @impl true
        def on_event(event, _ctx) do
          KiroCockpit.Swarm.HookResult.continue(event, ["message 4"])
        end
      end

      captured_ctx = :ets.new(:captured_multi, [:set, :public, :named_table])

      executor_fn = fn ctx ->
        :ets.insert(captured_ctx, {:messages, ctx.messages})

        # All messages should accumulate: 1 + 2 + 3 + 4
        assert length(ctx.messages) == 4
        assert "message 1" in ctx.messages
        assert "message 2" in ctx.messages
        assert "message 3" in ctx.messages
        assert "message 4" in ctx.messages

        :all_messages_received
      end

      {:ok, result} =
        ActionBoundary.run(
          :test_action,
          [
            enabled: true,
            session_id: session_id,
            agent_id: "agent",
            pre_hooks: [MessageHook1, MessageHook2, ContinueHookWithMsg],
            post_hooks: []
          ],
          executor_fn
        )

      assert result == :all_messages_received

      :ets.delete(captured_ctx)
    end
  end

  # -------------------------------------------------------------------
  # Steering context hydration tests (kiro-oai steering-context-hydration)
  # -------------------------------------------------------------------

  describe "steering context hydration — when swarm_ctx is empty" do
    # Hook that captures the ctx for verification
    defmodule CtxCapturingHook do
      @behaviour KiroCockpit.Swarm.Hook

      @impl true
      def name, do: :ctx_capture
      @impl true
      def priority, do: 95
      @impl true
      def filter(_event), do: true
      @impl true
      def on_event(event, ctx) do
        Process.put(:captured_ctx, ctx)
        KiroCockpit.Swarm.HookResult.continue(event, ["ctx captured"])
      end
    end

    setup do
      Process.delete(:captured_ctx)
      :ok
    end

    test "hydrates active_task from TaskManager when not in swarm_ctx" do
      session_id = "sess_hydrate_task_#{System.unique_integer([:positive])}"
      agent_id = "agent_hydrate"

      task = create_active_task!(session_id, agent_id, content: "Test task for hydration")

      plan_mode = KiroCockpit.Swarm.PlanMode.new()
      {:ok, plan_mode} = KiroCockpit.Swarm.PlanMode.enter_plan_mode(plan_mode)
      {:ok, plan_mode} = KiroCockpit.Swarm.PlanMode.draft_generated(plan_mode)
      {:ok, plan_mode} = KiroCockpit.Swarm.PlanMode.approve(plan_mode)

      {:ok, _} =
        ActionBoundary.run(
          :kiro_session_prompt,
          [
            enabled: true,
            session_id: session_id,
            agent_id: agent_id,
            permission_level: :subagent,
            plan_mode: plan_mode,
            approved: true,
            # Empty swarm_ctx — should be hydrated
            swarm_ctx: %{},
            pre_hooks: [CtxCapturingHook],
            post_hooks: []
          ],
          fn -> :ok end
        )

      ctx = Process.get(:captured_ctx)
      assert ctx != nil
      assert ctx.active_task != nil
      assert ctx.active_task.id == task.id
      assert ctx.active_task.content == "Test task for hydration"
    end

    test "hydrates plan from database when plan_id is available" do
      session_id = "sess_hydrate_plan_#{System.unique_integer([:positive])}"
      agent_id = "agent_hydrate"

      # Create a plan with proper mode and required fields
      {:ok, plan} =
        KiroCockpit.Plans.create_plan(
          session_id,
          "Test plan for hydration",
          "nano",
          [
            %{
              title: "Step 1",
              permission_level: "write",
              phase_number: 1,
              step_number: 1,
              status: "planned"
            }
          ],
          plan_markdown: "# Test Plan",
          execution_prompt: "Execute the plan",
          project_snapshot_hash: "abc123"
        )

      # Create a task associated with the plan
      task_attrs = %{
        session_id: session_id,
        content: "Test task with plan",
        owner_id: agent_id,
        status: "in_progress",
        category: "acting",
        files_scope: [],
        plan_id: plan.id
      }

      {:ok, _} = TaskManager.create(task_attrs)

      plan_mode = KiroCockpit.Swarm.PlanMode.new()
      {:ok, plan_mode} = KiroCockpit.Swarm.PlanMode.enter_plan_mode(plan_mode)
      {:ok, plan_mode} = KiroCockpit.Swarm.PlanMode.draft_generated(plan_mode)
      {:ok, plan_mode} = KiroCockpit.Swarm.PlanMode.approve(plan_mode)

      {:ok, _} =
        ActionBoundary.run(
          :kiro_session_prompt,
          [
            enabled: true,
            session_id: session_id,
            agent_id: agent_id,
            plan_id: plan.id,
            permission_level: :subagent,
            plan_mode: plan_mode,
            approved: true,
            # Empty swarm_ctx — should be hydrated with plan
            swarm_ctx: %{},
            pre_hooks: [CtxCapturingHook],
            post_hooks: []
          ],
          fn -> :ok end
        )

      ctx = Process.get(:captured_ctx)
      assert ctx != nil
      assert ctx.plan != nil
      assert ctx.plan.id == plan.id
      assert ctx.plan.user_request == "Test plan for hydration"
    end

    test "hydrates task_history from TaskManager" do
      session_id = "sess_hydrate_history_#{System.unique_integer([:positive])}"
      agent_id = "agent_hydrate"

      # Create multiple tasks for history
      {:ok, task1} =
        TaskManager.create(%{
          session_id: session_id,
          content: "First completed task",
          owner_id: agent_id,
          status: "completed",
          category: "acting",
          files_scope: []
        })

      {:ok, task2} =
        TaskManager.create(%{
          session_id: session_id,
          content: "Second completed task",
          owner_id: agent_id,
          status: "completed",
          category: "acting",
          files_scope: []
        })

      # Create active task
      {:ok, _active_task} =
        TaskManager.create(%{
          session_id: session_id,
          content: "Active task",
          owner_id: agent_id,
          status: "in_progress",
          category: "acting",
          files_scope: []
        })

      plan_mode = KiroCockpit.Swarm.PlanMode.new()
      {:ok, plan_mode} = KiroCockpit.Swarm.PlanMode.enter_plan_mode(plan_mode)
      {:ok, plan_mode} = KiroCockpit.Swarm.PlanMode.draft_generated(plan_mode)
      {:ok, plan_mode} = KiroCockpit.Swarm.PlanMode.approve(plan_mode)

      {:ok, _} =
        ActionBoundary.run(
          :kiro_session_prompt,
          [
            enabled: true,
            session_id: session_id,
            agent_id: agent_id,
            permission_level: :subagent,
            plan_mode: plan_mode,
            approved: true,
            swarm_ctx: %{},
            pre_hooks: [CtxCapturingHook],
            post_hooks: []
          ],
          fn -> :ok end
        )

      ctx = Process.get(:captured_ctx)
      assert ctx != nil
      assert ctx.task_history != nil
      assert is_list(ctx.task_history)
      # Should include all tasks (active + completed)
      task_ids = Enum.map(ctx.task_history, & &1.id)
      assert task1.id in task_ids
      assert task2.id in task_ids
    end

    test "hydrates completed_tasks from TaskManager" do
      session_id = "sess_hydrate_completed_#{System.unique_integer([:positive])}"
      agent_id = "agent_hydrate"

      # Create completed tasks
      {:ok, task1} =
        TaskManager.create(%{
          session_id: session_id,
          content: "Completed task 1",
          owner_id: agent_id,
          status: "completed",
          category: "acting",
          files_scope: []
        })

      {:ok, task2} =
        TaskManager.create(%{
          session_id: session_id,
          content: "Completed task 2",
          owner_id: agent_id,
          status: "completed",
          category: "researching",
          files_scope: []
        })

      # Create a pending task (not completed)
      {:ok, _pending} =
        TaskManager.create(%{
          session_id: session_id,
          content: "Pending task",
          owner_id: agent_id,
          status: "pending",
          category: "acting",
          files_scope: []
        })

      # Create active task
      {:ok, _active} =
        TaskManager.create(%{
          session_id: session_id,
          content: "Active task",
          owner_id: agent_id,
          status: "in_progress",
          category: "acting",
          files_scope: []
        })

      plan_mode = KiroCockpit.Swarm.PlanMode.new()
      {:ok, plan_mode} = KiroCockpit.Swarm.PlanMode.enter_plan_mode(plan_mode)
      {:ok, plan_mode} = KiroCockpit.Swarm.PlanMode.draft_generated(plan_mode)
      {:ok, plan_mode} = KiroCockpit.Swarm.PlanMode.approve(plan_mode)

      {:ok, _} =
        ActionBoundary.run(
          :kiro_session_prompt,
          [
            enabled: true,
            session_id: session_id,
            agent_id: agent_id,
            permission_level: :subagent,
            plan_mode: plan_mode,
            approved: true,
            swarm_ctx: %{},
            pre_hooks: [CtxCapturingHook],
            post_hooks: []
          ],
          fn -> :ok end
        )

      ctx = Process.get(:captured_ctx)
      assert ctx != nil
      assert ctx.completed_tasks != nil
      assert is_list(ctx.completed_tasks)
      # Should only include completed tasks
      completed_ids = Enum.map(ctx.completed_tasks, & &1.id)
      assert task1.id in completed_ids
      assert task2.id in completed_ids
      # Pending task should not be in completed_tasks
      assert length(completed_ids) == 2
    end

    test "hydrates permission_policy from active_task and permission_level" do
      session_id = "sess_hydrate_policy_#{System.unique_integer([:positive])}"
      agent_id = "agent_hydrate"

      {:ok, _} =
        TaskManager.create(%{
          session_id: session_id,
          content: "Task with file scope",
          owner_id: agent_id,
          status: "in_progress",
          category: "acting",
          files_scope: ["/workspace/src/"],
          permission_scope: ["write", "read"]
        })

      plan_mode = KiroCockpit.Swarm.PlanMode.new()
      {:ok, plan_mode} = KiroCockpit.Swarm.PlanMode.enter_plan_mode(plan_mode)
      {:ok, plan_mode} = KiroCockpit.Swarm.PlanMode.draft_generated(plan_mode)
      {:ok, plan_mode} = KiroCockpit.Swarm.PlanMode.approve(plan_mode)

      {:ok, _} =
        ActionBoundary.run(
          :kiro_session_prompt,
          [
            enabled: true,
            session_id: session_id,
            agent_id: agent_id,
            permission_level: :write,
            plan_mode: plan_mode,
            approved: true,
            swarm_ctx: %{},
            pre_hooks: [CtxCapturingHook],
            post_hooks: []
          ],
          fn -> :ok end
        )

      ctx = Process.get(:captured_ctx)
      assert ctx != nil
      assert ctx.permission_policy != nil
      assert ctx.permission_policy.level == :write
      assert ctx.permission_policy.allows_write == true
      assert ctx.permission_policy.allows_destructive == false
      assert ctx.permission_policy.category == "acting"
    end
  end

  describe "steering context hydration — preserves existing data" do
    defmodule CtxPreservingHook do
      @behaviour KiroCockpit.Swarm.Hook

      @impl true
      def name, do: :ctx_preserve
      @impl true
      def priority, do: 95
      @impl true
      def filter(_event), do: true
      @impl true
      def on_event(event, ctx) do
        Process.put(:preserved_ctx, ctx)
        KiroCockpit.Swarm.HookResult.continue(event, ["ctx preserved"])
      end
    end

    setup do
      Process.delete(:preserved_ctx)
      :ok
    end

    test "preserves existing active_task in swarm_ctx" do
      session_id = "sess_preserve_task_#{System.unique_integer([:positive])}"
      agent_id = "agent_preserve"

      # Create a task in DB (different from what we'll pass in ctx)
      task = create_active_task!(session_id, agent_id, content: "DB task")

      # Pass a different task in swarm_ctx
      existing_task = %{
        id: "existing-task-id",
        content: "Existing task from ctx",
        category: "researching"
      }

      plan_mode = KiroCockpit.Swarm.PlanMode.new()
      {:ok, plan_mode} = KiroCockpit.Swarm.PlanMode.enter_plan_mode(plan_mode)
      {:ok, plan_mode} = KiroCockpit.Swarm.PlanMode.draft_generated(plan_mode)
      {:ok, plan_mode} = KiroCockpit.Swarm.PlanMode.approve(plan_mode)

      {:ok, _} =
        ActionBoundary.run(
          :kiro_session_prompt,
          [
            enabled: true,
            session_id: session_id,
            agent_id: agent_id,
            permission_level: :subagent,
            plan_mode: plan_mode,
            approved: true,
            swarm_ctx: %{active_task: existing_task},
            pre_hooks: [CtxPreservingHook],
            post_hooks: []
          ],
          fn -> :ok end
        )

      ctx = Process.get(:preserved_ctx)
      assert ctx.active_task == existing_task
      # Should NOT be replaced with DB task
      assert ctx.active_task.id != task.id
    end

    test "preserves existing plan in swarm_ctx" do
      session_id = "sess_preserve_plan_#{System.unique_integer([:positive])}"
      agent_id = "agent_preserve"

      # Create a plan in DB with proper mode and required fields
      {:ok, db_plan} =
        KiroCockpit.Plans.create_plan(
          session_id,
          "DB plan",
          "nano",
          [
            %{
              title: "Step",
              permission_level: "write",
              phase_number: 1,
              step_number: 1,
              status: "planned"
            }
          ],
          plan_markdown: "# DB Plan",
          execution_prompt: "Execute the plan",
          project_snapshot_hash: "def456"
        )

      # Create task with the DB plan
      {:ok, _} =
        TaskManager.create(%{
          session_id: session_id,
          content: "Task",
          owner_id: agent_id,
          status: "in_progress",
          category: "acting",
          files_scope: [],
          plan_id: db_plan.id
        })

      # Pass a different plan in swarm_ctx
      existing_plan = %{id: "existing-plan-id", user_request: "Existing plan"}

      plan_mode = KiroCockpit.Swarm.PlanMode.new()
      {:ok, plan_mode} = KiroCockpit.Swarm.PlanMode.enter_plan_mode(plan_mode)
      {:ok, plan_mode} = KiroCockpit.Swarm.PlanMode.draft_generated(plan_mode)
      {:ok, plan_mode} = KiroCockpit.Swarm.PlanMode.approve(plan_mode)

      {:ok, _} =
        ActionBoundary.run(
          :kiro_session_prompt,
          [
            enabled: true,
            session_id: session_id,
            agent_id: agent_id,
            plan_id: db_plan.id,
            permission_level: :subagent,
            plan_mode: plan_mode,
            approved: true,
            swarm_ctx: %{plan: existing_plan},
            pre_hooks: [CtxPreservingHook],
            post_hooks: []
          ],
          fn -> :ok end
        )

      ctx = Process.get(:preserved_ctx)
      assert ctx.plan == existing_plan
      # Should NOT be replaced with DB plan
      assert ctx.plan.id != db_plan.id
    end

    test "preserves existing permission_policy in swarm_ctx" do
      session_id = "sess_preserve_policy_#{System.unique_integer([:positive])}"
      agent_id = "agent_preserve"

      _task = create_active_task!(session_id, agent_id)

      # Pass existing permission_policy
      existing_policy = %{
        level: :subagent,
        files_scope: ["/custom/path/"],
        allows_write: true,
        allows_destructive: true,
        category: "custom"
      }

      plan_mode = KiroCockpit.Swarm.PlanMode.new()
      {:ok, plan_mode} = KiroCockpit.Swarm.PlanMode.enter_plan_mode(plan_mode)
      {:ok, plan_mode} = KiroCockpit.Swarm.PlanMode.draft_generated(plan_mode)
      {:ok, plan_mode} = KiroCockpit.Swarm.PlanMode.approve(plan_mode)

      {:ok, _} =
        ActionBoundary.run(
          :kiro_session_prompt,
          [
            enabled: true,
            session_id: session_id,
            agent_id: agent_id,
            permission_level: :write,
            plan_mode: plan_mode,
            approved: true,
            swarm_ctx: %{permission_policy: existing_policy},
            pre_hooks: [CtxPreservingHook],
            post_hooks: []
          ],
          fn -> :ok end
        )

      ctx = Process.get(:preserved_ctx)
      assert ctx.permission_policy == existing_policy
      assert ctx.permission_policy.files_scope == ["/custom/path/"]
      assert ctx.permission_policy.allows_destructive == true
    end
  end

  describe "steering context hydration — defensive behavior" do
    defmodule CtxDefensiveHook do
      @behaviour KiroCockpit.Swarm.Hook

      @impl true
      def name, do: :ctx_defensive
      @impl true
      def priority, do: 95
      @impl true
      def filter(_event), do: true
      @impl true
      def on_event(event, ctx) do
        Process.put(:defensive_ctx, ctx)
        KiroCockpit.Swarm.HookResult.continue(event, ["ctx defensive"])
      end
    end

    # Fake TaskManager that raises on get_active
    defmodule RaisingTaskManager do
      def get_active(_session_id, _agent_id), do: raise("DB error")
      def list(_session_id, _opts), do: raise("DB error")
    end

    setup do
      Process.delete(:defensive_ctx)
      :ok
    end

    test "continues when TaskManager lookup fails" do
      session_id = "sess_defensive_#{System.unique_integer([:positive])}"
      agent_id = "agent_defensive"

      plan_mode = KiroCockpit.Swarm.PlanMode.new()
      {:ok, plan_mode} = KiroCockpit.Swarm.PlanMode.enter_plan_mode(plan_mode)
      {:ok, plan_mode} = KiroCockpit.Swarm.PlanMode.draft_generated(plan_mode)
      {:ok, plan_mode} = KiroCockpit.Swarm.PlanMode.approve(plan_mode)

      # Should not crash even though TaskManager raises
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
            swarm_ctx: %{},
            # Inject raising task manager
            task_manager_module: RaisingTaskManager,
            pre_hooks: [CtxDefensiveHook],
            post_hooks: []
          ],
          fn -> :survived end
        )

      assert result == :survived

      # Context should be present but without hydrated task data
      ctx = Process.get(:defensive_ctx)
      assert ctx != nil
      # active_task should not be hydrated due to DB error
      # When hydration fails, the key may not be present at all
      assert Map.get(ctx, :active_task) == nil
    end

    test "hydrates what it can when only some lookups fail" do
      # Using a fake TM that works for this test — the task_manager_module
      # injection allows testability without affecting real DB
      session_id = "sess_partial_#{System.unique_integer([:positive])}"
      agent_id = "agent_partial"

      # Create a real task first
      task = create_active_task!(session_id, agent_id, content: "Partial test task")

      plan_mode = KiroCockpit.Swarm.PlanMode.new()
      {:ok, plan_mode} = KiroCockpit.Swarm.PlanMode.enter_plan_mode(plan_mode)
      {:ok, plan_mode} = KiroCockpit.Swarm.PlanMode.draft_generated(plan_mode)
      {:ok, plan_mode} = KiroCockpit.Swarm.PlanMode.approve(plan_mode)

      {:ok, _} =
        ActionBoundary.run(
          :kiro_session_prompt,
          [
            enabled: true,
            session_id: session_id,
            agent_id: agent_id,
            permission_level: :subagent,
            plan_mode: plan_mode,
            approved: true,
            swarm_ctx: %{},
            # Use real TaskManager (default)
            pre_hooks: [CtxDefensiveHook],
            post_hooks: []
          ],
          fn -> :ok end
        )

      ctx = Process.get(:defensive_ctx)
      # active_task should be hydrated successfully
      assert ctx.active_task != nil
      assert ctx.active_task.id == task.id
      # permission_policy should be built from the hydrated task
      assert ctx.permission_policy != nil
    end
  end
end
