defmodule KiroCockpit.Repo.Migrations.CreatePlanSteps do
  use Ecto.Migration

  def change do
    create table(:plan_steps, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false
      add :plan_id, references(:plans, type: :uuid, on_delete: :delete_all), null: false
      add :phase_number, :integer, null: false
      add :step_number, :integer, null: false
      add :title, :string, null: false
      add :details, :text
      add :files, :map, null: false, default: fragment("'{}'::jsonb")
      add :permission_level, :string, null: false
      add :status, :string, null: false
      add :validation, :text

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:plan_steps, :plan_steps_permission_level_check,
             check:
               "permission_level IN ('read', 'write', 'shell_read', 'shell_write', 'terminal', 'external', 'destructive')"
           )

    create constraint(:plan_steps, :plan_steps_status_check,
             check: "status IN ('planned', 'running', 'done', 'failed', 'skipped')"
           )

    create constraint(:plan_steps, :plan_steps_files_object_check,
             check: "jsonb_typeof(files) = 'object'"
           )

    create index(:plan_steps, [:plan_id], name: :plan_steps_plan_id_index)

    execute(
      """
      COMMENT ON INDEX plan_steps_plan_id_index IS
      'Query: fetch steps for a plan. Rationale: plan_id is the equality predicate.'
      """,
      "COMMENT ON INDEX plan_steps_plan_id_index IS NULL"
    )

    create unique_index(:plan_steps, [:plan_id, :phase_number, :step_number],
             name: :plan_steps_plan_phase_step_unique_index
           )

    execute(
      """
      COMMENT ON INDEX plan_steps_plan_phase_step_unique_index IS
      'Query: ensure each step within a plan phase is unique. Rationale: prevent duplicate step numbers.'
      """,
      "COMMENT ON INDEX plan_steps_plan_phase_step_unique_index IS NULL"
    )

    create index(:plan_steps, [:status], name: :plan_steps_status_index)

    execute(
      """
      COMMENT ON INDEX plan_steps_status_index IS
      'Query: filter steps by status. Rationale: low-cardinality status filter.'
      """,
      "COMMENT ON INDEX plan_steps_status_index IS NULL"
    )
  end
end
