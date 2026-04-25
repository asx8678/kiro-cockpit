defmodule KiroCockpit.EventStoreTest do
  use KiroCockpit.DataCase

  alias KiroCockpit.EventStore
  alias KiroCockpit.EventStore.EventEnvelope
  alias KiroCockpit.EventStore.RawAcpMessage

  describe "JSON-RPC classification" do
    test "classifies only unambiguous JSON-RPC 2.0 shapes" do
      assert EventStore.classify_message_type(%{
               "jsonrpc" => "2.0",
               "id" => 1,
               "method" => "session/prompt"
             }) ==
               "request"

      assert EventStore.classify_message_type(%{
               "jsonrpc" => "2.0",
               "id" => nil,
               "method" => "session/prompt"
             }) ==
               "request"

      assert EventStore.classify_message_type(%{"jsonrpc" => "2.0", "method" => "session/update"}) ==
               "notification"

      assert EventStore.classify_message_type(%{"jsonrpc" => "2.0", "id" => 1, "result" => %{}}) ==
               "response"

      assert EventStore.classify_message_type(%{"jsonrpc" => "2.0", "id" => nil, "result" => nil}) ==
               "response"

      assert EventStore.classify_message_type(%{"jsonrpc" => "2.0", "id" => nil, "error" => %{}}) ==
               "error"
    end

    test "returns unknown for malformed or ambiguous JSON-RPC shapes" do
      unknown_payloads = [
        %{"id" => 1, "method" => "session/prompt"},
        %{"jsonrpc" => "1.0", "id" => 1, "method" => "session/prompt"},
        %{"jsonrpc" => "2.0"},
        %{"jsonrpc" => "2.0", "result" => %{}},
        %{"jsonrpc" => "2.0", "error" => %{}},
        %{"jsonrpc" => "2.0", "method" => 123},
        %{"jsonrpc" => "2.0", "id" => 1, "method" => "session/prompt", "result" => %{}},
        %{"jsonrpc" => "2.0", "id" => 1, "method" => "session/prompt", "error" => %{}},
        %{"jsonrpc" => "2.0", "id" => 1, "result" => %{}, "error" => %{}}
      ]

      for payload <- unknown_payloads do
        assert EventStore.classify_message_type(payload) == "unknown"
      end

      assert EventStore.classify_message_type("not a map") == "unknown"
    end

    test "extracts method and normalizes rpc ids without mutating raw payload" do
      payload = %{"jsonrpc" => "2.0", "id" => 42, "method" => "session/prompt"}

      assert EventStore.extract_method(payload) == "session/prompt"
      assert EventStore.normalize_rpc_id(payload) == "42"
      assert payload == %{"jsonrpc" => "2.0", "id" => 42, "method" => "session/prompt"}
    end
  end

  describe "raw ACP message changeset" do
    test "derives query fields and preserves the raw payload exactly" do
      payload = %{
        "jsonrpc" => "2.0",
        "id" => "abc-123",
        "method" => "session/prompt",
        "params" => %{"prompt" => "hello"}
      }

      changeset =
        RawAcpMessage.changeset(%RawAcpMessage{}, %{
          direction: :client_to_agent,
          session_id: "sess_abc123",
          raw_payload: payload
        })

      assert changeset.valid?
      assert get_change(changeset, :direction) == "client_to_agent"
      assert get_change(changeset, :session_id) == "sess_abc123"
      assert get_change(changeset, :method) == "session/prompt"
      assert get_change(changeset, :rpc_id) == "abc-123"
      assert get_change(changeset, :message_type) == "request"
      assert get_change(changeset, :raw_payload) == payload
    end

    test "validates direction and raw payload shape" do
      changeset =
        RawAcpMessage.changeset(%RawAcpMessage{}, %{
          direction: "sideways",
          raw_payload: ["not", "a", "map"]
        })

      refute changeset.valid?
      assert %{direction: ["is invalid"], raw_payload: ["is invalid"]} = errors_on(changeset)
    end
  end

  describe "event envelope constraints" do
    test "enforces unique per-aggregate event sequence" do
      aggregate_id = Ecto.UUID.generate()
      occurred_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      attrs = %{
        stream: "runtime",
        aggregate_type: "raw_acp_message",
        aggregate_id: aggregate_id,
        seq: 1,
        event_type: "raw_acp_message.recorded",
        event_version: 1,
        payload: %{},
        occurred_at: occurred_at
      }

      assert {:ok, _event} = Repo.insert(EventEnvelope.changeset(%EventEnvelope{}, attrs))
      assert {:error, changeset} = Repo.insert(EventEnvelope.changeset(%EventEnvelope{}, attrs))
      assert %{seq: ["has already been taken"]} = errors_on(changeset)
    end
  end

  describe "record_acp_message/3" do
    test "persists the raw message and event envelope atomically" do
      session_id = "sess_abc123"
      correlation_id = Ecto.UUID.generate()

      payload = %{
        "jsonrpc" => "2.0",
        "id" => 7,
        "method" => "session/prompt",
        "params" => %{"prompt" => "build the thing"}
      }

      assert {:ok, message} =
               EventStore.record_acp_message(:client_to_agent, payload,
                 session_id: session_id,
                 trace_id: "trace-123",
                 correlation_id: correlation_id
               )

      assert message.session_id == session_id
      assert message.direction == "client_to_agent"
      assert message.method == "session/prompt"
      assert message.rpc_id == "7"
      assert message.message_type == "request"
      assert message.raw_payload == payload
      assert %RawAcpMessage{} = EventStore.get_acp_message!(message.id)

      assert [listed] = EventStore.list_acp_messages(session_id)
      assert listed.id == message.id

      assert [filtered] =
               EventStore.list_acp_messages(session_id,
                 method: "session/prompt",
                 trace_id: "trace-123"
               )

      assert filtered.id == message.id

      event = Repo.one!(from event in EventEnvelope, where: event.aggregate_id == ^message.id)

      assert event.stream == "runtime"
      assert event.aggregate_type == "raw_acp_message"
      assert event.seq == 1
      assert event.event_type == "raw_acp_message.recorded"
      assert event.correlation_id == correlation_id
      assert event.payload["raw_acp_message_id"] == message.id
      assert event.payload["session_id"] == session_id
      assert event.payload["method"] == "session/prompt"
      assert event.payload["trace_id"] == "trace-123"
      refute Map.has_key?(event.payload, "plan_id")
      refute Map.has_key?(event.payload, "task_id")
      refute Map.has_key?(event.payload, "agent_id")
      refute Map.has_key?(event.payload, "raw_payload")
    end

    test "rolls back cleanly when the canonical raw message is invalid" do
      before_messages = Repo.aggregate(RawAcpMessage, :count)
      before_events = Repo.aggregate(EventEnvelope, :count)

      assert {:error, changeset} = EventStore.record_acp_message(:bogus, %{"jsonrpc" => "2.0"})
      assert %{direction: ["is invalid"]} = errors_on(changeset)

      assert Repo.aggregate(RawAcpMessage, :count) == before_messages
      assert Repo.aggregate(EventEnvelope, :count) == before_events
    end

    test "lists pre-session messages when session_id is nil" do
      payload = %{"jsonrpc" => "2.0", "method" => "session/update"}

      assert {:ok, message} = EventStore.record_acp_message("agent_to_client", payload)
      assert message.session_id == nil
      assert message.message_type == "notification"

      assert [listed] = EventStore.list_acp_messages(nil, message_type: "notification")
      assert listed.id == message.id
    end
  end
end
