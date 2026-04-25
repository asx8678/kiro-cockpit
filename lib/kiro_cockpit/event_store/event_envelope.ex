defmodule KiroCockpit.EventStore.EventEnvelope do
  @moduledoc """
  Universal event envelope for durable audit/streaming records.

  Canonical rows remain the source of truth; envelopes are emitted in the same
  transaction for audit, projections, and downstream consumers per §6.3 and
  ordered per aggregate per §14.1.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @streams ~w(domain runtime policy llm tool error)
  @fields ~w(
    stream
    aggregate_type
    aggregate_id
    phase
    seq
    event_type
    event_version
    payload
    correlation_id
    causation_id
    occurred_at
  )a
  @required_fields ~w(
    stream
    aggregate_type
    aggregate_id
    seq
    event_type
    event_version
    payload
    occurred_at
  )a

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          stream: String.t() | nil,
          aggregate_type: String.t() | nil,
          aggregate_id: Ecto.UUID.t() | nil,
          phase: String.t() | nil,
          seq: pos_integer() | nil,
          event_type: String.t() | nil,
          event_version: pos_integer() | nil,
          payload: map() | nil,
          correlation_id: Ecto.UUID.t() | nil,
          causation_id: Ecto.UUID.t() | nil,
          occurred_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil
        }

  schema "event_envelopes" do
    field :stream, :string
    field :aggregate_type, :string
    field :aggregate_id, Ecto.UUID
    field :phase, :string
    field :seq, :integer
    field :event_type, :string
    field :event_version, :integer, default: 1
    field :payload, :map, default: %{}
    field :correlation_id, Ecto.UUID
    field :causation_id, Ecto.UUID
    field :occurred_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc """
  Builds a changeset for an event envelope.
  """
  def changeset(event_envelope, attrs) do
    event_envelope
    |> cast(attrs, @fields)
    |> put_default_payload()
    |> validate_required(@required_fields)
    |> validate_inclusion(:stream, @streams)
    |> validate_number(:seq, greater_than: 0)
    |> validate_number(:event_version, greater_than: 0)
    |> validate_change(:payload, &validate_payload/2)
    |> unique_constraint(:seq, name: :event_envelopes_stream_aggregate_seq_index)
    |> check_constraint(:stream, name: :event_envelopes_stream_check)
    |> check_constraint(:seq, name: :event_envelopes_seq_positive_check)
    |> check_constraint(:event_version, name: :event_envelopes_event_version_positive_check)
    |> check_constraint(:payload, name: :event_envelopes_payload_object_check)
  end

  @doc """
  Returns the stream names accepted by the event envelope table.
  """
  def streams, do: @streams

  defp put_default_payload(changeset) do
    case get_field(changeset, :payload) do
      nil -> put_change(changeset, :payload, %{})
      _payload -> changeset
    end
  end

  defp validate_payload(:payload, payload) when is_map(payload), do: []
  defp validate_payload(:payload, _payload), do: [payload: "must be a map"]
end
