defmodule KiroCockpit.Repo.Migrations.CreatePlans do
  use Ecto.Migration

  def change do
    create table(:plans, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false
      add :session_id, :string, null: false
      add :mode, :string, null: false
      add :status, :string, null: false
      add :user_request, :text, null: false
      add :plan_markdown, :text, null: false
      add :execution_prompt, :text, null: false
      add :raw_model_output, :map, null: false, default: fragment("'{}'::jsonb")
      add :project_snapshot_hash, :string, null: false
      add :approved_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:plans, :plans_mode_check,
             check: "mode IN ('nano', 'nano_deep', 'nano_fix')"
           )

    create constraint(:plans, :plans_status_check,
             check:
               "status IN ('draft', 'approved', 'running', 'completed', 'rejected', 'superseded', 'failed')"
           )

    create constraint(:plans, :plans_raw_model_output_object_check,
             check: "jsonb_typeof(raw_model_output) = 'object'"
           )

    create index(:plans, [:session_id], name: :plans_session_id_index)

    execute(
      """
      COMMENT ON INDEX plans_session_id_index IS
      'Query: list plans for a session. Rationale: session_id is the equality predicate.'
      """,
      "COMMENT ON INDEX plans_session_id_index IS NULL"
    )

    create index(:plans, [:status, :inserted_at], name: :plans_status_inserted_at_index)

    execute(
      """
      COMMENT ON INDEX plans_status_inserted_at_index IS
      'Query: filter plans by status ordered by creation time. Rationale: low-cardinality status filter with chronological ordering.'
      """,
      "COMMENT ON INDEX plans_status_inserted_at_index IS NULL"
    )

    create index(:plans, [:mode, :inserted_at], name: :plans_mode_inserted_at_index)

    execute(
      """
      COMMENT ON INDEX plans_mode_inserted_at_index IS
      'Query: filter plans by mode ordered by creation time. Rationale: low-cardinality mode filter with chronological ordering.'
      """,
      "COMMENT ON INDEX plans_mode_inserted_at_index IS NULL"
    )
  end
end
