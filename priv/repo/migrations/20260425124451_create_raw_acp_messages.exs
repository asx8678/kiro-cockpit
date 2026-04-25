defmodule KiroCockpit.Repo.Migrations.CreateRawAcpMessages do
  use Ecto.Migration

  def change do
    create table(:raw_acp_messages, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false
      add :session_id, :string
      add :direction, :string, null: false
      add :method, :string
      add :rpc_id, :string
      add :message_type, :string, null: false
      add :raw_payload, :map, null: false
      add :trace_id, :string
      add :occurred_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:raw_acp_messages, :raw_acp_messages_direction_check,
             check: "direction IN ('client_to_agent', 'agent_to_client')"
           )

    create constraint(:raw_acp_messages, :raw_acp_messages_message_type_check,
             check: "message_type IN ('request', 'notification', 'response', 'error', 'unknown')"
           )

    create constraint(:raw_acp_messages, :raw_acp_messages_raw_payload_object_check,
             check: "jsonb_typeof(raw_payload) = 'object'"
           )

    create index(:raw_acp_messages, [:session_id, :occurred_at, :id],
             name: :raw_acp_messages_session_occurred_at_index
           )

    execute(
      """
      COMMENT ON INDEX raw_acp_messages_session_occurred_at_index IS
      'Query: list raw ACP messages for an ACP protocol sessionId ordered by occurred_at and id. Rationale: session_id is the protocol string equality predicate; occurred_at/id gives stable timeline order, including nullable pre-session capture.'
      """,
      "COMMENT ON INDEX raw_acp_messages_session_occurred_at_index IS NULL"
    )

    create index(:raw_acp_messages, [:method, :occurred_at],
             name: :raw_acp_messages_method_occurred_at_index,
             where: "method IS NOT NULL"
           )

    execute(
      """
      COMMENT ON INDEX raw_acp_messages_method_occurred_at_index IS
      'Query: inspect traffic for one JSON-RPC method ordered by occurrence time. Rationale: method is nullable on responses, so the partial index avoids indexing non-method rows.'
      """,
      "COMMENT ON INDEX raw_acp_messages_method_occurred_at_index IS NULL"
    )

    create index(:raw_acp_messages, [:message_type, :occurred_at],
             name: :raw_acp_messages_message_type_occurred_at_index
           )

    execute(
      """
      COMMENT ON INDEX raw_acp_messages_message_type_occurred_at_index IS
      'Query: find requests, notifications, responses, or errors ordered by occurrence time. Rationale: message_type is a low-cardinality diagnostic filter paired with chronological review.'
      """,
      "COMMENT ON INDEX raw_acp_messages_message_type_occurred_at_index IS NULL"
    )

    create index(:raw_acp_messages, [:trace_id, :occurred_at],
             name: :raw_acp_messages_trace_id_occurred_at_index,
             where: "trace_id IS NOT NULL"
           )

    execute(
      """
      COMMENT ON INDEX raw_acp_messages_trace_id_occurred_at_index IS
      'Query: fetch all raw ACP messages for a trace_id ordered by occurrence time. Rationale: trace_id is optional correlation metadata, so a partial index keeps null-heavy capture compact.'
      """,
      "COMMENT ON INDEX raw_acp_messages_trace_id_occurred_at_index IS NULL"
    )
  end
end
