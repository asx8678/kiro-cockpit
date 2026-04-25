defmodule KiroCockpit.Plans.Plan do
  @moduledoc """
  A NanoPlanner plan persisted in the database.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @modes ~w(nano nano_deep nano_fix)
  @statuses ~w(draft approved running completed rejected superseded failed)

  @required_fields ~w(
    session_id
    mode
    status
    user_request
    plan_markdown
    execution_prompt
    project_snapshot_hash
  )a

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          session_id: String.t(),
          mode: String.t(),
          status: String.t(),
          user_request: String.t(),
          plan_markdown: String.t(),
          execution_prompt: String.t(),
          raw_model_output: map(),
          project_snapshot_hash: String.t(),
          approved_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "plans" do
    field :session_id, :string
    field :mode, :string
    field :status, :string
    field :user_request, :string
    field :plan_markdown, :string
    field :execution_prompt, :string
    field :raw_model_output, :map, default: %{}
    field :project_snapshot_hash, :string
    field :approved_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec

    has_many :plan_steps, KiroCockpit.Plans.PlanStep
    has_many :plan_events, KiroCockpit.Plans.PlanEvent

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Builds a changeset for a plan.
  """
  def changeset(plan, attrs) do
    plan
    |> cast(attrs, [
      :session_id,
      :mode,
      :status,
      :user_request,
      :plan_markdown,
      :execution_prompt,
      :raw_model_output,
      :project_snapshot_hash,
      :approved_at,
      :completed_at
    ])
    |> validate_required(@required_fields)
    |> validate_inclusion(:mode, @modes)
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:session_id, max: 255)
    |> validate_length(:project_snapshot_hash, max: 255)
    |> check_constraint(:mode, name: :plans_mode_check)
    |> check_constraint(:status, name: :plans_status_check)
    |> check_constraint(:raw_model_output, name: :plans_raw_model_output_object_check)
  end
end
