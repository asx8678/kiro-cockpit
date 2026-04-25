defmodule KiroCockpit.Plans.PlanStep do
  @moduledoc """
  A step within a NanoPlanner plan.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @permission_levels ~w(read write shell_read shell_write terminal external destructive)
  @statuses ~w(planned running done failed skipped)

  @required_fields ~w(
    plan_id
    phase_number
    step_number
    title
    permission_level
    status
  )a

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          plan_id: Ecto.UUID.t(),
          phase_number: integer(),
          step_number: integer(),
          title: String.t(),
          details: String.t() | nil,
          files: map(),
          permission_level: String.t(),
          status: String.t(),
          validation: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "plan_steps" do
    field :phase_number, :integer
    field :step_number, :integer
    field :title, :string
    field :details, :string
    field :files, :map, default: %{}
    field :permission_level, :string
    field :status, :string
    field :validation, :string

    belongs_to :plan, KiroCockpit.Plans.Plan, type: :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Builds a changeset for a plan step.
  """
  def changeset(plan_step, attrs) do
    plan_step
    |> cast(attrs, [
      :plan_id,
      :phase_number,
      :step_number,
      :title,
      :details,
      :files,
      :permission_level,
      :status,
      :validation
    ])
    |> validate_required(@required_fields)
    |> validate_inclusion(:permission_level, @permission_levels)
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:title, max: 255)
    |> check_constraint(:permission_level, name: :plan_steps_permission_level_check)
    |> check_constraint(:status, name: :plan_steps_status_check)
    |> check_constraint(:files, name: :plan_steps_files_object_check)
    |> unique_constraint([:plan_id, :phase_number, :step_number],
      name: :plan_steps_plan_phase_step_unique_index
    )
  end
end
