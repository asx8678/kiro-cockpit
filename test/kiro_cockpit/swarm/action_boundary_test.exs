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
end
