defmodule KiroCockpit.EventStore.RawAcpMessage do
  @moduledoc """
  Raw ACP JSON-RPC message captured before higher-level session/runtime layers exist.

  The raw payload is preserved exactly as the caller supplied it. `session_id`
  is the ACP protocol `sessionId` string (for example, `sess_abc123`), not an
  internal application UUID. Derived fields (`method`, `rpc_id`, and
  `message_type`) are indexing aids for queries and do not replace the raw
  JSON-RPC map.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @directions ~w(client_to_agent agent_to_client)
  @message_types ~w(request notification response error unknown)
  @fields ~w(
    session_id
    direction
    method
    rpc_id
    message_type
    raw_payload
    trace_id
    occurred_at
  )a
  @required_fields ~w(direction message_type raw_payload occurred_at)a
  @input_keys [:payload, :correlation_id, :causation_id | @fields]
  @string_to_input_key Map.new(@input_keys, fn key -> {Atom.to_string(key), key} end)

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          session_id: String.t() | nil,
          direction: String.t() | nil,
          method: String.t() | nil,
          rpc_id: String.t() | nil,
          message_type: String.t() | nil,
          raw_payload: map() | nil,
          trace_id: String.t() | nil,
          occurred_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "raw_acp_messages" do
    field :session_id, :string
    field :direction, :string
    field :method, :string
    field :rpc_id, :string
    field :message_type, :string
    field :raw_payload, :map
    field :trace_id, :string
    field :occurred_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Builds a changeset for raw ACP message persistence.
  """
  def changeset(raw_acp_message, attrs) do
    attrs = normalize_recording_attrs(attrs)

    raw_acp_message
    |> cast(attrs, @fields)
    |> put_default_occurred_at()
    |> validate_required(@required_fields)
    |> validate_inclusion(:direction, @directions)
    |> validate_inclusion(:message_type, @message_types)
    |> validate_length(:session_id, max: 255)
    |> validate_change(:raw_payload, &validate_raw_payload/2)
    |> check_constraint(:direction, name: :raw_acp_messages_direction_check)
    |> check_constraint(:message_type, name: :raw_acp_messages_message_type_check)
    |> check_constraint(:raw_payload, name: :raw_acp_messages_raw_payload_object_check)
  end

  @doc """
  Normalizes accepted caller attrs and derives JSON-RPC indexing fields.
  """
  def normalize_recording_attrs(attrs) when is_map(attrs) or is_list(attrs) do
    attrs
    |> Map.new()
    |> normalize_known_keys()
    |> normalize_payload_alias()
    |> derive_json_rpc_fields()
    |> normalize_direction()
    |> normalize_message_type()
  end

  @doc """
  Classifies a JSON-RPC payload as request, notification, response, error, or unknown.
  """
  def classify_message_type(payload) when is_map(payload) do
    payload
    |> json_rpc_shape()
    |> classify_json_rpc_shape()
  end

  def classify_message_type(_payload), do: "unknown"

  @doc """
  Extracts the JSON-RPC method when present.
  """
  def extract_method(payload) when is_map(payload) do
    case fetch_payload_value(payload, :method) do
      {:ok, method} when is_binary(method) -> method
      {:ok, method} when is_atom(method) -> Atom.to_string(method)
      _missing_or_invalid -> nil
    end
  end

  def extract_method(_payload), do: nil

  @doc """
  Normalizes a JSON-RPC id to a string when present.
  """
  def normalize_rpc_id(payload) when is_map(payload) do
    case fetch_payload_value(payload, :id) do
      {:ok, id} -> normalize_id(id)
      :error -> nil
    end
  end

  def normalize_rpc_id(_payload), do: nil

  @doc """
  Returns the accepted ACP message directions.
  """
  def directions, do: @directions

  @doc """
  Returns the accepted derived message types.
  """
  def message_types, do: @message_types

  defp normalize_known_keys(attrs) do
    Enum.reduce(attrs, %{}, fn {key, value}, acc ->
      case normalize_input_key(key) do
        nil -> acc
        normalized_key -> Map.put(acc, normalized_key, value)
      end
    end)
  end

  defp normalize_input_key(key) when is_atom(key) do
    if key in @input_keys, do: key
  end

  defp normalize_input_key(key) when is_binary(key), do: Map.get(@string_to_input_key, key)
  defp normalize_input_key(_key), do: nil

  defp normalize_payload_alias(%{raw_payload: _raw_payload} = attrs),
    do: Map.delete(attrs, :payload)

  defp normalize_payload_alias(%{payload: payload} = attrs),
    do: attrs |> Map.put(:raw_payload, payload) |> Map.delete(:payload)

  defp normalize_payload_alias(attrs), do: attrs

  defp derive_json_rpc_fields(%{raw_payload: raw_payload} = attrs) when is_map(raw_payload) do
    attrs
    |> Map.put(:method, extract_method(raw_payload))
    |> Map.put(:rpc_id, normalize_rpc_id(raw_payload))
    |> Map.put(:message_type, classify_message_type(raw_payload))
  end

  defp derive_json_rpc_fields(attrs), do: attrs

  defp normalize_direction(%{direction: direction} = attrs),
    do: Map.put(attrs, :direction, normalize_stringish(direction))

  defp normalize_direction(attrs), do: attrs

  defp normalize_message_type(%{message_type: message_type} = attrs) do
    Map.put(attrs, :message_type, normalize_stringish(message_type))
  end

  defp normalize_message_type(attrs), do: attrs

  defp put_default_occurred_at(changeset) do
    case get_field(changeset, :occurred_at) do
      nil ->
        put_change(changeset, :occurred_at, DateTime.utc_now() |> DateTime.truncate(:microsecond))

      _occurred_at ->
        changeset
    end
  end

  defp validate_raw_payload(:raw_payload, payload) when is_map(payload), do: []
  defp validate_raw_payload(:raw_payload, _payload), do: [raw_payload: "must be a map"]

  defp json_rpc_shape(payload) do
    {
      json_rpc_2_0?(payload),
      json_rpc_method?(payload),
      has_payload_key?(payload, :id),
      has_payload_key?(payload, :result),
      has_payload_key?(payload, :error)
    }
  end

  defp classify_json_rpc_shape({true, true, true, false, false}), do: "request"
  defp classify_json_rpc_shape({true, true, false, false, false}), do: "notification"
  defp classify_json_rpc_shape({true, false, true, true, false}), do: "response"
  defp classify_json_rpc_shape({true, false, true, false, true}), do: "error"
  defp classify_json_rpc_shape(_shape), do: "unknown"

  defp json_rpc_2_0?(payload) do
    case fetch_payload_value(payload, :jsonrpc) do
      {:ok, "2.0"} -> true
      _missing_or_invalid -> false
    end
  end

  defp json_rpc_method?(payload) do
    case fetch_payload_value(payload, :method) do
      {:ok, method} when is_binary(method) -> true
      _missing_or_invalid -> false
    end
  end

  defp has_payload_key?(payload, key),
    do: match?({:ok, _value}, fetch_payload_value(payload, key))

  defp fetch_payload_value(payload, key) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(payload, string_key) -> {:ok, Map.fetch!(payload, string_key)}
      Map.has_key?(payload, key) -> {:ok, Map.fetch!(payload, key)}
      true -> :error
    end
  end

  defp normalize_id(nil), do: nil
  defp normalize_id(id) when is_binary(id), do: id
  defp normalize_id(id) when is_integer(id), do: Integer.to_string(id)

  defp normalize_id(id) when is_float(id),
    do: :erlang.float_to_binary(id, [:compact, decimals: 16])

  defp normalize_id(id) when is_boolean(id), do: to_string(id)

  defp normalize_id(id) do
    case Jason.encode(id) do
      {:ok, encoded} -> encoded
      {:error, _reason} -> inspect(id)
    end
  end

  defp normalize_stringish(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_stringish(value), do: value
end
