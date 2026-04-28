defmodule KiroCockpit.PuppyBrain.HistoryCompactorTest do
  use ExUnit.Case, async: true

  alias KiroCockpit.PuppyBrain.{HistoryCompactor, ModelProfile}

  # -- Helpers --------------------------------------------------------------

  defp user_msg(content, metadata \\ %{}) do
    %{"role" => "user", "content" => content, "metadata" => metadata}
  end

  defp assistant_msg(content, metadata \\ %{}) do
    %{"role" => "assistant", "content" => content, "metadata" => metadata}
  end

  defp system_msg(content, metadata) do
    %{"role" => "system", "content" => content, "metadata" => metadata}
  end

  defp tool_call_msg(call_id, fn_name, args) do
    %{
      "role" => "assistant",
      "content" => nil,
      "tool_calls" => [
        %{"id" => call_id, "function" => %{"name" => fn_name, "arguments" => args}}
      ]
    }
  end

  defp tool_result_msg(call_id, result) do
    %{
      "role" => "tool",
      "tool_call_id" => call_id,
      "content" => result
    }
  end

  defp pending_permission_msg do
    user_msg("please approve", %{
      "permission_request" => %{"status" => "pending", "tool" => "shell_exec"}
    })
  end

  defp resolved_permission_msg do
    user_msg("approved", %{
      "permission_request" => %{"status" => "resolved", "tool" => "shell_exec"}
    })
  end

  # -- estimate_tokens/1 ----------------------------------------------------

  describe "estimate_tokens/1" do
    test "returns 0 for empty list" do
      assert HistoryCompactor.estimate_tokens([]) == 0
    end

    test "returns 0 for non-list input" do
      assert HistoryCompactor.estimate_tokens(nil) == 0
    end

    test "returns positive count for messages with content" do
      tokens = HistoryCompactor.estimate_tokens([user_msg("Hello, world!")])
      assert tokens > 0
    end

    test "more content means more tokens" do
      short = HistoryCompactor.estimate_tokens([user_msg("hi")])
      long = HistoryCompactor.estimate_tokens([user_msg(String.duplicate("x", 1000))])
      assert long > short
    end
  end

  # -- needs_compaction?/3 --------------------------------------------------

  describe "needs_compaction?/3" do
    test "returns false when messages fit in budget" do
      messages = [user_msg("short")]
      refute HistoryCompactor.needs_compaction?(messages, nil, max_tokens: 100_000)
    end

    test "returns true when messages exceed budget" do
      long_msg = user_msg(String.duplicate("a", 100_000))
      assert HistoryCompactor.needs_compaction?([long_msg], nil, max_tokens: 100)
    end
  end

  # -- compact/3 core behavior ----------------------------------------------

  describe "compact/3" do
    test "does not compact when messages fit in budget" do
      messages = [user_msg("hello"), assistant_msg("world")]
      {compactor, summary} = HistoryCompactor.compact(messages, nil, max_tokens: 100_000)

      assert summary.compacted == false
      assert summary.preserved == 2
      assert summary.summarized == 0
      assert compactor.messages == messages
    end

    test "preserves active plan messages during compaction" do
      plan_msg = user_msg("active plan", %{"plan_id" => "plan_42"})
      filler = for _ <- 1..50, do: user_msg(String.duplicate("filler ", 200))
      messages = filler ++ [plan_msg]

      {compactor, _summary} = HistoryCompactor.compact(messages, nil, max_tokens: 500)

      assert Enum.any?(compactor.messages, fn msg ->
               get_in(msg, ["metadata", "plan_id"]) == "plan_42"
             end)
    end

    test "preserves active task messages during compaction" do
      task_msg = assistant_msg("doing task", %{"task_id" => "task_7"})
      filler = for _ <- 1..50, do: user_msg(String.duplicate("filler ", 200))
      messages = filler ++ [task_msg]

      {compactor, _summary} = HistoryCompactor.compact(messages, nil, max_tokens: 500)

      assert Enum.any?(compactor.messages, fn msg ->
               get_in(msg, ["metadata", "task_id"]) == "task_7"
             end)
    end

    test "preserves unresolved permission requests during compaction" do
      # Unresolved permission request should never be dropped.
      perm_msg = pending_permission_msg()
      filler = for _ <- 1..50, do: user_msg(String.duplicate("filler ", 200))
      messages = filler ++ [perm_msg]

      {compactor, _summary} = HistoryCompactor.compact(messages, nil, max_tokens: 500)

      assert Enum.any?(compactor.messages, fn msg ->
               get_in(msg, ["metadata", "permission_request", "status"]) == "pending"
             end)
    end

    test "resolved permission requests can be compacted" do
      # Resolved permissions are not "must keep" — they can be summarized.
      resolved_msg = resolved_permission_msg()
      filler = for _ <- 1..50, do: user_msg(String.duplicate("filler ", 200))
      messages = [resolved_msg | filler]

      {compactor, summary} = HistoryCompactor.compact(messages, nil, max_tokens: 500)

      # Resolved permission may or may not survive depending on position,
      # but the key invariant is unresolved ones ALWAYS survive.
      assert is_list(compactor.messages)
      assert summary.compacted == true
    end

    test "preserves last project_snapshot_hash during compaction" do
      hash_msg = system_msg("snapshot baseline", %{"project_snapshot_hash" => "abc123def"})
      filler = for _ <- 1..50, do: user_msg(String.duplicate("filler ", 200))
      messages = filler ++ [hash_msg]

      {compactor, _summary} = HistoryCompactor.compact(messages, nil, max_tokens: 500)

      assert Enum.any?(compactor.messages, fn msg ->
               get_in(msg, ["metadata", "project_snapshot_hash"]) == "abc123def"
             end)
    end

    test "keeps tool-call/result pairs intact" do
      call = tool_call_msg("call_1", "read_file", "{\"path\": \"/tmp/x\"}")
      result = tool_result_msg("call_1", "file contents here")
      filler = for _ <- 1..50, do: user_msg(String.duplicate("filler ", 200))
      # Tool pair is in the "older" section — should still be kept together.
      messages = [call, result | filler]

      {compactor, _summary} = HistoryCompactor.compact(messages, nil, max_tokens: 2000)

      # If either the call or the result is present, both must be present.
      has_call = Enum.any?(compactor.messages, &Map.has_key?(&1, "tool_calls"))
      has_result = Enum.any?(compactor.messages, &Map.has_key?(&1, "tool_call_id"))

      if has_call or has_result do
        assert has_call and has_result, "tool-call and tool-result must be kept as a pair"
      end
    end

    test "preserves user decision messages" do
      decision_msg = user_msg("user chose option B", %{"decision" => true})
      filler = for _ <- 1..50, do: user_msg(String.duplicate("filler ", 200))
      messages = filler ++ [decision_msg]

      {compactor, _summary} = HistoryCompactor.compact(messages, nil, max_tokens: 500)

      assert Enum.any?(compactor.messages, fn msg ->
               get_in(msg, ["metadata", "decision"]) == true
             end)
    end

    test "produces a compaction summary system message" do
      filler = for _ <- 1..50, do: user_msg(String.duplicate("filler ", 200))
      messages = filler

      {compactor, summary} = HistoryCompactor.compact(messages, nil, max_tokens: 500)

      assert summary.compacted == true
      assert summary.summarized > 0

      # First message should be the compaction summary.
      [first | _] = compactor.messages
      assert first["role"] == "system"
      assert String.contains?(first["content"], "History Compaction")
    end

    test "never exceeds max_tokens after compaction" do
      filler = for _ <- 1..100, do: user_msg(String.duplicate("filler content ", 100))
      messages = filler

      {compactor, _summary} = HistoryCompactor.compact(messages, nil, max_tokens: 2000)

      assert compactor.estimated_tokens <= 2000
    end
  end

  # -- Integration with ModelProfile ----------------------------------------

  describe "compact/3 with ModelProfile" do
    test "uses profile context window and policy for compaction threshold" do
      {:ok, profile} = ModelProfile.for_purpose(:planning)
      # planner-default has 128K window at 70% = ~89,600 token threshold.
      # Small messages shouldn't trigger compaction.
      messages = [user_msg("hello")]

      {compactor, summary} = HistoryCompactor.compact(messages, profile)

      assert summary.compacted == false
      assert compactor.messages == messages
    end

    test "steering profile has tighter budget due to smaller context window" do
      {:ok, profile} = ModelProfile.for_purpose(:steering)
      # steering-default: 32K window at 80% = ~25,600 token threshold.
      filler = for _ <- 1..200, do: user_msg(String.duplicate("content ", 200))
      messages = filler

      {_compactor, summary} = HistoryCompactor.compact(messages, profile)

      # With 200 large messages, should trigger compaction.
      assert summary.compacted == true
    end
  end
end
