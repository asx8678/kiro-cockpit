defmodule KiroCockpit.Swarm.BronzeActionBoundaryIntegrationTest do
  @moduledoc """
  Integration tests for Bronze action capture in ActionBoundary (§35 Phase 3).

  Verifies that ActionBoundary.run/3:
    * Records action_before before pre-hooks
    * Records action_after on successful completion
    * Records action_blocked when pre-hooks block
    * Persists all events with session/plan/task/agent correlation

  These tests exercise the full boundary flow with Bronze persistence.
  """

  use KiroCockpit.DataCase, async: true

  alias KiroCockpit.Swarm.{ActionBoundary, DataPipeline, Hook, HookResult}
  alias KiroCockpit.Swarm.Tasks.TaskManager

  # -- Test hooks -----------------------------------------------------------

  defmodule ContinueHook do
    @behaviour Hook

    @impl true
    def name, do: :continue_hook
    @impl true
    def priority, do: 50
    @impl true
    def filter(_event), do: true
    @impl true
    def on_event(event, _ctx) do
      HookResult.continue(event, ["continue passed"])
    end
  end

  defmodule BlockHook do
    @behaviour Hook

    @impl true
    def name, do: :block_hook
    @impl true
    def priority, do: 100
    @impl true
    def filter(_event), do: true
    @impl true
    def on_event(event, _ctx) do
      HookResult.block(event, "blocked for test", ["create a task before proceeding"])
    end
  end

  # -- Helpers --------------------------------------------------------------

  defp create_active_task!(session_id, agent_id, opts \\ []) do
    attrs = %{
      session_id: session_id,
      content: Keyword.get(opts, :content, "integration test task"),
      owner_id: agent_id,
      status: "in_progress",
      category: Keyword.get(opts, :category, "acting"),
      files_scope: Keyword.get(opts, :files_scope, [])
    }

    {:ok, task} = TaskManager.create(attrs)
    task
  end

  # -- Tests ----------------------------------------------------------------

  describe "ActionBoundary Bronze integration" do
    test "records action_before and action_after on successful execution" do
      session_id = "sess_integration_ok_#{System.unique_integer([:positive])}"
      plan_id = Ecto.UUID.generate()
      task_id = Ecto.UUID.generate()

      # Enable action capture
      original = Application.get_env(:kiro_cockpit, :bronze_action_capture_enabled, true)
      Application.put_env(:kiro_cockpit, :bronze_action_capture_enabled, true)

      result =
        ActionBoundary.run(
          :file_read,
          [
            enabled: true,
            session_id: session_id,
            agent_id: "integration-agent",
            plan_id: plan_id,
            task_id: task_id,
            permission_level: :read,
            pre_hooks: [ContinueHook],
            post_hooks: []
          ],
          fn -> {:file_contents, "test data"} end
        )

      # Restore config
      Application.put_env(:kiro_cockpit, :bronze_action_capture_enabled, original)

      assert {:ok, {:file_contents, "test data"}} = result

      # Both action_before and action_after should be recorded
      events = DataPipeline.list_action_events(session_id)
      assert length(events) == 2

      before_event = Enum.find(events, &(&1.event_type == "action_before"))
      after_event = Enum.find(events, &(&1.event_type == "action_after"))

      assert before_event != nil
      assert after_event != nil

      # Verify correlation is preserved
      assert before_event.session_id == session_id
      assert before_event.plan_id == plan_id
      assert before_event.task_id == task_id
      assert before_event.agent_id == "integration-agent"

      assert after_event.session_id == session_id
      assert after_event.plan_id == plan_id
      assert after_event.task_id == task_id

      # Verify result status is captured
      assert after_event.hook_results["result_status"] == "ok"
      assert after_event.hook_results["action_name"] == "file_read"
    end

    test "records action_blocked when pre-hooks block" do
      session_id = "sess_integration_block_#{System.unique_integer([:positive])}"
      plan_id = Ecto.UUID.generate()
      task_id = Ecto.UUID.generate()

      # Enable action capture
      original = Application.get_env(:kiro_cockpit, :bronze_action_capture_enabled, true)
      Application.put_env(:kiro_cockpit, :bronze_action_capture_enabled, true)

      result =
        ActionBoundary.run(
          :file_write,
          [
            enabled: true,
            session_id: session_id,
            agent_id: "integration-agent",
            plan_id: plan_id,
            task_id: task_id,
            permission_level: :write,
            pre_hooks: [BlockHook],
            post_hooks: []
          ],
          fn -> :should_not_execute end
        )

      # Restore config
      Application.put_env(:kiro_cockpit, :bronze_action_capture_enabled, original)

      assert {:error, {:swarm_blocked, "blocked for test", messages}} = result
      assert "create a task before proceeding" in messages

      # action_before and action_blocked should be recorded
      events = DataPipeline.list_action_events(session_id)
      assert length(events) == 2

      before_event = Enum.find(events, &(&1.event_type == "action_before"))
      blocked_event = Enum.find(events, &(&1.event_type == "action_blocked"))

      assert before_event != nil
      assert blocked_event != nil

      # Verify blocked event has reason and guidance
      assert blocked_event.hook_results["block_reason"] == "blocked for test"

      assert blocked_event.hook_results["guidance_messages"] == [
               "create a task before proceeding"
             ]

      assert blocked_event.hook_results["blocking_hook"] == "unknown"

      # Verify correlation is preserved in blocked event
      assert blocked_event.session_id == session_id
      assert blocked_event.plan_id == plan_id
      assert blocked_event.task_id == task_id
    end

    test "records lifecycle events via run_lifecycle_post_hooks" do
      session_id = "sess_lifecycle_#{System.unique_integer([:positive])}"
      plan_id = Ecto.UUID.generate()

      # Enable action capture
      original = Application.get_env(:kiro_cockpit, :bronze_action_capture_enabled, true)
      Application.put_env(:kiro_cockpit, :bronze_action_capture_enabled, true)

      # Run lifecycle post hooks
      :ok =
        ActionBoundary.run_lifecycle_post_hooks(
          :task_completed,
          enabled: true,
          session_id: session_id,
          agent_id: "lifecycle-agent",
          plan_id: plan_id,
          post_hooks: [ContinueHook]
        )

      # Restore config
      Application.put_env(:kiro_cockpit, :bronze_action_capture_enabled, original)

      # Should record action_before and action_after for lifecycle
      events = DataPipeline.list_action_events(session_id)
      assert length(events) == 2

      before_event = Enum.find(events, &(&1.event_type == "action_before"))
      after_event = Enum.find(events, &(&1.event_type == "action_after"))

      assert before_event != nil
      assert after_event != nil

      assert before_event.hook_results["action_name"] == "task_completed"
      assert after_event.hook_results["action_name"] == "task_completed"
    end

    test "does not record action events when capture is disabled" do
      session_id = "sess_disabled_#{System.unique_integer([:positive])}"

      # Disable action capture
      original = Application.get_env(:kiro_cockpit, :bronze_action_capture_enabled, true)
      Application.put_env(:kiro_cockpit, :bronze_action_capture_enabled, false)

      result =
        ActionBoundary.run(
          :test_action,
          [
            enabled: true,
            session_id: session_id,
            agent_id: "agent",
            pre_hooks: [ContinueHook],
            post_hooks: []
          ],
          fn -> :ok end
        )

      # Restore config
      Application.put_env(:kiro_cockpit, :bronze_action_capture_enabled, original)

      assert {:ok, :ok} = result

      # No action events should be recorded
      events = DataPipeline.list_action_events(session_id)
      assert length(events) == 0
    end

    test "correlation is preserved through action lifecycle" do
      session_id = "sess_corr_#{System.unique_integer([:positive])}"
      plan_id = Ecto.UUID.generate()
      _task_id = Ecto.UUID.generate()

      # Create active task for hydration test
      create_active_task!(session_id, "hydration-agent",
        content: "hydrated task",
        category: "acting"
      )

      # Enable action capture
      original = Application.get_env(:kiro_cockpit, :bronze_action_capture_enabled, true)
      Application.put_env(:kiro_cockpit, :bronze_action_capture_enabled, true)

      # Build approved plan_mode
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
            agent_id: "hydration-agent",
            # Only provide plan_id, task_id should be hydrated from active task
            plan_id: plan_id,
            permission_level: :subagent,
            plan_mode: plan_mode,
            approved: true,
            pre_hooks: [ContinueHook],
            post_hooks: []
          ],
          fn -> :executed end
        )

      # Restore config
      Application.put_env(:kiro_cockpit, :bronze_action_capture_enabled, original)

      assert {:ok, :executed} = result

      # Events should have hydrated correlation.
      # Note: create_active_task! may also record lifecycle action events,
      # so we filter for the boundary action specifically.
      events = DataPipeline.list_action_events(session_id)

      boundary_events =
        Enum.filter(events, fn e ->
          e.hook_results["action_name"] == "kiro_session_prompt"
        end)

      assert length(boundary_events) == 2

      for event <- boundary_events do
        assert event.session_id == session_id
        assert event.agent_id == "hydration-agent"
        # The task_id gets hydrated from active task
        assert event.task_id != nil
      end
    end

    test "hook_trace events are still recorded alongside action events" do
      session_id = "sess_both_#{System.unique_integer([:positive])}"

      # Enable action capture
      original = Application.get_env(:kiro_cockpit, :bronze_action_capture_enabled, true)
      Application.put_env(:kiro_cockpit, :bronze_action_capture_enabled, true)

      result =
        ActionBoundary.run(
          :test_action,
          [
            enabled: true,
            session_id: session_id,
            agent_id: "agent",
            pre_hooks: [ContinueHook],
            post_hooks: []
          ],
          fn -> :success end
        )

      # Restore config
      Application.put_env(:kiro_cockpit, :bronze_action_capture_enabled, original)

      assert {:ok, :success} = result

      # Should have both action events AND hook_trace events
      action_events = DataPipeline.list_action_events(session_id)
      # before + after
      assert length(action_events) == 2

      # Hook trace events from HookManager
      all_events = KiroCockpit.Swarm.Events.list_by_session(session_id)
      hook_traces = Enum.filter(all_events, &(&1.event_type == "hook_trace"))
      # Pre-hook trace
      assert length(hook_traces) >= 1
    end
  end
end
