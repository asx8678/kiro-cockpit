defmodule KiroCockpit.Swarm.HookResultTest do
  use ExUnit.Case, async: true

  alias KiroCockpit.Swarm.{Event, HookResult}

  describe "continue/3" do
    test "creates a continue result with event" do
      event = Event.new(:read)
      result = HookResult.continue(event)

      assert result.decision == :continue
      assert result.event == event
      assert result.messages == []
      assert result.reason == nil
      assert result.hook_metadata == %{}
    end

    test "creates a continue result with messages" do
      event = Event.new(:read)
      result = HookResult.continue(event, ["ok"])

      assert result.messages == ["ok"]
    end

    test "creates a continue result with hook_metadata" do
      event = Event.new(:read)
      result = HookResult.continue(event, [], hook_metadata: %{latency_ms: 12})

      assert result.hook_metadata == %{latency_ms: 12}
    end
  end

  describe "modify/3" do
    test "creates a modify result with modified event" do
      event = Event.new(:file_write)
      modified = %Event{event | payload: %{redacted: true}}
      result = HookResult.modify(modified, ["payload redacted"])

      assert result.decision == :modify
      assert result.event == modified
      assert result.messages == ["payload redacted"]
      assert result.reason == nil
    end

    test "creates a modify result with hook_metadata" do
      event = Event.new(:file_write)
      result = HookResult.modify(event, [], hook_metadata: %{fields_redacted: 3})

      assert result.hook_metadata == %{fields_redacted: 3}
    end
  end

  describe "block/4" do
    test "creates a block result with reason" do
      event = Event.new(:destructive_rm)
      result = HookResult.block(event, "Destructive action not permitted")

      assert result.decision == :block
      assert result.event == event
      assert result.reason == "Destructive action not permitted"
      assert result.messages == []
    end

    test "creates a block result with messages and metadata" do
      event = Event.new(:shell_write)

      result =
        HookResult.block(event, "No active task", ["task required"],
          hook_metadata: %{code: :no_task}
        )

      assert result.reason == "No active task"
      assert result.messages == ["task required"]
      assert result.hook_metadata == %{code: :no_task}
    end

    test "requires reason to be a string" do
      event = Event.new(:read)

      assert_raise FunctionClauseError, fn ->
        HookResult.block(event, nil)
      end
    end
  end

  describe "blocked?/1" do
    test "returns true for block decisions" do
      event = Event.new(:read)
      result = HookResult.block(event, "blocked")

      assert HookResult.blocked?(result) == true
    end

    test "returns false for continue decisions" do
      event = Event.new(:read)
      result = HookResult.continue(event)

      assert HookResult.blocked?(result) == false
    end

    test "returns false for modify decisions" do
      event = Event.new(:read)
      result = HookResult.modify(event)

      assert HookResult.blocked?(result) == false
    end
  end

  describe "List.wrap for messages" do
    test "single string message is wrapped in a list" do
      event = Event.new(:read)
      result = HookResult.continue(event, "single")

      assert result.messages == ["single"]
    end
  end
end
