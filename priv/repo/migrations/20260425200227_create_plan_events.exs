defmodule KiroCockpit.Repo.Migrations.CreatePlanEvents do
  use Ecto.Migration

  def change do
    create table(:plan_events, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false
      add :plan_id, references(:plans, type: :uuid, on_delete: :delete_all), null: false
      add :event_type, :string, null: false
      add :payload, :map, null: false, default: fragment("'{}'::jsonb")
      add :created_at, :utc_datetime_usec, null: false

      # No timestamps() because we have created_at column
    end

    create constraint(:plan_events, :plan_events_event_type_check,
             check:
               "event_type IN ('created', 'revised', 'approved', 'rejected', 'running', 'completed', 'failed', 'superseded')"
           )

    create constraint(:plan_events, :plan_events_payload_object_check,
             check: "jsonb_typeof(payload) = 'object'"
           )

    create index(:plan_events, [:plan_id], name: :plan_events_plan_id_index)

    execute(
      """
      COMMENT ON INDEX plan_events_plan_id_index IS
      'Query: fetch events for a plan. Rationale: plan_id is the equality predicate.'
      """,
      "COMMENT ON INDEX plan_events_plan_id_index IS NULL"
    )

    create index(:plan_events, [:event_type, :created_at],
             name: :plan_events_event_type_created_at_index
           )

    execute(
      """
      COMMENT ON INDEX plan_events_event_type_created_at_index IS
      'Query: filter events by type ordered by time. Rationale: low-cardinality event_type filter with chronological ordering.'
      """,
      "COMMENT ON INDEX plan_events_event_type_created_at_index IS NULL"
    )
  end
end
