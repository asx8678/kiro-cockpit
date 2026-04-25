defmodule KiroCockpit.KiroSession.StreamEventTest do
  @moduledoc """
  Pure-function tests for `KiroCockpit.KiroSession.StreamEvent.normalize/3`.

  No GenServers, no ports — just the normalization contract. The struct is
  the stable boundary every downstream consumer (LiveView, EventStore,
  steering evaluator) depends on; if it changes shape, half the tree must
  change with it.
  """

  use ExUnit.Case, async: true

  alias KiroCockpit.KiroSession.StreamEvent

  describe "normalize/3 — known kinds" do
    for {type, kind} <- [
          {"agent_message_chunk", :agent_message_chunk},
          {"agent_thought_chunk", :agent_thought_chunk},
          {"user_message_chunk", :user_message_chunk},
          {"tool_call", :tool_call},
          {"tool_call_update", :tool_call_update},
          {"plan", :plan},
          {"current_mode_update", :current_mode_update},
          {"config_option_update", :config_option_update},
          {"turn_end", :turn_end}
        ] do
      test "#{type} normalizes to kind: #{inspect(kind)}" do
        params = %{
          "sessionId" => "sess_x",
          "update" => %{"sessionUpdate" => unquote(type)}
        }

        now = DateTime.utc_now()
        event = StreamEvent.normalize(params, 0, now)

        assert %StreamEvent{} = event
        assert event.kind == unquote(kind)
        assert event.type == unquote(type)
        assert event.session_id == "sess_x"
        assert event.sequence == 0
        assert event.occurred_at == now
        assert event.raw == params
      end
    end
  end

  describe "normalize/3 — unknown / malformed" do
    test "unknown sessionUpdate string degrades to :unknown" do
      params = %{
        "sessionId" => "sess_x",
        "update" => %{"sessionUpdate" => "future_extension_we_dont_know"}
      }

      event = StreamEvent.normalize(params, 1, DateTime.utc_now())
      assert event.kind == :unknown
      assert event.type == "future_extension_we_dont_know"
    end

    test "non-string sessionUpdate keeps :unknown and preserves raw type" do
      params = %{
        "sessionId" => "sess_x",
        "update" => %{"sessionUpdate" => 42}
      }

      event = StreamEvent.normalize(params, 0, DateTime.utc_now())
      assert event.kind == :unknown
      assert event.type == 42
    end

    test "missing :update field degrades to :unknown with type: nil" do
      params = %{"sessionId" => "sess_x"}

      event = StreamEvent.normalize(params, 0, DateTime.utc_now())
      assert event.kind == :unknown
      assert event.type == nil
      assert event.session_id == "sess_x"
    end

    test "missing sessionId leaves session_id: nil but does not crash" do
      params = %{"update" => %{"sessionUpdate" => "agent_message_chunk"}}

      event = StreamEvent.normalize(params, 0, DateTime.utc_now())
      assert event.kind == :agent_message_chunk
      assert event.session_id == nil
    end

    test "non-string sessionId is treated as missing (defensive)" do
      params = %{
        "sessionId" => :weird_atom,
        "update" => %{"sessionUpdate" => "turn_end"}
      }

      event = StreamEvent.normalize(params, 0, DateTime.utc_now())
      assert event.session_id == nil
      assert event.kind == :turn_end
    end
  end

  describe "normalize/3 — sequence + occurred_at preservation" do
    test "stores caller-supplied sequence verbatim" do
      params = %{"sessionId" => "x", "update" => %{"sessionUpdate" => "agent_message_chunk"}}
      event = StreamEvent.normalize(params, 12_345, DateTime.utc_now())
      assert event.sequence == 12_345
    end

    test "stores caller-supplied occurred_at verbatim" do
      now = ~U[2025-01-15 12:34:56.000000Z]
      params = %{"sessionId" => "x", "update" => %{"sessionUpdate" => "turn_end"}}
      event = StreamEvent.normalize(params, 0, now)
      assert event.occurred_at == now
    end

    test "rejects negative sequence (caller bug)" do
      params = %{"update" => %{"sessionUpdate" => "agent_message_chunk"}}

      assert_raise FunctionClauseError, fn ->
        StreamEvent.normalize(params, -1, DateTime.utc_now())
      end
    end
  end

  describe "known_kinds/0" do
    test "is a closed set keyed by canonical strings" do
      kinds = StreamEvent.known_kinds()

      assert Map.get(kinds, "agent_message_chunk") == :agent_message_chunk
      assert Map.get(kinds, "tool_call_update") == :tool_call_update
      assert Map.get(kinds, "turn_end") == :turn_end
      refute Map.has_key?(kinds, "unknown")
      refute Map.has_key?(kinds, "future")
    end
  end
end
