defmodule KiroCockpit.Swarm.HookTrace do
  @moduledoc """
  Helper functions for hook tracing and normalization.

  Converts hook execution results into trace-card-friendly maps and
  optionally persists hook trace summaries to Bronze swarm events.
  """

  alias KiroCockpit.Swarm.{Event, HookResult}
  alias KiroCockpit.Swarm.Events

  @doc """
  Normalize a hook result into a map suitable for Bronze `hook_results`.

  Includes hook name, decision, reason (if block), guidance (messages),
  and optional hook metadata.
  """
  @spec normalize_hook_result(atom(), HookResult.t()) :: map()
  def normalize_hook_result(hook_name, %HookResult{} = result) do
    base = %{
      "hook" => to_string(hook_name),
      "decision" => to_string(result.decision)
    }

    base
    |> maybe_put("reason", result.reason)
    |> maybe_put("guidance", format_messages(result.messages))
    |> maybe_put("metadata", result.hook_metadata)
  end

  @doc """
  Build a chain summary map for trace card display.
  """
  @spec chain_summary(
          Event.t(),
          list(map()),
          :ok | :blocked,
          String.t() | nil,
          non_neg_integer(),
          atom() | String.t() | nil
        ) :: map()
  def chain_summary(event, hook_results, outcome, reason \\ nil, duration_ms \\ 0, phase \\ nil) do
    %{
      "action" => to_string(event.action_name),
      "session_id" => event.session_id,
      "plan_id" => event.plan_id,
      "task_id" => event.task_id,
      "agent_id" => event.agent_id,
      "phase" => if(phase, do: to_string(phase), else: nil),
      "outcome" => to_string(outcome),
      "reason" => reason,
      "duration_ms" => duration_ms,
      "hook_results" => hook_results
    }
    |> Map.filter(fn {_, v} -> not is_nil(v) end)
  end

  @doc """
  Persist hook trace summary to Bronze swarm events when requested.

  The `ctx` may contain `persist_hook_trace?: true`. If not, this is a no-op.
  Persistence errors are caught and emitted as telemetry metadata.
  """
  @spec maybe_persist_trace(Event.t(), map(), map()) :: :ok
  def maybe_persist_trace(event, trace_summary, ctx) do
    if ctx[:persist_hook_trace?] do
      try do
        # Prepare attributes for Bronze event
        attrs = %{
          session_id: event.session_id,
          plan_id: event.plan_id,
          task_id: event.task_id,
          agent_id: event.agent_id,
          event_type: "hook_trace",
          phase: to_string(ctx[:phase] || :lifecycle),
          payload: %{},
          raw_payload: %{},
          hook_results: trace_summary
        }

        case Events.create_event(attrs) do
          {:ok, _} -> :ok
          {:error, changeset} -> emit_persistence_error(changeset)
        end
      rescue
        exception ->
          emit_persistence_error(exception)
      end
    else
      :ok
    end
  end

  # Internal helpers

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp format_messages([]), do: nil
  defp format_messages(messages), do: Enum.join(messages, "; ")

  defp emit_persistence_error(error) do
    # Emit telemetry metadata about persistence failure (but do not crash)
    event = KiroCockpit.Telemetry.event(:hook, :persistence, :exception)
    KiroCockpit.Telemetry.execute(event, %{count: 1}, %{error: inspect(error)})
  end
end
