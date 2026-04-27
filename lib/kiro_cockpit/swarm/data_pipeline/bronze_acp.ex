defmodule KiroCockpit.Swarm.DataPipeline.BronzeAcp do
  @moduledoc """
  Bronze capture for ACP (Agent Communication Protocol) update events (§35 Phase 3).

  Records ACP lifecycle events with session/plan/task/agent correlation:

    * `"acp_update"` — ACP state change or message processed
    * `"acp_request"` — Outgoing ACP request from agent
    * `"acp_response"` — Incoming ACP response to agent
    * `"acp_notification"` — ACP notification received

  ## Correlation

  Every ACP event carries correlation IDs:

    * `session_id` — ACP protocol sessionId (mandatory)
    * `plan_id` — associated plan when known
    * `task_id` — associated task when known
    * `agent_id` — agent identifier (mandatory)

  ## Payload Handling

  ACP payloads are captured as summaries by default:

    * Method name extracted
    * RPC id correlation
    * Direction (client_to_agent / agent_to_client)
    * Size hints (not full payload for privacy)

  Full capture can be enabled via `safe: true` or global config for debugging.

  ## Integration with RawAcpMessage

  This module complements `KiroCockpit.EventStore` which captures raw ACP
  traffic. Bronze ACP records add correlation and semantic event typing for
  the Plan 3 data pipeline.
  """

  alias KiroCockpit.Swarm.Events

  @type direction :: :client_to_agent | :agent_to_client | String.t()
  @type acp_event_type :: String.t()

  @doc """
  Record an ACP update event.

  General-purpose ACP event capture for state changes, method calls,
  or any ACP-related activity that should be tracked in Bronze.

  ## Required Fields

    * `:session_id` — ACP session identifier
    * `:agent_id` — agent identifier
    * `:payload` — ACP payload summary or full payload

  ## Optional Fields

    * `:plan_id` — associated plan UUID
    * `:task_id` — associated task UUID
    * `:method` — ACP method name (e.g., "tools/call")
    * `:direction` — :client_to_agent or :agent_to_client
    * `:rpc_id` — JSON-RPC request id for correlation
    * `:phase` — "pre", "post", or "lifecycle"

  ## Options

    * `:safe` — capture full payload (default: false)
    * `:truncate_at` — max payload size in bytes (default: 4096)
    * `:event_type` — override default "acp_update" type
  """
  @spec record_acp_update(map()) :: :ok
  def record_acp_update(attrs) when is_map(attrs) do
    attrs = normalize_attrs(attrs)

    event_type = Map.get(attrs, :event_type, "acp_update")
    payload = build_payload_summary(attrs)
    raw_payload = build_raw_payload_summary(attrs)

    event_attrs = %{
      session_id: attrs.session_id,
      plan_id: Map.get(attrs, :plan_id),
      task_id: Map.get(attrs, :task_id),
      agent_id: attrs.agent_id,
      event_type: event_type,
      phase: Map.get(attrs, :phase, "lifecycle"),
      payload: payload,
      raw_payload: raw_payload,
      hook_results: %{
        "method" => Map.get(attrs, :method),
        "direction" => normalize_direction(Map.get(attrs, :direction)),
        "rpc_id" => Map.get(attrs, :rpc_id),
        "correlation" => build_correlation_map(attrs)
      }
    }

    persist_safely(event_attrs, attrs, event_type)
  end

  @doc """
  Record an ACP request (outgoing from agent to client/environment).

  Captures tool calls, prompt requests, or any agent-initiated ACP activity.
  """
  @spec record_acp_request(String.t(), String.t(), map(), keyword()) :: :ok
  def record_acp_request(session_id, agent_id, payload, opts \\ []) do
    base_attrs = %{
      session_id: session_id,
      agent_id: agent_id,
      payload: payload,
      direction: :agent_to_client,
      event_type: "acp_request"
    }

    # Merge optional correlation and metadata
    attrs =
      opts
      |> Keyword.take([:plan_id, :task_id, :method, :rpc_id, :safe, :truncate_at])
      |> Enum.reduce(base_attrs, fn {k, v}, acc -> Map.put(acc, k, v) end)

    record_acp_update(attrs)
  end

  @doc """
  Record an ACP response (incoming to agent from client/environment).

  Captures tool results, prompt responses, or any environment response.
  """
  @spec record_acp_response(String.t(), String.t(), map(), keyword()) :: :ok
  def record_acp_response(session_id, agent_id, payload, opts \\ []) do
    base_attrs = %{
      session_id: session_id,
      agent_id: agent_id,
      payload: payload,
      direction: :client_to_agent,
      event_type: "acp_response"
    }

    attrs =
      opts
      |> Keyword.take([:plan_id, :task_id, :method, :rpc_id, :safe, :truncate_at])
      |> Enum.reduce(base_attrs, fn {k, v}, acc -> Map.put(acc, k, v) end)

    record_acp_update(attrs)
  end

  @doc """
  Record an ACP notification (async message, no response expected).

  Captures progress updates, log messages, or any one-way ACP traffic.
  """
  @spec record_acp_notification(String.t(), String.t(), map(), keyword()) :: :ok
  def record_acp_notification(session_id, agent_id, payload, opts \\ []) do
    base_attrs = %{
      session_id: session_id,
      agent_id: agent_id,
      payload: payload,
      event_type: "acp_notification"
    }

    attrs =
      opts
      |> Keyword.take([:plan_id, :task_id, :method, :direction, :safe, :truncate_at])
      |> Enum.reduce(base_attrs, fn {k, v}, acc -> Map.put(acc, k, v) end)

    record_acp_update(attrs)
  end

  @doc """
  Query Bronze ACP events for a session.

  Returns acp_update, acp_request, acp_response, and acp_notification
  events ordered chronologically.
  """
  @spec list_acp_events(String.t(), keyword()) :: [Events.SwarmEvent.t()]
  def list_acp_events(session_id, opts \\ []) do
    event_types = ["acp_update", "acp_request", "acp_response", "acp_notification"]

    opts
    |> Keyword.put(:session_id, session_id)
    |> Events.list_recent()
    |> Enum.filter(&(&1.event_type in event_types))
    |> apply_order(opts)
  end

  @doc """
  Query Bronze ACP events for a plan.
  """
  @spec list_acp_by_plan(Ecto.UUID.t(), keyword()) :: [Events.SwarmEvent.t()]
  def list_acp_by_plan(plan_id, opts \\ []) do
    plan_id
    |> Events.list_by_plan(opts)
    |> Enum.filter(
      &(&1.event_type in ["acp_update", "acp_request", "acp_response", "acp_notification"])
    )
  end

  @doc """
  Query Bronze ACP events for a task.
  """
  @spec list_acp_by_task(Ecto.UUID.t(), keyword()) :: [Events.SwarmEvent.t()]
  def list_acp_by_task(task_id, opts \\ []) do
    task_id
    |> Events.list_by_task(opts)
    |> Enum.filter(
      &(&1.event_type in ["acp_update", "acp_request", "acp_response", "acp_notification"])
    )
  end

  @doc """
  Query Bronze ACP events by method name.
  """
  @spec list_by_method(String.t(), String.t(), keyword()) :: [Events.SwarmEvent.t()]
  def list_by_method(session_id, method, opts \\ []) do
    session_id
    |> list_acp_events(opts)
    |> Enum.filter(fn event ->
      hook_results = event.hook_results || %{}
      hook_results["method"] == method
    end)
  end

  @doc """
  Query Bronze ACP events by direction.
  """
  @spec list_by_direction(String.t(), direction(), keyword()) :: [Events.SwarmEvent.t()]
  def list_by_direction(session_id, direction, opts \\ []) do
    normalized = normalize_direction(direction)

    session_id
    |> list_acp_events(opts)
    |> Enum.filter(fn event ->
      hook_results = event.hook_results || %{}
      hook_results["direction"] == normalized
    end)
  end

  # -- Internal helpers ------------------------------------------------------

  # Normalize input attributes
  defp normalize_attrs(attrs) do
    attrs
    |> ensure_string_session_id()
    |> ensure_string_agent_id()
    |> extract_method_from_payload()
    |> extract_rpc_id_from_payload()
  end

  # Ensure session_id is present
  defp ensure_string_session_id(%{session_id: sid} = attrs) when is_binary(sid), do: attrs

  defp ensure_string_session_id(%{session_id: sid} = attrs) when is_atom(sid),
    do: %{attrs | session_id: to_string(sid)}

  defp ensure_string_session_id(attrs), do: Map.put(attrs, :session_id, "unknown")

  # Ensure agent_id is present
  defp ensure_string_agent_id(%{agent_id: aid} = attrs) when is_binary(aid), do: attrs

  defp ensure_string_agent_id(%{agent_id: aid} = attrs) when is_atom(aid),
    do: %{attrs | agent_id: to_string(aid)}

  defp ensure_string_agent_id(attrs), do: Map.put(attrs, :agent_id, "unknown")

  # Extract method from payload if not explicitly provided
  defp extract_method_from_payload(%{method: method} = attrs) when is_binary(method), do: attrs

  defp extract_method_from_payload(attrs) do
    payload = Map.get(attrs, :payload, %{}) || Map.get(attrs, :raw_payload, %{}) || %{}
    method = extract_method(payload)
    Map.put(attrs, :method, method)
  end

  # Extract RPC id from payload if not explicitly provided
  defp extract_rpc_id_from_payload(%{rpc_id: rpc_id} = attrs) when not is_nil(rpc_id), do: attrs

  defp extract_rpc_id_from_payload(attrs) do
    payload = Map.get(attrs, :payload, %{}) || Map.get(attrs, :raw_payload, %{}) || %{}
    rpc_id = extract_rpc_id(payload)
    Map.put(attrs, :rpc_id, rpc_id)
  end

  # Extract method from JSON-RPC payload
  defp extract_method(%{"method" => method}) when is_binary(method), do: method
  defp extract_method(%{method: method}) when is_binary(method), do: method
  defp extract_method(_), do: nil

  # Extract RPC id from JSON-RPC payload
  defp extract_rpc_id(%{"id" => id}) when not is_nil(id), do: normalize_rpc_id(id)
  defp extract_rpc_id(%{id: id}) when not is_nil(id), do: normalize_rpc_id(id)
  defp extract_rpc_id(_), do: nil

  # Normalize RPC id to string
  defp normalize_rpc_id(id) when is_binary(id), do: id
  defp normalize_rpc_id(id) when is_integer(id), do: Integer.to_string(id)

  defp normalize_rpc_id(id) when is_float(id),
    do: :erlang.float_to_binary(id, [:compact, decimals: 16])

  defp normalize_rpc_id(id) when is_boolean(id), do: to_string(id)
  defp normalize_rpc_id(_), do: nil

  # Build payload summary
  defp build_payload_summary(attrs) do
    safe_mode = Map.get(attrs, :safe, false) || full_payload_capture_enabled?()
    truncate_at = Map.get(attrs, :truncate_at, 4096)
    payload = Map.get(attrs, :payload, %{}) || %{}

    if safe_mode do
      truncate_payload(payload, truncate_at)
    else
      %{
        "keys" => Map.keys(payload) |> Enum.map(&to_string/1),
        "size" => map_size(payload),
        "type" => "acp_payload_summary"
      }
    end
  end

  # Build raw payload summary
  # Falls back to :payload when :raw_payload is absent (empty map is
  # truthy in Elixir, so we must check for nil explicitly).
  defp build_raw_payload_summary(attrs) do
    safe_mode = Map.get(attrs, :safe, false) || full_payload_capture_enabled?()
    truncate_at = Map.get(attrs, :truncate_at, 4096)
    raw_payload = resolve_raw_payload(attrs)

    if safe_mode do
      truncate_payload(raw_payload, truncate_at)
    else
      method_hint = extract_method_hint(raw_payload)
      id_hint = extract_id_hint(raw_payload)

      %{
        "method_hint" => method_hint,
        "id_hint" => id_hint,
        "jsonrpc" => Map.get(raw_payload, "jsonrpc") || Map.get(raw_payload, :jsonrpc),
        "size" => estimate_payload_size(raw_payload),
        "type" => "acp_raw_payload_summary"
      }
    end
  end

  # Resolve raw payload: prefer explicit :raw_payload, fall back to
  # :payload. We cannot use `||` because `%{}` is truthy.
  defp resolve_raw_payload(attrs) do
    case Map.get(attrs, :raw_payload) do
      nil -> Map.get(attrs, :payload, %{})
      rp -> rp
    end
  end

  # Extract method hint
  defp extract_method_hint(%{"method" => method}) when is_binary(method), do: method
  defp extract_method_hint(%{method: method}) when is_binary(method), do: method
  defp extract_method_hint(_), do: nil

  # Extract id hint
  defp extract_id_hint(%{"id" => id}) when not is_nil(id), do: "has_id"
  defp extract_id_hint(%{id: id}) when not is_nil(id), do: "has_id"
  defp extract_id_hint(_), do: nil

  # Estimate payload size
  defp estimate_payload_size(payload) when is_map(payload) do
    map_size(payload) * 100
  end

  defp estimate_payload_size(_), do: 0

  # Truncate payload to max bytes
  defp truncate_payload(payload, max_bytes) when is_map(payload) do
    case Jason.encode(payload) do
      {:ok, json} when byte_size(json) > max_bytes ->
        truncated = binary_part(json, 0, max_bytes)

        case Jason.decode(truncated) do
          {:ok, partial} -> partial
          {:error, _} -> %{"truncated" => true, "original_size" => byte_size(json)}
        end

      {:ok, _json} ->
        payload

      {:error, _} ->
        %{"error" => "could not encode payload"}
    end
  end

  defp truncate_payload(_payload, _max_bytes), do: %{}

  # Normalize direction to string
  defp normalize_direction(:client_to_agent), do: "client_to_agent"
  defp normalize_direction(:agent_to_client), do: "agent_to_client"
  defp normalize_direction(dir) when is_binary(dir), do: dir
  defp normalize_direction(_), do: nil

  # Build correlation map
  defp build_correlation_map(attrs) do
    %{
      "session_id" => Map.get(attrs, :session_id),
      "plan_id" => Map.get(attrs, :plan_id),
      "task_id" => Map.get(attrs, :task_id),
      "agent_id" => Map.get(attrs, :agent_id),
      "method" => Map.get(attrs, :method)
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  # Apply ordering options
  defp apply_order(events, opts) do
    order = Keyword.get(opts, :order, :asc)

    case order do
      :desc -> Enum.reverse(events)
      "desc" -> Enum.reverse(events)
      _ -> events
    end
  end

  # Safely persist with error handling
  defp persist_safely(attrs, original_attrs, event_type) do
    try do
      case Events.create_event(attrs) do
        {:ok, _} ->
          :ok

        {:error, changeset} ->
          emit_persistence_error(event_type, original_attrs, changeset)
          :ok
      end
    rescue
      exception ->
        emit_persistence_error(event_type, original_attrs, exception)
        :ok
    end
  end

  # Emit telemetry for persistence errors.
  # Uses :exception phase (the only valid phase for error events per
  # Telemetry.event/3 validation). The action name :acp identifies the
  # ACP capture context; the error detail goes in metadata.
  defp emit_persistence_error(event_type, attrs, error) do
    telemetry_event = KiroCockpit.Telemetry.event(:bronze, :acp, :exception)

    metadata = %{
      event_type: event_type,
      session_id: Map.get(attrs, :session_id),
      agent_id: Map.get(attrs, :agent_id),
      error: inspect(error),
      persistence_error: true
    }

    KiroCockpit.Telemetry.execute(telemetry_event, %{count: 1}, metadata)
  end

  # Check if full payload capture is enabled globally
  defp full_payload_capture_enabled? do
    Application.get_env(:kiro_cockpit, :bronze_full_payload_capture, false)
  end
end
