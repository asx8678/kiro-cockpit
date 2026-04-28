defmodule KiroCockpit.Swarm.Hooks.WriteValidationHook do
  @moduledoc """
  Detects repeated write failures and blocks risky retry loops.

  Per §27.2, this post-action hook (priority 90, can block) monitors
  consecutive write failures tracked via trusted `ctx` and blocks
  further writes when the failure count exceeds the configurable
  threshold, preventing wasteful or destructive retry spirals.

  ## Failure tracking

  Failure counts come from **trusted** `ctx` keys only — never from
  untrusted `event.payload` or `event.metadata`:

    - `ctx[:write_failure_count]` — integer, consecutive write failures
    - `ctx[:last_write_failure_reason]` — string, reason for last failure

  When no trusted count is provided, the hook defaults to `:continue`
  (no evidence of a retry loop).

  ## Threshold

  Default threshold is 3 consecutive failures. Override via
  `ctx[:write_failure_threshold]`.

  ## Block behavior

  When blocked, the hook returns actionable guidance:
  the agent should inspect the failure reason, change strategy, or
  escalate — not blindly retry the same write.

  Priority: 90 (post-action, can block)
  """

  @behaviour KiroCockpit.Swarm.Hook

  alias KiroCockpit.Swarm.{Event, HookResult}

  @default_threshold 3

  @write_actions [
    :write,
    :file_write_requested,
    :file_edit_requested,
    :write_file,
    :shell_write_requested,
    :fs_write_requested
  ]

  @impl true
  def name, do: :write_validation

  @impl true
  def priority, do: 90

  @impl true
  def filter(%Event{action_name: action}) do
    action in @write_actions
  end

  @impl true
  def on_event(event, ctx) do
    failure_count = trusted_int(ctx, :write_failure_count) || 0
    threshold = trusted_int(ctx, :write_failure_threshold) || @default_threshold

    if failure_count >= threshold do
      reason = trusted_string(ctx, :last_write_failure_reason) || "Repeated write failures"
      guidance = build_block_guidance(failure_count, reason)

      HookResult.block(
        event,
        "Write retry loop detected (#{failure_count} consecutive failures)",
        [guidance], hook_metadata: %{failure_count: failure_count, threshold: threshold})
    else
      if failure_count > 0 do
        HookResult.continue(
          event,
          [
            "⚠️ Write failure count: #{failure_count}/#{threshold}. Consider changing strategy before retrying."
          ],
          hook_metadata: %{failure_count: failure_count, threshold: threshold}
        )
      else
        HookResult.continue(event)
      end
    end
  end

  defp build_block_guidance(failure_count, reason) do
    "🛑 Write blocked after #{failure_count} consecutive failures. " <>
      "Last reason: #{reason}. " <>
      "Change approach, inspect the target, or escalate instead of retrying."
  end

  defp trusted_int(ctx, key) do
    case Map.get(ctx, key) || Map.get(ctx, Atom.to_string(key)) do
      nil -> nil
      val when is_integer(val) -> val
      val when is_binary(val) -> parse_int(val)
      _ -> nil
    end
  end

  defp trusted_string(ctx, key) do
    case Map.get(ctx, key) || Map.get(ctx, Atom.to_string(key)) do
      val when is_binary(val) -> val
      _ -> nil
    end
  end

  defp parse_int(str) do
    case Integer.parse(str) do
      {int, _} -> int
      :error -> nil
    end
  end
end
