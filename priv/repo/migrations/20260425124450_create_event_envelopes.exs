defmodule KiroCockpit.Repo.Migrations.CreateEventEnvelopes do
  use Ecto.Migration

  def change do
    create table(:event_envelopes, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false
      add :stream, :string, null: false
      add :aggregate_type, :string, null: false
      add :aggregate_id, :uuid, null: false
      add :phase, :string
      add :seq, :bigint, null: false
      add :event_type, :string, null: false
      add :event_version, :integer, null: false, default: 1
      add :payload, :map, null: false, default: fragment("'{}'::jsonb")
      add :correlation_id, :uuid
      add :causation_id, :uuid
      add :occurred_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create constraint(:event_envelopes, :event_envelopes_stream_check,
             check: "stream IN ('domain', 'runtime', 'policy', 'llm', 'tool', 'error')"
           )

    create constraint(:event_envelopes, :event_envelopes_seq_positive_check, check: "seq > 0")

    create constraint(:event_envelopes, :event_envelopes_event_version_positive_check,
             check: "event_version > 0"
           )

    create constraint(:event_envelopes, :event_envelopes_payload_object_check,
             check: "jsonb_typeof(payload) = 'object'"
           )

    create unique_index(:event_envelopes, [:stream, :aggregate_type, :aggregate_id, :seq],
             name: :event_envelopes_stream_aggregate_seq_index
           )

    execute(
      """
      COMMENT ON INDEX event_envelopes_stream_aggregate_seq_index IS
      'Query: producer inserts and consumers read per aggregate stream order. Rationale: enforces §14.1 monotonic seq for (stream, aggregate_type, aggregate_id).'
      """,
      "COMMENT ON INDEX event_envelopes_stream_aggregate_seq_index IS NULL"
    )

    create index(:event_envelopes, [:correlation_id],
             name: :event_envelopes_correlation_id_index,
             where: "correlation_id IS NOT NULL"
           )

    execute(
      """
      COMMENT ON INDEX event_envelopes_correlation_id_index IS
      'Query: fetch events sharing a caller-provided correlation_id. Rationale: cross-aggregate tracing without scanning the event spine.'
      """,
      "COMMENT ON INDEX event_envelopes_correlation_id_index IS NULL"
    )

    create index(:event_envelopes, [:aggregate_type, :aggregate_id, :inserted_at],
             name: :event_envelopes_aggregate_inserted_at_index
           )

    execute(
      """
      COMMENT ON INDEX event_envelopes_aggregate_inserted_at_index IS
      'Query: inspect chronological history for one aggregate. Rationale: aggregate_type and aggregate_id are equality predicates; inserted_at provides ordered audit reads.'
      """,
      "COMMENT ON INDEX event_envelopes_aggregate_inserted_at_index IS NULL"
    )

    create index(:event_envelopes, [:stream, :inserted_at],
             name: :event_envelopes_stream_inserted_at_index
           )

    execute(
      """
      COMMENT ON INDEX event_envelopes_stream_inserted_at_index IS
      'Query: consumer tailers read new events by stream ordered by inserted_at. Rationale: stream is the equality predicate; inserted_at supports append-style tailing.'
      """,
      "COMMENT ON INDEX event_envelopes_stream_inserted_at_index IS NULL"
    )
  end
end
