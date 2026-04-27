defmodule KiroCockpit.Swarm.DataPipeline.BronzeActionTest do
  @moduledoc """
  Tests for Bronze action capture (§35 Phase 3).

  Covers:
    * action_before recording with correlation
    * action_after recording with result status
    * action_blocked recording with reason and guidance
    * Payload summarization and privacy
    * Query functions for action events
    * Fail-closed persistence (errors don't crash)
  """

  use KiroCockpit.DataCase, async: true

  alias KiroCockpit.Swarm.{DataPipeline.BronzeAction, Event, Events}

  describe "record_before/2" do
    test "records action_before with full correlation" do
      session_id = "sess_before_#{System.unique_integer([:positive])}"
      plan_id = Ecto.UUID.generate()
      task_id = Ecto.UUID.generate()

      event =
        Event.new(:file_write,
          session_id: session_id,
          plan_id: plan_id,
          task_id: task_id,
          agent_id: "test-agent",
          permission_level: :write,
          payload: %{path: "/tmp/test.txt", content: "hello"}
        )

      assert :ok = BronzeAction.record_before(event, %{safe: true})

      [recorded] = BronzeAction.list_actions(session_id)
      assert recorded.event_type == "action_before"
      assert recorded.session_id == session_id
      assert recorded.plan_id == plan_id
      assert recorded.task_id == task_id
      assert recorded.agent_id == "test-agent"
      assert recorded.phase == "pre"

      # Verify hook_results contains correlation
      hook_results = recorded.hook_results
      assert hook_results["action_name"] == "file_write"
      assert hook_results["permission_level"] == "write"
      assert hook_results["correlation"]["session_id"] == session_id
      assert hook_results["correlation"]["plan_id"] == plan_id
      assert hook_results["correlation"]["task_id"] == task_id
    end

    test "records action_before with payload summary by default" do
      session_id = "sess_summary_#{System.unique_integer([:positive])}"

      event =
        Event.new(:file_write,
          session_id: session_id,
          agent_id: "test-agent",
          payload: %{path: "/tmp/test.txt", content: "sensitive data here"}
        )

      assert :ok = BronzeAction.record_before(event, %{})

      [recorded] = BronzeAction.list_actions(session_id)

      # Payload should be a summary, not the full content
      assert recorded.payload["type"] == "payload_summary"
      assert recorded.payload["keys"] == ["path", "content"]
      assert recorded.payload["size"] == 2

      # Raw payload should also be a summary
      assert recorded.raw_payload["type"] == "raw_payload_summary"
    end

    test "records action_before with full payload when safe: true" do
      session_id = "sess_full_#{System.unique_integer([:positive])}"

      event =
        Event.new(:file_write,
          session_id: session_id,
          agent_id: "test-agent",
          payload: %{path: "/tmp/test.txt"}
        )

      assert :ok = BronzeAction.record_before(event, %{safe: true})

      [recorded] = BronzeAction.list_actions(session_id)

      # Full payload captured when safe
      assert recorded.payload["path"] == "/tmp/test.txt"
      refute recorded.payload["type"] == "payload_summary"
    end

    test "handles event without correlation IDs" do
      session_id = "sess_no_corr_#{System.unique_integer([:positive])}"

      event =
        Event.new(:system_cleanup,
          session_id: session_id,
          agent_id: "system-agent"
        )

      assert :ok = BronzeAction.record_before(event, %{})

      [recorded] = BronzeAction.list_actions(session_id)
      assert recorded.event_type == "action_before"
      assert recorded.plan_id == nil
      assert recorded.task_id == nil
    end

    test "emits telemetry on persistence error without crashing" do
      # Create an invalid event (nil session_id will fail validation)
      event = Event.new(:test_action, session_id: nil, agent_id: nil)

      # Should return :ok even though persistence fails
      assert :ok = BronzeAction.record_before(event, %{})
    end
  end

  describe "record_after/3" do
    test "records action_after with ok result" do
      session_id = "sess_after_ok_#{System.unique_integer([:positive])}"

      event =
        Event.new(:file_read,
          session_id: session_id,
          agent_id: "test-agent",
          plan_id: Ecto.UUID.generate(),
          task_id: Ecto.UUID.generate()
        )

      result = {:ok, "file contents here"}

      assert :ok = BronzeAction.record_after(event, result, %{safe: true})

      [recorded] = BronzeAction.list_actions(session_id)
      assert recorded.event_type == "action_after"
      assert recorded.phase == "post"

      hook_results = recorded.hook_results
      assert hook_results["result_status"] == "ok"
      assert hook_results["output_summary"] =~ "string:"
    end

    test "records action_after with blocked result" do
      session_id = "sess_after_blocked_#{System.unique_integer([:positive])}"

      event =
        Event.new(:file_write,
          session_id: session_id,
          agent_id: "test-agent"
        )

      result = {:error, {:swarm_blocked, "no active task", ["create a task first"]}}

      assert :ok = BronzeAction.record_after(event, result, %{})

      [recorded] = BronzeAction.list_actions(session_id)
      assert recorded.event_type == "action_after"

      hook_results = recorded.hook_results
      assert hook_results["result_status"] == "blocked"
      assert hook_results["output_summary"] =~ "blocked:"
    end

    test "records action_after with error result" do
      session_id = "sess_after_error_#{System.unique_integer([:positive])}"

      event =
        Event.new(:shell_exec,
          session_id: session_id,
          agent_id: "test-agent"
        )

      result = {:error, :command_failed}

      assert :ok = BronzeAction.record_after(event, result, %{})

      [recorded] = BronzeAction.list_actions(session_id)
      assert recorded.event_type == "action_after"

      hook_results = recorded.hook_results
      assert hook_results["result_status"] == "error"
    end

    test "records both before and after for complete lifecycle" do
      session_id = "sess_lifecycle_#{System.unique_integer([:positive])}"
      plan_id = Ecto.UUID.generate()
      task_id = Ecto.UUID.generate()

      event =
        Event.new(:kiro_session_prompt,
          session_id: session_id,
          agent_id: "kiro-agent",
          plan_id: plan_id,
          task_id: task_id,
          permission_level: :write
        )

      # Record before
      assert :ok = BronzeAction.record_before(event, %{})

      # Record after
      result = {:ok, :prompt_completed}
      assert :ok = BronzeAction.record_after(event, result, %{})

      # Both events should be recorded
      events = BronzeAction.list_actions(session_id)
      assert length(events) == 2

      # list_actions returns events ordered by created_at (descending from
      # list_recent), so use Enum.find instead of positional destructuring.
      before_event = Enum.find(events, &(&1.event_type == "action_before"))
      after_event = Enum.find(events, &(&1.event_type == "action_after"))

      assert before_event.event_type == "action_before"
      assert after_event.event_type == "action_after"

      # Both should have same correlation
      assert before_event.plan_id == plan_id
      assert after_event.plan_id == plan_id
      assert before_event.task_id == task_id
      assert after_event.task_id == task_id
    end
  end

  describe "record_blocked/5" do
    test "records action_blocked with reason and guidance" do
      session_id = "sess_blocked_#{System.unique_integer([:positive])}"

      event =
        Event.new(:file_write,
          session_id: session_id,
          agent_id: "test-agent"
        )

      reason = "no active task for session"
      messages = ["create a task first", "use task_manager.create/1"]

      assert :ok =
               BronzeAction.record_blocked(event, reason, messages, %{},
                 blocking_hook: "TaskEnforcementHook"
               )

      [recorded] = BronzeAction.list_actions(session_id)
      assert recorded.event_type == "action_blocked"
      assert recorded.phase == "pre"

      hook_results = recorded.hook_results
      assert hook_results["block_reason"] == reason
      assert hook_results["guidance_messages"] == messages
      assert hook_results["blocking_hook"] == "TaskEnforcementHook"
    end

    test "records action_blocked without optional opts" do
      session_id = "sess_blocked_minimal_#{System.unique_integer([:positive])}"

      event =
        Event.new(:shell_exec,
          session_id: session_id,
          agent_id: "test-agent"
        )

      assert :ok = BronzeAction.record_blocked(event, "blocked", ["reason"], %{})

      [recorded] = BronzeAction.list_actions(session_id)
      assert recorded.event_type == "action_blocked"
    end
  end

  describe "query functions" do
    test "list_actions returns only action events for session" do
      session_id = "sess_query_#{System.unique_integer([:positive])}"
      other_session = "sess_other_#{System.unique_integer([:positive])}"

      # Create action events
      event1 = Event.new(:file_read, session_id: session_id, agent_id: "agent")
      BronzeAction.record_before(event1, %{})

      event2 = Event.new(:file_write, session_id: other_session, agent_id: "agent")
      BronzeAction.record_before(event2, %{})

      # Create a non-action event (hook_trace)
      Events.create_event(%{
        session_id: session_id,
        agent_id: "agent",
        event_type: "hook_trace",
        payload: %{},
        raw_payload: %{},
        hook_results: []
      })

      actions = BronzeAction.list_actions(session_id)
      assert length(actions) == 1
      assert hd(actions).session_id == session_id
    end

    test "list_actions_by_plan returns action events for plan" do
      plan_id = Ecto.UUID.generate()
      other_plan = Ecto.UUID.generate()

      event1 =
        Event.new(:file_read,
          session_id: "sess1",
          agent_id: "agent",
          plan_id: plan_id
        )

      BronzeAction.record_before(event1, %{})

      event2 =
        Event.new(:file_write,
          session_id: "sess2",
          agent_id: "agent",
          plan_id: other_plan
        )

      BronzeAction.record_before(event2, %{})

      actions = BronzeAction.list_actions_by_plan(plan_id)
      assert length(actions) == 1
      assert hd(actions).plan_id == plan_id
    end

    test "list_actions_by_task returns action events for task" do
      task_id = Ecto.UUID.generate()

      event =
        Event.new(:file_read,
          session_id: "sess",
          agent_id: "agent",
          plan_id: Ecto.UUID.generate(),
          task_id: task_id
        )

      BronzeAction.record_before(event, %{})

      actions = BronzeAction.list_actions_by_task(task_id)
      assert length(actions) == 1
      assert hd(actions).task_id == task_id
    end
  end

  describe "payload summarization" do
    test "summarizes large payloads with keys and size" do
      session_id = "sess_large_#{System.unique_integer([:positive])}"

      large_payload =
        for i <- 1..100, into: %{} do
          {"key_#{i}", "value_#{i}_#{String.duplicate("x", 100)}"}
        end

      event =
        Event.new(:large_action,
          session_id: session_id,
          agent_id: "test-agent",
          payload: large_payload
        )

      BronzeAction.record_before(event, %{})

      [recorded] = BronzeAction.list_actions(session_id)
      assert recorded.payload["size"] == 100
      assert length(recorded.payload["keys"]) == 100
      assert recorded.payload["type"] == "payload_summary"
    end

    test "handles non-map payloads gracefully" do
      session_id = "sess_bad_payload_#{System.unique_integer([:positive])}"

      # Create event with nil payload (edge case)
      event =
        Event.new(:edge_case,
          session_id: session_id,
          agent_id: "test-agent"
        )

      # Manually set payload to nil to test edge case
      event = %{event | payload: nil}

      assert :ok = BronzeAction.record_before(event, %{})

      [recorded] = BronzeAction.list_actions(session_id)
      assert recorded.payload == %{}
    end

    test "truncates long strings in summaries" do
      session_id = "sess_truncate_#{System.unique_integer([:positive])}"

      event =
        Event.new(:test_action,
          session_id: session_id,
          agent_id: "test-agent"
        )

      long_reason = String.duplicate("x", 500)
      result = {:error, {:swarm_blocked, long_reason, []}}

      BronzeAction.record_after(event, result, %{})

      [recorded] = BronzeAction.list_actions(session_id)
      output = recorded.hook_results["output_summary"]

      # Should be truncated
      assert byte_size(output) < 500
      assert String.ends_with?(output, "...")
    end
  end

  describe "global configuration" do
    test "respects bronze_full_payload_capture config" do
      # Temporarily enable full capture
      original = Application.get_env(:kiro_cockpit, :bronze_full_payload_capture, false)
      Application.put_env(:kiro_cockpit, :bronze_full_payload_capture, true)

      session_id = "sess_config_#{System.unique_integer([:positive])}"

      event =
        Event.new(:test_action,
          session_id: session_id,
          agent_id: "test-agent",
          payload: %{secret: "data"}
        )

      # Without safe: true, should still capture full due to config
      BronzeAction.record_before(event, %{})

      [recorded] = BronzeAction.list_actions(session_id)

      # Restore config
      Application.put_env(:kiro_cockpit, :bronze_full_payload_capture, original)

      # Payload should be full, not summary
      assert recorded.payload["secret"] == "data"
    end
  end
end
