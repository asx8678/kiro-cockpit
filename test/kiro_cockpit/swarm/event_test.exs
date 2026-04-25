defmodule KiroCockpit.Swarm.EventTest do
  use ExUnit.Case, async: true

  alias KiroCockpit.Swarm.{Event, TraceContext}

  describe "new/2" do
    test "creates an event with required action_name" do
      event = Event.new(:file_write)

      assert %Event{} = event
      assert event.action_name == :file_write
      assert event.session_id == nil
      assert event.plan_id == nil
      assert event.task_id == nil
      assert event.agent_id == nil
      assert event.permission_level == nil
      assert event.payload == %{}
      assert event.raw_payload == %{}
      assert event.metadata == %{}
      assert event.trace_context == nil
    end

    test "accepts all optional fields via keyword" do
      tc = TraceContext.new()

      event =
        Event.new(:shell_exec,
          session_id: "sess_abc",
          plan_id: "plan_1",
          task_id: "task_1",
          agent_id: "agent_1",
          permission_level: :shell_write,
          payload: %{command: "ls"},
          raw_payload: %{raw: "ls -la"},
          metadata: %{source: "cli"},
          trace_context: tc
        )

      assert event.action_name == :shell_exec
      assert event.session_id == "sess_abc"
      assert event.plan_id == "plan_1"
      assert event.task_id == "task_1"
      assert event.agent_id == "agent_1"
      assert event.permission_level == :shell_write
      assert event.payload == %{command: "ls"}
      assert event.raw_payload == %{raw: "ls -la"}
      assert event.metadata == %{source: "cli"}
      assert event.trace_context == tc
    end

    test "defaults payload, raw_payload, and metadata to empty maps" do
      event = Event.new(:read)

      assert event.payload == %{}
      assert event.raw_payload == %{}
      assert event.metadata == %{}
    end
  end

  describe "struct enforce_keys" do
    test "action_name is required" do
      assert_raise ArgumentError, fn ->
        struct!(Event, %{})
      end
    end
  end
end
