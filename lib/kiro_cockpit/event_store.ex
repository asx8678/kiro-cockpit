defmodule KiroCockpit.EventStore do
  @moduledoc """
  Durable persistence boundary for raw ACP JSON-RPC traffic.

  The ACP transport branch is intentionally absent here. Future transport/session
  code can call this module with plain maps and correlation options; this module
  persists the raw canonical capture row and its event envelope atomically.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias KiroCockpit.EventStore.EventEnvelope
  alias KiroCockpit.EventStore.RawAcpMessage
  alias KiroCockpit.Repo

  @runtime_stream "runtime"
  @raw_acp_aggregate_type "raw_acp_message"
  @raw_acp_recorded_event_type "raw_acp_message.recorded"
  @raw_acp_recorded_event_version 1
  @max_record_retries 3
  @default_limit 100
  @max_limit 500

  @type direction :: :client_to_agent | :agent_to_client | String.t()
  @type payload :: map()
  @type record_result :: {:ok, RawAcpMessage.t()} | {:error, Ecto.Changeset.t() | term()}

  @doc """
  Records a raw ACP message from a map of attributes.

  Required input:

    * `:direction` / `"direction"`
    * `:raw_payload` / `"raw_payload"` or `:payload` / `"payload"`

  Derived fields (`method`, `rpc_id`, `message_type`) are computed from the raw
  JSON-RPC payload so callers do not need ACP transport modules to classify it.
  `:correlation_id` and `:causation_id`, when supplied, are copied onto the
  event envelope only; they are never invented here.
  """
  @spec record_acp_message(map() | keyword()) :: record_result()
  def record_acp_message(attrs) when is_map(attrs) or is_list(attrs) do
    attrs = RawAcpMessage.normalize_recording_attrs(attrs)
    record_with_retry(attrs, @max_record_retries)
  end

  @doc """
  Records a raw ACP message using a direction, raw payload, and optional metadata.

  Options may include `:session_id`, `:plan_id`, `:task_id`, `:agent_id`,
  `:trace_id`, `:occurred_at`, `:correlation_id`, and `:causation_id`.
  """
  @spec record_acp_message(direction(), payload(), keyword() | map()) :: record_result()
  def record_acp_message(direction, payload, opts \\ []) when is_map(payload) do
    opts
    |> Map.new()
    |> Map.put(:direction, direction)
    |> Map.put(:raw_payload, payload)
    |> record_acp_message()
  end

  @doc """
  Lists ACP messages for a session ordered by occurrence time.

  Passing `nil` lists messages captured before a session was attached. Supported
  filters: `:direction`, `:message_type`, `:method`, `:trace_id`, `:plan_id`,
  `:task_id`, `:agent_id`, `:limit`, and `:order` (`:asc` or `:desc`).
  """
  @spec list_acp_messages(Ecto.UUID.t() | nil, keyword() | map()) :: [RawAcpMessage.t()]
  def list_acp_messages(session_id, opts \\ []) do
    opts = Map.new(opts)

    RawAcpMessage
    |> filter_session(session_id)
    |> filter_equals(:direction, Map.get(opts, :direction))
    |> filter_equals(:message_type, Map.get(opts, :message_type))
    |> filter_equals(:method, Map.get(opts, :method))
    |> filter_equals(:trace_id, Map.get(opts, :trace_id))
    |> filter_equals(:plan_id, Map.get(opts, :plan_id))
    |> filter_equals(:task_id, Map.get(opts, :task_id))
    |> filter_equals(:agent_id, Map.get(opts, :agent_id))
    |> order_messages(Map.get(opts, :order, :asc))
    |> maybe_limit(normalize_limit(Map.get(opts, :limit, @default_limit)))
    |> Repo.all()
  end

  @doc """
  Fetches a persisted ACP message or raises `Ecto.NoResultsError`.
  """
  @spec get_acp_message!(Ecto.UUID.t()) :: RawAcpMessage.t()
  def get_acp_message!(id), do: Repo.get!(RawAcpMessage, id)

  @doc """
  Classifies a raw JSON-RPC payload without depending on ACP transport modules.
  """
  @spec classify_message_type(term()) :: String.t()
  defdelegate classify_message_type(payload), to: RawAcpMessage

  @doc """
  Normalizes a JSON-RPC id to a string when present.
  """
  @spec normalize_rpc_id(term()) :: String.t() | nil
  defdelegate normalize_rpc_id(payload), to: RawAcpMessage

  @doc """
  Extracts the JSON-RPC method from a payload when present.
  """
  @spec extract_method(term()) :: String.t() | nil
  defdelegate extract_method(payload), to: RawAcpMessage

  @doc """
  Returns the next per-aggregate event sequence number inside the caller's transaction.
  """
  @spec next_seq(Ecto.Repo.t(), String.t(), String.t(), Ecto.UUID.t()) :: {:ok, pos_integer()}
  def next_seq(repo, stream, aggregate_type, aggregate_id) do
    query =
      from event in EventEnvelope,
        where:
          event.stream == ^stream and event.aggregate_type == ^aggregate_type and
            event.aggregate_id == ^aggregate_id,
        select: coalesce(max(event.seq), 0)

    {:ok, repo.one(query) + 1}
  end

  defp record_with_retry(attrs, retries_left) do
    attrs
    |> record_multi()
    |> Repo.transaction()
    |> unwrap_record_transaction(attrs, retries_left)
  end

  defp record_multi(attrs) do
    Multi.new()
    |> Multi.insert(:message, RawAcpMessage.changeset(%RawAcpMessage{}, attrs))
    |> Multi.run(:event_seq, fn repo, %{message: message} ->
      next_seq(repo, @runtime_stream, @raw_acp_aggregate_type, message.id)
    end)
    |> Multi.insert(:event, fn %{message: message, event_seq: event_seq} ->
      EventEnvelope.changeset(%EventEnvelope{}, event_attrs(message, attrs, event_seq))
    end)
  end

  defp unwrap_record_transaction({:ok, %{message: message}}, _attrs, _retries_left),
    do: {:ok, message}

  defp unwrap_record_transaction({:error, :message, changeset, _changes}, _attrs, _retries_left) do
    {:error, changeset}
  end

  defp unwrap_record_transaction({:error, :event, changeset, _changes}, attrs, retries_left) do
    if retries_left > 0 and unique_seq_error?(changeset) do
      record_with_retry(attrs, retries_left - 1)
    else
      {:error, changeset}
    end
  end

  defp unwrap_record_transaction({:error, _step, reason, _changes}, _attrs, _retries_left),
    do: {:error, reason}

  defp event_attrs(message, attrs, event_seq) do
    %{
      stream: @runtime_stream,
      aggregate_type: @raw_acp_aggregate_type,
      aggregate_id: message.id,
      seq: event_seq,
      event_type: @raw_acp_recorded_event_type,
      event_version: @raw_acp_recorded_event_version,
      payload: event_payload(message),
      correlation_id: Map.get(attrs, :correlation_id),
      causation_id: Map.get(attrs, :causation_id),
      occurred_at: message.occurred_at
    }
  end

  defp event_payload(message) do
    %{
      "raw_acp_message_id" => message.id,
      "session_id" => message.session_id,
      "direction" => message.direction,
      "method" => message.method,
      "rpc_id" => message.rpc_id,
      "message_type" => message.message_type,
      "plan_id" => message.plan_id,
      "task_id" => message.task_id,
      "agent_id" => message.agent_id,
      "trace_id" => message.trace_id
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp unique_seq_error?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:seq, {_message, opts}} -> opts[:constraint] == :unique
      _error -> false
    end)
  end

  defp unique_seq_error?(_reason), do: false

  defp filter_session(query, nil), do: where(query, [message], is_nil(message.session_id))

  defp filter_session(query, session_id) do
    where(query, [message], message.session_id == ^session_id)
  end

  defp filter_equals(query, _field, nil), do: query

  defp filter_equals(query, field, value) do
    where(query, [message], field(message, ^field) == ^value)
  end

  defp order_messages(query, :desc) do
    order_by(query, [message], desc: message.occurred_at, desc: message.id)
  end

  defp order_messages(query, "desc"), do: order_messages(query, :desc)

  defp order_messages(query, _order) do
    order_by(query, [message], asc: message.occurred_at, asc: message.id)
  end

  defp maybe_limit(query, nil), do: query
  defp maybe_limit(query, limit), do: limit(query, ^limit)

  defp normalize_limit(nil), do: nil

  defp normalize_limit(limit) when is_integer(limit) and limit > @max_limit, do: @max_limit
  defp normalize_limit(limit) when is_integer(limit) and limit > 0, do: limit
  defp normalize_limit(_limit), do: @default_limit
end
