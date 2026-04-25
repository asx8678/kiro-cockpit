defmodule KiroCockpit.Repo.Migrations.CreateSwarmTasks do
  @moduledoc """
  Creates the swarm_tasks table per §34.1 and §35 Phase 10.

  Task statuses: pending, in_progress, completed, blocked, deleted
  Task priorities: low, medium, high
  Task categories: researching, planning, acting, verifying, debugging, documenting
  """
  use Ecto.Migration

  def change do
    create table(:swarm_tasks, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false
      add :plan_id, references(:plans, type: :uuid, on_delete: :nilify_all)
      add :session_id, :string, null: false
      add :content, :text, null: false
      add :status, :string, null: false, default: "pending"
      add :priority, :string, null: false, default: "medium"
      add :category, :string, null: false, default: "researching"
      add :notes, :map, default: fragment("'[]'::jsonb")
      add :depends_on, :map, default: fragment("'[]'::jsonb")
      add :blocks, :map, default: fragment("'[]'::jsonb")
      add :owner_id, :string, null: false
      add :sequence, :integer, null: false, default: 0
      add :permission_scope, :map, default: fragment("'[]'::jsonb")
      add :files_scope, :map, default: fragment("'[]'::jsonb")
      add :acceptance_criteria, :map, default: fragment("'[]'::jsonb")

      timestamps(type: :utc_datetime_usec)
    end

    # CHECK constraints mirror the changeset validations for DB-level integrity.
    create constraint(:swarm_tasks, :swarm_tasks_status_check,
             check: "status IN ('pending', 'in_progress', 'completed', 'blocked', 'deleted')"
           )

    create constraint(:swarm_tasks, :swarm_tasks_priority_check,
             check: "priority IN ('low', 'medium', 'high')"
           )

    create constraint(:swarm_tasks, :swarm_tasks_category_check,
             check:
               "category IN ('researching', 'planning', 'acting', 'verifying', 'debugging', 'documenting')"
           )

    create constraint(:swarm_tasks, :swarm_tasks_notes_array_check,
             check: "jsonb_typeof(notes) = 'array'"
           )

    create constraint(:swarm_tasks, :swarm_tasks_depends_on_array_check,
             check: "jsonb_typeof(depends_on) = 'array'"
           )

    create constraint(:swarm_tasks, :swarm_tasks_blocks_array_check,
             check: "jsonb_typeof(blocks) = 'array'"
           )

    create constraint(:swarm_tasks, :swarm_tasks_permission_scope_array_check,
             check: "jsonb_typeof(permission_scope) = 'array'"
           )

    create constraint(:swarm_tasks, :swarm_tasks_files_scope_array_check,
             check: "jsonb_typeof(files_scope) = 'array'"
           )

    create constraint(:swarm_tasks, :swarm_tasks_acceptance_criteria_array_check,
             check: "jsonb_typeof(acceptance_criteria) = 'array'"
           )

    # Indexes — per §34.1 query patterns
    # Primary lookup: find active tasks for a session+owner (execution lane)
    create index(:swarm_tasks, [:session_id, :owner_id, :status],
             name: :swarm_tasks_session_owner_status_index
           )

    execute(
      """
      COMMENT ON INDEX swarm_tasks_session_owner_status_index IS
      'Query: find active (in_progress) task for a session+owner execution lane. Rationale: enforcement flow checks exactly-one-active per lane (§27.6).'
      """,
      "COMMENT ON INDEX swarm_tasks_session_owner_status_index IS NULL"
    )

    create unique_index(:swarm_tasks, [:session_id, :owner_id],
             name: :swarm_tasks_one_active_per_lane_index,
             where: "status = 'in_progress'"
           )

    execute(
      """
      COMMENT ON INDEX swarm_tasks_one_active_per_lane_index IS
      'Invariant: exactly one active (in_progress) task per session+owner execution lane. Rationale: prevents concurrent activation races (§27.6).'
      """,
      "COMMENT ON INDEX swarm_tasks_one_active_per_lane_index IS NULL"
    )

    # List tasks for a plan, ordered by sequence
    create index(:swarm_tasks, [:plan_id, :sequence], name: :swarm_tasks_plan_sequence_index)

    execute(
      """
      COMMENT ON INDEX swarm_tasks_plan_sequence_index IS
      'Query: list tasks for a plan ordered by sequence. Rationale: plan phase-to-task mapping (§27.4) and UI display.'
      """,
      "COMMENT ON INDEX swarm_tasks_plan_sequence_index IS NULL"
    )

    # List tasks for a session (cross-plan)
    create index(:swarm_tasks, [:session_id, :status], name: :swarm_tasks_session_status_index)

    execute(
      """
      COMMENT ON INDEX swarm_tasks_session_status_index IS
      'Query: list all tasks for a session filtered by status. Rationale: task board view (§35 Phase 10).'
      """,
      "COMMENT ON INDEX swarm_tasks_session_status_index IS NULL"
    )
  end
end
