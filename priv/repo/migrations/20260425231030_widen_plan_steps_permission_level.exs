defmodule KiroCockpit.Repo.Migrations.WidenPlanStepsPermissionLevel do
  @moduledoc """
  Widens the plan_steps_permission_level_check constraint to include
  :subagent and :memory_write (§32.1 nine-permission vocabulary).
  """
  use Ecto.Migration

  def up do
    # Drop old constraint, recreate with the full 9-permission list
    execute("""
    ALTER TABLE plan_steps DROP CONSTRAINT plan_steps_permission_level_check
    """)

    execute("""
    ALTER TABLE plan_steps ADD CONSTRAINT plan_steps_permission_level_check
    CHECK (permission_level IN ('read', 'write', 'shell_read', 'shell_write',
                                 'terminal', 'external', 'destructive',
                                 'subagent', 'memory_write'))
    """)
  end

  def down do
    execute("""
    ALTER TABLE plan_steps DROP CONSTRAINT plan_steps_permission_level_check
    """)

    execute("""
    ALTER TABLE plan_steps ADD CONSTRAINT plan_steps_permission_level_check
    CHECK (permission_level IN ('read', 'write', 'shell_read', 'shell_write',
                                 'terminal', 'external', 'destructive'))
    """)
  end
end
