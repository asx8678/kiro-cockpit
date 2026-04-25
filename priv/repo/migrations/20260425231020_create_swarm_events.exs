defmodule KiroCockpit.Repo.Migrations.CreateSwarmEvents do
  use Ecto.Migration

  def change do
    create table(:swarm_events, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false
      add :session_id, :string, null: false
      add :plan_id, :uuid
      add :task_id, :uuid
      add :agent_id, :string, null: false
      add :event_type, :string, null: false
      add :phase, :string
      add :payload, :map, null: false, default: fragment("'{}'::jsonb")
      add :raw_payload, :map, null: false, default: fragment("'{}'::jsonb")
      add :hook_results, :map, null: false, default: fragment("'[]'::jsonb")
      add :created_at, :utc_datetime_usec, null: false

      # No timestamps() because we have created_at column per §34.2.
    end

    create constraint(:swarm_events, :swarm_events_payload_object_check,
             check: "jsonb_typeof(payload) = 'object'"
           )

    create constraint(:swarm_events, :swarm_events_raw_payload_object_check,
             check: "jsonb_typeof(raw_payload) = 'object'"
           )

    create constraint(:swarm_events, :swarm_events_hook_results_shape_check,
             check: "jsonb_typeof(hook_results) IN ('array', 'object')"
           )

    create index(:swarm_events, [:session_id, :created_at, :id],
             name: :swarm_events_session_created_at_index
           )

    execute(
      """
      COMMENT ON INDEX swarm_events_session_created_at_index IS
      'Query: list Bronze swarm events for an ACP session ordered by created_at and id (Events.list_by_session/2). Rationale: session_id is the equality predicate; created_at/id provides stable Bronze timeline ordering per §27.10.'
      """,
      "COMMENT ON INDEX swarm_events_session_created_at_index IS NULL"
    )

    create index(:swarm_events, [:plan_id, :created_at, :id],
             name: :swarm_events_plan_created_at_index,
             where: "plan_id IS NOT NULL"
           )

    execute(
      """
      COMMENT ON INDEX swarm_events_plan_created_at_index IS
      'Query: trace every Bronze event back to its plan (Events.list_by_plan/2). Rationale: enforces §27.11 invariant 8 (every execution traceable to plan_id); partial index keeps planless ingress rows out.'
      """,
      "COMMENT ON INDEX swarm_events_plan_created_at_index IS NULL"
    )

    create index(:swarm_events, [:task_id, :created_at, :id],
             name: :swarm_events_task_created_at_index,
             where: "task_id IS NOT NULL"
           )

    execute(
      """
      COMMENT ON INDEX swarm_events_task_created_at_index IS
      'Query: trace every Bronze event back to its task (Events.list_by_task/2). Rationale: enforces §27.11 invariant 8 (every execution traceable to task_id); partial index keeps taskless system events out.'
      """,
      "COMMENT ON INDEX swarm_events_task_created_at_index IS NULL"
    )

    create index(:swarm_events, [:event_type, :created_at],
             name: :swarm_events_event_type_created_at_index
           )

    execute(
      """
      COMMENT ON INDEX swarm_events_event_type_created_at_index IS
      'Query: filter Bronze events by event_type ordered by time (Events.list_recent/1 with :event_type). Rationale: low-cardinality event_type filter with chronological ordering for analyzer consumers per §27.10.'
      """,
      "COMMENT ON INDEX swarm_events_event_type_created_at_index IS NULL"
    )

    create index(:swarm_events, [:created_at, :id], name: :swarm_events_created_at_index)

    execute(
      """
      COMMENT ON INDEX swarm_events_created_at_index IS
      'Query: tail Bronze events ordered by created_at (Events.list_recent/1). Rationale: backstop scan for the analyzer pipeline that consumes recent Bronze rows.'
      """,
      "COMMENT ON INDEX swarm_events_created_at_index IS NULL"
    )
  end
end
