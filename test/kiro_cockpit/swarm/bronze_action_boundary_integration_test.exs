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

  alias KiroCockpit.EventStore
  alias KiroCockpit.Swarm.{ActionBoundary, DataPipeline, Event, Hook, HookResult}
  alias KiroCockpit.Swarm.DataPipeline.{BronzeAcp, BronzeAction}
  alias KiroCockpit.Swarm.Events
  alias KiroCockpit.Swarm.PlanMode
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

  defp create_active_task!(session_id, agent_id, opts) do
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

  # Exception-safe Application env mutation: always restores original value
  # even if the test body raises. Module is async: true, so we must not
  # pollute other tests with stale config.
  defp with_env(key, value, fun) do
    original = Application.get_env(:kiro_cockpit, key, value)
    Application.put_env(:kiro_cockpit, key, value)

    try do
      fun.()
    after
      Application.put_env(:kiro_cockpit, key, original)
    end
  end

  # -- Tests ----------------------------------------------------------------

  describe "ActionBoundary Bronze integration" do
    test "records action_before and action_after on successful execution" do
      session_id = "sess_integration_ok_#{System.unique_integer([:positive])}"
      plan_id = Ecto.UUID.generate()
      task_id = Ecto.UUID.generate()

      with_env(:bronze_action_capture_enabled, true, fn ->
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

        assert {:ok, {:file_contents, "test data"}} = result

        # Both action_before and action_after should be recorded
        events = DataPipeline.list_action_events(session_id)
        types = events |> Enum.map(& &1.event_type) |> Enum.sort()
        assert ["action_after", "action_before"] = types

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
      end)
    end

    test "records action_blocked when pre-hooks block" do
      session_id = "sess_integration_block_#{System.unique_integer([:positive])}"
      plan_id = Ecto.UUID.generate()
      task_id = Ecto.UUID.generate()

      with_env(:bronze_action_capture_enabled, true, fn ->
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

        assert {:error, {:swarm_blocked, "blocked for test", messages}} = result
        assert "create a task before proceeding" in messages

        # action_before and action_blocked should be recorded
        events = DataPipeline.list_action_events(session_id)
        types = events |> Enum.map(& &1.event_type) |> Enum.sort()
        assert ["action_before", "action_blocked"] = types

        blocked_event = Enum.find(events, &(&1.event_type == "action_blocked"))

        assert blocked_event != nil
        assert blocked_event.hook_results["block_reason"] == "blocked for test"

        assert blocked_event.hook_results["guidance_messages"] ==
                 ["create a task before proceeding"]

        assert blocked_event.hook_results["blocking_hook"] == "unknown"

        # Verify correlation is preserved in blocked event
        assert blocked_event.session_id == session_id
        assert blocked_event.plan_id == plan_id
        assert blocked_event.task_id == task_id
      end)
    end

    test "records lifecycle events via run_lifecycle_post_hooks" do
      session_id = "sess_lifecycle_#{System.unique_integer([:positive])}"
      plan_id = Ecto.UUID.generate()

      with_env(:bronze_action_capture_enabled, true, fn ->
        :ok =
          ActionBoundary.run_lifecycle_post_hooks(
            :task_completed,
            enabled: true,
            session_id: session_id,
            agent_id: "lifecycle-agent",
            plan_id: plan_id,
            post_hooks: [ContinueHook]
          )

        # Should record action_before and action_after for lifecycle
        events = DataPipeline.list_action_events(session_id)
        types = events |> Enum.map(& &1.event_type) |> Enum.sort()
        assert ["action_after", "action_before"] = types

        before_event = Enum.find(events, &(&1.event_type == "action_before"))
        after_event = Enum.find(events, &(&1.event_type == "action_after"))

        assert before_event != nil
        assert after_event != nil
        assert before_event.hook_results["action_name"] == "task_completed"
        assert after_event.hook_results["action_name"] == "task_completed"
      end)
    end

    test "does not record action events when capture is disabled" do
      session_id = "sess_disabled_#{System.unique_integer([:positive])}"

      with_env(:bronze_action_capture_enabled, false, fn ->
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

        assert {:ok, :ok} = result

        # No action events should be recorded
        events = DataPipeline.list_action_events(session_id)
        assert [] = events
      end)
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

      with_env(:bronze_action_capture_enabled, true, fn ->
        # Build approved plan_mode
        plan_mode = PlanMode.new()
        {:ok, plan_mode} = PlanMode.enter_plan_mode(plan_mode)
        {:ok, plan_mode} = PlanMode.draft_generated(plan_mode)
        {:ok, plan_mode} = PlanMode.approve(plan_mode)

        result =
          ActionBoundary.run(
            :kiro_session_prompt,
            [
              enabled: true,
              session_id: session_id,
              agent_id: "hydration-agent",
              plan_id: plan_id,
              permission_level: :subagent,
              plan_mode: plan_mode,
              approved: true,
              pre_hooks: [ContinueHook],
              post_hooks: []
            ],
            fn -> :executed end
          )

        assert {:ok, :executed} = result

        # Events should have hydrated correlation.
        # Note: create_active_task! may also record lifecycle action events,
        # so we filter for the boundary action specifically.
        events = DataPipeline.list_action_events(session_id)

        boundary_events =
          Enum.filter(events, fn e ->
            e.hook_results["action_name"] == "kiro_session_prompt"
          end)

        assert [_, _] = boundary_events

        for event <- boundary_events do
          assert event.session_id == session_id
          assert event.agent_id == "hydration-agent"
          assert event.task_id != nil
        end
      end)
    end

    test "hook_trace events are still recorded alongside action events" do
      session_id = "sess_both_#{System.unique_integer([:positive])}"

      with_env(:bronze_action_capture_enabled, true, fn ->
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

        assert {:ok, :success} = result

        # Should have both action events AND hook_trace events
        action_events = DataPipeline.list_action_events(session_id)
        assert [_, _] = action_events

        # Hook trace events from HookManager
        all_events = Events.list_by_session(session_id)
        hook_traces = Enum.filter(all_events, &(&1.event_type == "hook_trace"))
        assert [_ | _] = hook_traces
      end)
    end

    test "action_after records error status when executor returns {:error, reason}" do
      session_id = "sess_exec_error_#{System.unique_integer([:positive])}"

      with_env(:bronze_action_capture_enabled, true, fn ->
        result =
          ActionBoundary.run(
            :failing_action,
            [
              enabled: true,
              session_id: session_id,
              agent_id: "error-agent",
              pre_hooks: [ContinueHook],
              post_hooks: []
            ],
            fn -> {:error, :executor_failed} end
          )

        # Boundary returns {:ok, {:error, ...}} because it didn't block
        assert {:ok, {:error, :executor_failed}} = result

        # action_before and action_after should be recorded
        events = DataPipeline.list_action_events(session_id)
        assert [_, _] = events

        after_event = Enum.find(events, &(&1.event_type == "action_after"))
        assert after_event != nil

        # Bronze result_status must be "error", not "ok"
        assert after_event.hook_results["result_status"] == "error"
      end)
    end
  end

  describe "BronzeAction extract_result_summary for {:blocked, reason, messages}" do
    test "lifecycle blocked result records result_status as blocked" do
      session_id = "sess_lifecycle_blocked_#{System.unique_integer([:positive])}"

      with_env(:bronze_action_capture_enabled, true, fn ->
        :ok =
          ActionBoundary.run_lifecycle_post_hooks(
            :task_blocked,
            enabled: true,
            session_id: session_id,
            agent_id: "blocked-agent",
            post_hooks: [BlockHook]
          )

        events = DataPipeline.list_action_events(session_id)
        after_event = Enum.find(events, &(&1.event_type == "action_after"))

        assert after_event != nil
        # The key regression: result_status must be "blocked", not "error"
        assert after_event.hook_results["result_status"] == "blocked"
      end)
    end

    test "BronzeAction.record_after handles {:blocked, reason, messages} result" do
      session_id = "sess_bronze_blocked_#{System.unique_integer([:positive])}"

      event = %Event{
        action_name: :test_blocked,
        session_id: session_id,
        agent_id: "test-agent",
        plan_id: nil,
        task_id: nil,
        permission_level: nil,
        payload: %{},
        raw_payload: %{},
        metadata: %{}
      }

      :ok = BronzeAction.record_after(event, {:blocked, "post-hook blocked", []})

      events = DataPipeline.list_action_events(session_id)
      after_event = Enum.find(events, &(&1.event_type == "action_after"))

      assert after_event != nil
      assert after_event.hook_results["result_status"] == "blocked"
    end
  end

  describe "BronzeAcp missing mandatory IDs" do
    test "record_acp_update rejects nil session_id without inventing unknown" do
      attrs = %{
        # session_id intentionally nil
        agent_id: "test-agent",
        payload: %{"method" => "test"},
        event_type: "acp_update"
      }

      :ok = BronzeAcp.record_acp_update(attrs)

      # No acp_* events should be persisted with fake IDs
      events = Events.list_by_session("unknown")

      acp_events =
        Enum.filter(
          events,
          &(&1.event_type in ["acp_update", "acp_request", "acp_response", "acp_notification"])
        )

      assert Enum.all?(acp_events, &(&1.session_id != "unknown"))
    end

    test "record_acp_update rejects nil agent_id without inventing unknown" do
      session_id = "sess_no_agent_#{System.unique_integer([:positive])}"

      attrs = %{
        session_id: session_id,
        # agent_id intentionally nil
        payload: %{"method" => "test"},
        event_type: "acp_update"
      }

      :ok = BronzeAcp.record_acp_update(attrs)

      # No events should be recorded for this session
      events = BronzeAcp.list_acp_events(session_id)
      assert [] = events
    end

    test "record_acp_update rejects empty string session_id" do
      attrs = %{
        session_id: "",
        agent_id: "test-agent",
        payload: %{"method" => "test"},
        event_type: "acp_update"
      }

      :ok = BronzeAcp.record_acp_update(attrs)

      # No events with empty session_id
      events = Events.list_by_session("")

      acp_events =
        Enum.filter(
          events,
          &(&1.event_type in ["acp_update", "acp_request", "acp_response", "acp_notification"])
        )

      assert [] = acp_events
    end

    test "record_acp_request with valid IDs persists correctly" do
      session_id = "sess_valid_#{System.unique_integer([:positive])}"

      payload = %{"jsonrpc" => "2.0", "method" => "tools/call", "id" => 1}

      :ok =
        BronzeAcp.record_acp_request(
          session_id,
          "test-agent",
          payload,
          method: "tools/call"
        )

      events = BronzeAcp.list_acp_events(session_id)
      assert [%{event_type: "acp_request"}] = events
      assert hd(events).session_id == session_id
      assert hd(events).agent_id == "test-agent"
    end
  end

  describe "ACP Bronze persistence path via EventStore" do
    test "outbound ACP request creates both raw_acp_message and swarm_event acp rows" do
      session_id = "sess_bronze_out_#{System.unique_integer([:positive])}"

      payload = %{
        "jsonrpc" => "2.0",
        "id" => 42,
        "method" => "tools/call",
        "params" => %{"name" => "fs/read"}
      }

      with_env(:bronze_acp_capture_enabled, true, fn ->
        # Record via EventStore (raw row)
        {:ok, _msg} =
          EventStore.record_acp_message(
            "client_to_agent",
            payload,
            session_id: session_id
          )

        # Record via BronzeAcp (correlation row)
        :ok =
          BronzeAcp.record_acp_request(
            session_id,
            "integration-agent",
            payload,
            method: "tools/call",
            rpc_id: "42"
          )

        # Verify raw_acp_message row exists
        raw_msgs = EventStore.list_acp_messages(session_id)
        assert [_ | _] = raw_msgs
        first_raw = hd(raw_msgs)
        assert first_raw.direction == "client_to_agent"
        assert first_raw.message_type == "request"

        # Verify swarm_event acp_* row exists
        acp_events = BronzeAcp.list_acp_events(session_id)
        assert [_ | _] = acp_events
        first_acp = hd(acp_events)
        assert first_acp.event_type == "acp_request"
        assert first_acp.session_id == session_id
        assert first_acp.agent_id == "integration-agent"
      end)
    end

    test "inbound ACP response creates both raw_acp_message and swarm_event acp rows" do
      session_id = "sess_bronze_in_#{System.unique_integer([:positive])}"

      payload = %{
        "jsonrpc" => "2.0",
        "id" => 42,
        "result" => %{"content" => "file data"}
      }

      with_env(:bronze_acp_capture_enabled, true, fn ->
        # Record via EventStore (raw row)
        {:ok, _msg} =
          EventStore.record_acp_message(
            "agent_to_client",
            payload,
            session_id: session_id
          )

        # Record via BronzeAcp (correlation row)
        :ok =
          BronzeAcp.record_acp_response(
            session_id,
            "integration-agent",
            payload,
            rpc_id: "42"
          )

        # Verify raw_acp_message row exists
        raw_msgs = EventStore.list_acp_messages(session_id)
        assert [_ | _] = raw_msgs
        first_raw = hd(raw_msgs)
        assert first_raw.direction == "agent_to_client"
        assert first_raw.message_type == "response"

        # Verify swarm_event acp_* row exists
        acp_events = BronzeAcp.list_acp_events(session_id)
        assert [_ | _] = acp_events
        first_acp = hd(acp_events)
        assert first_acp.event_type == "acp_response"
      end)
    end

    test "inbound ACP notification creates both raw_acp_message and swarm_event acp rows" do
      session_id = "sess_bronze_notif_#{System.unique_integer([:positive])}"

      payload = %{
        "jsonrpc" => "2.0",
        "method" => "session/update",
        "params" => %{"delta" => "text"}
      }

      with_env(:bronze_acp_capture_enabled, true, fn ->
        # Record via EventStore (raw row)
        {:ok, _msg} =
          EventStore.record_acp_message(
            "agent_to_client",
            payload,
            session_id: session_id
          )

        # Record via BronzeAcp (correlation row)
        :ok =
          BronzeAcp.record_acp_notification(
            session_id,
            "integration-agent",
            payload,
            method: "session/update",
            direction: :agent_to_client
          )

        # Verify raw_acp_message row exists
        raw_msgs = EventStore.list_acp_messages(session_id)
        assert [_ | _] = raw_msgs
        first_raw = hd(raw_msgs)
        assert first_raw.direction == "agent_to_client"
        assert first_raw.message_type == "notification"

        # Verify swarm_event acp_* row exists
        acp_events = BronzeAcp.list_acp_events(session_id)
        assert [_ | _] = acp_events
        first_acp = hd(acp_events)
        assert first_acp.event_type == "acp_notification"
      end)
    end
  end

  describe "client_to_agent response/error Bronze classification (regression)" do
    test "client_to_agent JSON-RPC response records as acp_response, not acp_update" do
      session_id = "sess_cta_resp_#{System.unique_integer([:positive])}"

      # Simulate a client→agent response (e.g. tool callback result echoed back)
      payload = %{
        "jsonrpc" => "2.0",
        "id" => 10,
        "result" => %{"content" => "file contents"}
      }

      with_env(:bronze_acp_capture_enabled, true, fn ->
        # Persist as client_to_agent (direction the response flows on wire)
        {:ok, _msg} =
          EventStore.record_acp_message(
            "client_to_agent",
            payload,
            session_id: session_id
          )

        :ok =
          BronzeAcp.record_acp_response(
            session_id,
            "integration-agent",
            payload,
            direction: :client_to_agent,
            rpc_id: "10"
          )

        acp_events = BronzeAcp.list_acp_events(session_id)
        assert [_ | _] = acp_events
        first_acp = hd(acp_events)

        # Key regression: event_type must be "acp_response", NOT "acp_update"
        assert first_acp.event_type == "acp_response"
        assert first_acp.session_id == session_id

        # Verify direction is preserved
        hook_results = first_acp.hook_results || %{}
        assert hook_results["direction"] == "client_to_agent"
      end)
    end

    test "client_to_agent JSON-RPC error records as acp_response, not acp_update" do
      session_id = "sess_cta_err_#{System.unique_integer([:positive])}"

      # Simulate a client→agent error response (e.g. denied callback)
      payload = %{
        "jsonrpc" => "2.0",
        "id" => 11,
        "error" => %{"code" => -32_603, "message" => "Internal error"}
      }

      with_env(:bronze_acp_capture_enabled, true, fn ->
        {:ok, _msg} =
          EventStore.record_acp_message(
            "client_to_agent",
            payload,
            session_id: session_id
          )

        :ok =
          BronzeAcp.record_acp_response(
            session_id,
            "integration-agent",
            payload,
            direction: :client_to_agent,
            rpc_id: "11"
          )

        acp_events = BronzeAcp.list_acp_events(session_id)
        assert [_ | _] = acp_events
        first_acp = hd(acp_events)

        # Key regression: event_type must be "acp_response", NOT "acp_update"
        assert first_acp.event_type == "acp_response"

        hook_results = first_acp.hook_results || %{}
        assert hook_results["direction"] == "client_to_agent"
      end)
    end
  end
end
