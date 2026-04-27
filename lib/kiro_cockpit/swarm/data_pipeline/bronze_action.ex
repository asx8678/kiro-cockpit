defmodule KiroCockpit.Swarm.DataPipeline.BronzeAction do
  @moduledoc """
  Bronze capture for action lifecycle events (§35 Phase 3).

  Records action_before (pre-hooks started) and action_after (post-hooks done)
  events with full session/plan/task/agent correlation. Captures payload
  summaries and result status (ok/blocked/error) for complete audit trails.

  ## Event Types

    * `"action_before"` — action enters boundary, pre-hooks starting
    * `"action_after"` — action completes, post-hooks done, result recorded
    * `"action_blocked"` — action was blocked by pre-hooks, persisted with reason

  ## Privacy & Payload Handling

  Payloads are summarized to protect sensitive data:

    * `:payload` — normalized summary (action name, keys, size hints)
    * `:raw_payload` — original ACP/wrapper payload (may be truncated per config)

  Full payloads can be captured when `safe: true` is passed or when
  `Application.get_env(:kiro_cockpit, :bronze_full_payload_capture, false)`
  is enabled (development/debugging only).

  ## Fail-Closed Persistence

  Bronze persistence errors are caught and emitted as telemetry metadata.
  The action chain never crashes due to Bronze persistence failures.
  Blocked actions always have a Bronze record per §27.11 invariant 7.
  """

  alias KiroCockpit.Swarm.{Event, Events}

  @type result_status :: :ok | :blocked | :error
  @type action_result :: {:ok, term()} | {:error, term()} | {:blocked, String.t(), [String.t()]}

  @doc """
  Record an action_before event when an action enters the boundary.

  Called at the start of `ActionBoundary.run/3` before pre-hooks execute.
  Captures the initial event state with full correlation.

  ## Options

    * `:safe` — when true, capture full payloads (default: false)
    * `:truncate_at` — max payload size in bytes (default: 4096)

  ## Returns

    * `:ok` — event persisted (or persistence failed silently with telemetry)
  """
  @spec record_before(Event.t(), map()) :: :ok
  def record_before(%Event{} = event, ctx \\ %{}) do
    payload_summary = summarize_payload(event.payload, ctx)
    raw_payload_summary = summarize_raw_payload(event.raw_payload, ctx)

    attrs = %{
      session_id: event.session_id,
      plan_id: event.plan_id,
      task_id: event.task_id,
      agent_id: event.agent_id,
      event_type: "action_before",
      phase: "pre",
      payload: payload_summary,
      raw_payload: raw_payload_summary,
      hook_results: %{
        "action_name" => to_string(event.action_name),
        "permission_level" => safe_to_string(event.permission_level),
        "correlation" => build_correlation_map(event)
      }
    }

    persist_safely(attrs, event, "action_before")
  end

  @doc """
  Record an action_after event when an action completes.

  Called at the end of `ActionBoundary.run/3` after post-hooks execute.
  Captures the final result status and any output summary.

  ## Options

    Same as `record_before/2`.

  ## Result Status Mapping

    * `{:ok, _}` → `:ok`
    * `{:error, {:swarm_blocked, _, _}}` → `:blocked`
    * `{:error, _}` → `:error`
  """
  @spec record_after(Event.t(), action_result(), map()) :: :ok
  def record_after(%Event{} = event, result, ctx \\ %{}) do
    {status, output_summary} = extract_result_summary(result)

    payload_summary = summarize_payload(event.payload, ctx)
    raw_payload_summary = summarize_raw_payload(event.raw_payload, ctx)

    attrs = %{
      session_id: event.session_id,
      plan_id: event.plan_id,
      task_id: event.task_id,
      agent_id: event.agent_id,
      event_type: "action_after",
      phase: "post",
      payload: payload_summary,
      raw_payload: raw_payload_summary,
      hook_results: %{
        "action_name" => to_string(event.action_name),
        "permission_level" => safe_to_string(event.permission_level),
        "result_status" => to_string(status),
        "output_summary" => output_summary,
        "correlation" => build_correlation_map(event)
      }
    }

    persist_safely(attrs, event, "action_after")
  end

  @doc """
  Record an action_blocked event with reason and guidance.

  Called when pre-hooks block an action. Persists the block reason
  and any guidance messages for audit purposes. This is fail-closed:
  even if persistence fails, we don't crash (but we emit telemetry).

  ## Blocked Record Fields

    * `"block_reason"` — the reason string from the blocking hook
    * `"guidance_messages"` — list of guidance messages for the user
    * `"blocking_hook"` — which hook initiated the block (if known)
  """
  @spec record_blocked(Event.t(), String.t(), [String.t()], map(), keyword()) :: :ok
  def record_blocked(%Event{} = event, reason, messages, ctx \\ %{}, opts \\ []) do
    blocking_hook = Keyword.get(opts, :blocking_hook, "unknown")

    payload_summary = summarize_payload(event.payload, ctx)
    raw_payload_summary = summarize_raw_payload(event.raw_payload, ctx)

    attrs = %{
      session_id: event.session_id,
      plan_id: event.plan_id,
      task_id: event.task_id,
      agent_id: event.agent_id,
      event_type: "action_blocked",
      phase: "pre",
      payload: payload_summary,
      raw_payload: raw_payload_summary,
      hook_results: %{
        "action_name" => to_string(event.action_name),
        "permission_level" => safe_to_string(event.permission_level),
        "block_reason" => reason,
        "guidance_messages" => messages,
        "blocking_hook" => to_string(blocking_hook),
        "correlation" => build_correlation_map(event)
      }
    }

    persist_safely(attrs, event, "action_blocked")
  end

  @doc """
  Query Bronze action events for a session.

  Returns action_before, action_after, and action_blocked events
  ordered chronologically.
  """
  @spec list_actions(String.t(), keyword()) :: [Events.SwarmEvent.t()]
  def list_actions(session_id, opts \\ []) do
    event_types = ["action_before", "action_after", "action_blocked"]

    opts
    |> Keyword.put(:session_id, session_id)
    |> Keyword.put(:event_types, event_types)
    |> Events.list_recent()
    |> Enum.filter(&(&1.event_type in event_types))
  end

  @doc """
  Query Bronze action events for a plan.
  """
  @spec list_actions_by_plan(Ecto.UUID.t(), keyword()) :: [Events.SwarmEvent.t()]
  def list_actions_by_plan(plan_id, opts \\ []) do
    plan_id
    |> Events.list_by_plan(opts)
    |> Enum.filter(&(&1.event_type in ["action_before", "action_after", "action_blocked"]))
  end

  @doc """
  Query Bronze action events for a task.
  """
  @spec list_actions_by_task(Ecto.UUID.t(), keyword()) :: [Events.SwarmEvent.t()]
  def list_actions_by_task(task_id, opts \\ []) do
    task_id
    |> Events.list_by_task(opts)
    |> Enum.filter(&(&1.event_type in ["action_before", "action_after", "action_blocked"]))
  end

  # -- Internal helpers ------------------------------------------------------

  # Extract result status and summary from boundary result
  defp extract_result_summary({:ok, value}) do
    {:ok, format_value_summary(value)}
  end

  defp extract_result_summary({:error, {:swarm_blocked, reason, _messages}}) do
    {:blocked, "blocked: #{truncate_string(reason, 200)}"}
  end

  # Lifecycle blocked result (e.g. from ActionBoundary.normalize_lifecycle_result/1)
  defp extract_result_summary({:blocked, reason, _messages}) when is_binary(reason) do
    {:blocked, "blocked: #{truncate_string(reason, 200)}"}
  end

  defp extract_result_summary({:error, reason}) do
    {:error, format_error_summary(reason)}
  end

  defp extract_result_summary(result) do
    {:error, "unexpected result: #{inspect(result) |> truncate_string(200)}"}
  end

  # Format value summary for output (privacy-safe)
  defp format_value_summary(value) when is_atom(value), do: "atom:#{value}"

  defp format_value_summary(value) when is_binary(value),
    do: "string:#{truncate_string(value, 100)}"

  defp format_value_summary(value) when is_number(value), do: "number:#{value}"
  defp format_value_summary(value) when is_list(value), do: "list:#{length(value)}"
  defp format_value_summary(value) when is_map(value), do: "map:#{map_size(value)}"
  defp format_value_summary(_value), do: "term"

  # Format error summary
  defp format_error_summary(reason) when is_binary(reason),
    do: "error:#{truncate_string(reason, 200)}"

  defp format_error_summary(reason), do: "error:#{inspect(reason) |> truncate_string(200)}"

  # Build correlation map for tracing
  defp build_correlation_map(%Event{} = event) do
    %{
      "session_id" => event.session_id,
      "plan_id" => event.plan_id,
      "task_id" => event.task_id,
      "agent_id" => event.agent_id,
      "action_name" => to_string(event.action_name)
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  # Summarize payload for privacy (keys and size hints, not full values)
  defp summarize_payload(payload, ctx) when is_map(payload) do
    safe_mode = Map.get(ctx, :safe, false) || full_payload_capture_enabled?()

    if safe_mode do
      payload
    else
      %{
        "keys" => Map.keys(payload) |> Enum.map(&to_string/1),
        "size" => map_size(payload),
        "type" => "payload_summary"
      }
    end
  end

  defp summarize_payload(_payload, _ctx), do: %{}

  # Summarize raw payload (may contain ACP data)
  defp summarize_raw_payload(raw_payload, ctx) when is_map(raw_payload) do
    safe_mode = Map.get(ctx, :safe, false) || full_payload_capture_enabled?()
    truncate_at = Map.get(ctx, :truncate_at, 4096)

    if safe_mode do
      truncate_payload(raw_payload, truncate_at)
    else
      method = extract_method_hint(raw_payload)
      id_hint = extract_id_hint(raw_payload)

      %{
        "method_hint" => method,
        "id_hint" => id_hint,
        "size" => estimate_payload_size(raw_payload),
        "type" => "raw_payload_summary"
      }
    end
  end

  defp summarize_raw_payload(_raw_payload, _ctx), do: %{}

  # Extract method hint from ACP/JSON-RPC payload
  defp extract_method_hint(%{"method" => method}) when is_binary(method), do: method
  defp extract_method_hint(%{method: method}) when is_binary(method), do: method
  defp extract_method_hint(%{"jsonrpc" => _}), do: "jsonrpc_request"
  defp extract_method_hint(_), do: nil

  # Extract id hint from payload
  defp extract_id_hint(%{"id" => id}) when not is_nil(id), do: "has_id"
  defp extract_id_hint(%{id: id}) when not is_nil(id), do: "has_id"
  defp extract_id_hint(_), do: nil

  # Estimate payload size (rough byte estimate)
  defp estimate_payload_size(payload) when is_map(payload) do
    # Conservative estimate based on key count
    map_size(payload) * 100
  end

  # Truncate payload to max bytes (rough approximation)
  defp truncate_payload(payload, max_bytes) do
    case Jason.encode(payload) do
      {:ok, json} when byte_size(json) > max_bytes ->
        truncated = binary_part(json, 0, max_bytes)
        # Try to decode partial, fall back to summary
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

  # Safely persist with error handling (implicit try per Credo).
  defp persist_safely(attrs, event, event_type) do
    case Events.create_event(attrs) do
      {:ok, _} ->
        :ok

      {:error, changeset} ->
        emit_persistence_error(event_type, event, changeset)
        :ok
    end
  rescue
    exception ->
      emit_persistence_error(event_type, event, exception)
      :ok
  end

  # Emit telemetry for persistence errors.
  # Uses :exception phase (the only valid phase for error events per
  # Telemetry.event/3 validation). The action name :action identifies the
  # action capture context; the error detail goes in metadata.
  defp emit_persistence_error(event_type, event, error) do
    telemetry_event = KiroCockpit.Telemetry.event(:bronze, :action, :exception)

    metadata = %{
      event_type: event_type,
      action_name: event.action_name,
      session_id: event.session_id,
      error: inspect(error),
      persistence_error: true
    }

    KiroCockpit.Telemetry.execute(telemetry_event, %{count: 1}, metadata)
  end

  # Check if full payload capture is enabled globally
  defp full_payload_capture_enabled? do
    Application.get_env(:kiro_cockpit, :bronze_full_payload_capture, false)
  end

  # Truncate string to max length
  defp truncate_string(str, max_len) when is_binary(str) and byte_size(str) > max_len do
    binary_part(str, 0, max_len) <> "..."
  end

  defp truncate_string(str, _max_len) when is_binary(str), do: str
  defp truncate_string(nil, _max_len), do: nil
  defp truncate_string(other, max_len), do: truncate_string(inspect(other), max_len)

  # Safe to_string that handles nil
  defp safe_to_string(nil), do: nil
  defp safe_to_string(value), do: to_string(value)
end
