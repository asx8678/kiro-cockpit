defmodule KiroCockpit.Plans.PlanEvent do
  @moduledoc """
  An event recorded for a plan lifecycle.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @event_types ~w(created revised approved rejected running completed failed superseded)

  @required_fields ~w(plan_id event_type created_at)a

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          plan_id: Ecto.UUID.t(),
          event_type: String.t(),
          payload: map(),
          created_at: DateTime.t()
        }

  schema "plan_events" do
    field :event_type, :string
    field :payload, :map, default: %{}
    field :created_at, :utc_datetime_usec

    belongs_to :plan, KiroCockpit.Plans.Plan, type: :binary_id
  end

  @doc """
  Builds a changeset for a plan event.
  """
  def changeset(plan_event, attrs) do
    plan_event
    |> cast(attrs, [:plan_id, :event_type, :payload, :created_at])
    |> validate_required(@required_fields)
    |> validate_inclusion(:event_type, @event_types)
    |> check_constraint(:event_type, name: :plan_events_event_type_check)
    |> check_constraint(:payload, name: :plan_events_payload_object_check)
  end
end
