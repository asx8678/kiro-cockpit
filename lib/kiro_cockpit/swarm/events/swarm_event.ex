defmodule KiroCockpit.Swarm.Events.SwarmEvent do
  @moduledoc """
  A Bronze swarm event captured for the Plan 3 data pipeline.

  Per plan2.md §27.10, Bronze rows are the raw event capture layer that feeds
  Silver analyzers and Gold memory promotion. Per §27.11 invariants 7 and 8,
  Bronze captures every event (including blocked ones) and every execution
  is traceable to its `plan_id` / `task_id`.

  This schema mirrors §34.2 and intentionally keeps `payload`, `raw_payload`,
  and `hook_results` as plain maps (or, for `hook_results`, a list of maps).
  It is independent of any specific hook struct module so capture sites can
  write before higher-level Swarm hook structs are introduced.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias KiroCockpit.Swarm.Events.JsonAny

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @cast_fields ~w(
    session_id
    plan_id
    task_id
    agent_id
    event_type
    phase
    payload
    raw_payload
    hook_results
    created_at
  )a

  @required_fields ~w(
    session_id
    agent_id
    event_type
    payload
    raw_payload
    hook_results
    created_at
  )a

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          session_id: String.t() | nil,
          plan_id: Ecto.UUID.t() | nil,
          task_id: Ecto.UUID.t() | nil,
          agent_id: String.t() | nil,
          event_type: String.t() | nil,
          phase: String.t() | nil,
          payload: map() | nil,
          raw_payload: map() | nil,
          hook_results: map() | list() | nil,
          created_at: DateTime.t() | nil
        }

  schema "swarm_events" do
    field :session_id, :string
    field :plan_id, Ecto.UUID
    field :task_id, Ecto.UUID
    field :agent_id, :string
    field :event_type, :string
    field :phase, :string
    field :payload, :map, default: %{}
    field :raw_payload, :map, default: %{}
    field :hook_results, JsonAny, default: []
    field :created_at, :utc_datetime_usec
  end

  @doc """
  Builds a changeset for a swarm event.

  Correlation IDs (`session_id`, `plan_id`, `task_id`, `agent_id`) are
  cast through unchanged: producers own correlation, the persistence layer
  never invents it.
  """
  def changeset(swarm_event, attrs) do
    swarm_event
    |> cast(attrs, @cast_fields)
    |> put_default(:payload, %{})
    |> put_default(:raw_payload, %{})
    |> put_default(:hook_results, [])
    |> put_default_created_at()
    |> validate_required(@required_fields)
    |> validate_length(:session_id, max: 255)
    |> validate_length(:agent_id, max: 255)
    |> validate_length(:event_type, max: 255)
    |> validate_length(:phase, max: 64)
    |> validate_change(:payload, &validate_object/2)
    |> validate_change(:raw_payload, &validate_object/2)
    |> validate_change(:hook_results, &validate_hook_results_shape/2)
    |> check_constraint(:payload, name: :swarm_events_payload_object_check)
    |> check_constraint(:raw_payload, name: :swarm_events_raw_payload_object_check)
    |> check_constraint(:hook_results, name: :swarm_events_hook_results_shape_check)
  end

  defp put_default(changeset, field, default) do
    case get_field(changeset, field) do
      nil -> put_change(changeset, field, default)
      _value -> changeset
    end
  end

  defp put_default_created_at(changeset) do
    case get_field(changeset, :created_at) do
      nil ->
        put_change(
          changeset,
          :created_at,
          DateTime.utc_now() |> DateTime.truncate(:microsecond)
        )

      _value ->
        changeset
    end
  end

  defp validate_object(_field, value) when is_map(value), do: []
  defp validate_object(field, _value), do: [{field, "must be a map"}]

  defp validate_hook_results_shape(:hook_results, value) when is_list(value) do
    if Enum.all?(value, &is_map/1) do
      []
    else
      [hook_results: "list entries must be maps"]
    end
  end

  defp validate_hook_results_shape(:hook_results, value) when is_map(value), do: []

  defp validate_hook_results_shape(:hook_results, _value),
    do: [hook_results: "must be a map or list"]
end
