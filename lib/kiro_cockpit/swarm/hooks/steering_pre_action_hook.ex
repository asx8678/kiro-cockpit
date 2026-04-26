defmodule KiroCockpit.Swarm.Hooks.SteeringPreActionHook do
  @moduledoc """
  Steering pre-action hook — trusted deterministic signals first, then LLM-backed steering.

  Per §27.7 and §26.6, this hook evaluates action relevance in two layers:

  1. **Trusted deterministic signals** (from server-side `ctx` only) always
     take precedence. These come from `ctx[:steering_signal]`, a map set by
     trusted policy/hook context — never from `event.payload` or
     `event.metadata`, which are untrusted agent-provided data.
     Signal keys include: `steering_decision`, `off_topic`, `drift`,
     `guide`, `task_mismatch`.
  2. **LLM-backed SteeringAgent** runs only when no trusted deterministic
     signal is found (`:no_signal`). The agent evaluates context and returns
     one of: `:continue`, `:focus`, `:guide`, or `:block`.

  If no steering model is configured, the hook falls through to a quiet
  `:continue` — deterministic gates have already run elsewhere. This hook's
  priority is intentionally lower than `TaskEnforcementHook` so task/category/
  file-scope gates run before LLM steering.

  Priority: 94 (pre-action, can block after deterministic task gates)
  """

  @behaviour KiroCockpit.Swarm.Hook

  alias KiroCockpit.Swarm.{Event, HookResult, SteeringAgent}

  @steered_actions [
    :read,
    :write,
    :shell_read,
    :shell_write,
    :terminal,
    :external,
    :destructive,
    :subagent,
    :memory_write,
    :kiro_session_prompt,
    :kiro_tool_call_detected,
    :permission_request,
    :file_write_requested,
    :shell_command_requested,
    :subagent_invoke,
    :mcp_tool_invoke,
    :verification_run,
    :memory_promote,
    :nano_plan_generate,
    :nano_plan_approve
  ]

  @decision_by_string %{
    "continue" => :continue,
    "focus" => :focus,
    "guide" => :guide,
    "block" => :block
  }

  @valid_decisions Map.values(@decision_by_string)

  @impl true
  def name, do: :steering_pre_action

  @impl true
  def priority, do: 94

  @impl true
  def filter(%Event{action_name: action}) do
    action in @steered_actions
  end

  @impl true
  def on_event(event, ctx) do
    case check_deterministic_signals(event, ctx) do
      {:focus, message} ->
        HookResult.modify(event, [message], hook_metadata: %{steering_decision: :focus})

      {:guide, message} ->
        HookResult.modify(event, [message], hook_metadata: %{steering_decision: :guide})

      {:block, reason, guidance} ->
        HookResult.block(event, reason, [guidance], hook_metadata: %{steering_decision: :block})

      {:continue, message} ->
        HookResult.continue(event, List.wrap(message),
          hook_metadata: %{steering_decision: :continue}
        )

      :no_signal ->
        run_llm_steering(event, ctx)
    end
  end

  # -------------------------------------------------------------------
  # LLM steering (Ring 2)
  # -------------------------------------------------------------------

  defp run_llm_steering(event, ctx) do
    steering_opts = Map.get(ctx, :steering_opts, [])
    event_map = event_to_map(event)

    {:ok, %SteeringAgent.Decision{} = decision} =
      SteeringAgent.evaluate(event_map, ctx, steering_opts)

    decision_to_hook_result(decision, event)
  end

  defp decision_to_hook_result(%SteeringAgent.Decision{decision: :continue} = d, event) do
    meta = %{steering_decision: :continue, steering_source: d.source}

    HookResult.continue(event, [], hook_metadata: meta)
  end

  defp decision_to_hook_result(%SteeringAgent.Decision{decision: :focus} = d, event) do
    message = build_focus_message(d)
    meta = %{steering_decision: :focus, steering_source: d.source}
    HookResult.modify(event, [message], hook_metadata: meta)
  end

  defp decision_to_hook_result(%SteeringAgent.Decision{decision: :guide} = d, event) do
    message = build_guide_message(d)
    meta = %{steering_decision: :guide, steering_source: d.source}
    HookResult.modify(event, [message], hook_metadata: meta)
  end

  defp decision_to_hook_result(%SteeringAgent.Decision{decision: :block} = d, event) do
    guidance = build_block_guidance(d)
    meta = %{steering_decision: :block, steering_source: d.source}
    HookResult.block(event, d.reason, [guidance], hook_metadata: meta)
  end

  defp build_focus_message(decision) do
    base = "⚡ Steering: slight drift — #{decision.reason}"

    if decision.suggested_next_action do
      base <> " Suggested: #{decision.suggested_next_action}"
    else
      base
    end
  end

  defp build_guide_message(decision) do
    refs_part =
      case decision.memory_refs do
        [] -> ""
        refs -> " [refs: #{Enum.join(refs, ", ")}]"
      end

    base = "🧭 Steering: #{decision.reason}#{refs_part}"

    if decision.suggested_next_action do
      base <> " Suggested: #{decision.suggested_next_action}"
    else
      base
    end
  end

  defp build_block_guidance(decision) do
    base = "🛑 Steering: #{decision.reason}"

    if decision.suggested_next_action do
      base <> " Alternative: #{decision.suggested_next_action}"
    else
      base
    end
  end

  # Convert Event struct to a plain map for SteeringAgent.evaluate
  defp event_to_map(%Event{} = event) do
    %{
      action_name: event.action_name,
      session_id: event.session_id,
      plan_id: event.plan_id,
      task_id: event.task_id,
      agent_id: event.agent_id,
      payload: event.payload
    }
  end

  # -------------------------------------------------------------------
  # Trusted deterministic signals (from ctx only, never event payload/metadata)
  # -------------------------------------------------------------------

  defp check_deterministic_signals(_event, ctx) do
    trusted_signal = ctx_field(ctx, :steering_signal) || ctx_field(ctx, :trusted_steering_signal)
    deterministic_signal(trusted_signal) || :no_signal
  end

  defp deterministic_signal(map) when is_map(map) do
    decision = normalize_decision(map_field(map, :steering_decision))

    cond do
      decision in @valid_decisions ->
        decision_signal(decision, map)

      truthy?(map_field(map, :off_topic)) ->
        {:block, "Action is off-topic",
         guidance(map, :off_topic_guidance, "This action is not related to the current task.")}

      truthy?(map_field(map, :drift)) ->
        {:focus, guidance(map, :drift_message, "Action is drifting from the main task.")}

      truthy?(map_field(map, :guide)) ->
        {:guide, guidance(map, :guide_message, "Consider related context or memory.")}

      truthy?(map_field(map, :task_mismatch)) ->
        {:block, "Task mismatch",
         guidance(map, :task_mismatch_guidance, "Action does not match the active task.")}

      true ->
        nil
    end
  end

  defp deterministic_signal(_map), do: nil

  defp decision_signal(:continue, map) do
    {:continue, map_field(map, :continue_message) || map_field(map, :reason) || []}
  end

  defp decision_signal(:focus, map) do
    {:focus,
     first_message(
       map,
       [:focus_message, :drift_message, :reason, :suggested_next_action],
       "Action is drifting from the main task."
     )}
  end

  defp decision_signal(:guide, map) do
    {:guide,
     first_message(
       map,
       [:guide_message, :reason, :suggested_next_action],
       "Consider related context or memory."
     )}
  end

  defp decision_signal(:block, map) do
    reason = first_message(map, [:block_reason, :reason], "Action blocked by steering")

    guidance =
      first_message(
        map,
        [:block_guidance, :suggested_next_action],
        "Action is off-topic or unsafe."
      )

    {:block, reason, guidance}
  end

  defp guidance(map, key, default) do
    first_message(map, [key, :suggested_next_action, :reason], default)
  end

  defp first_message(map, keys, default) do
    Enum.find_value(keys, fn key ->
      value = map_field(map, key)
      if is_binary(value) and String.trim(value) != "", do: value
    end) || default
  end

  defp normalize_decision(decision) when is_atom(decision) do
    if decision in @valid_decisions, do: decision, else: nil
  end

  defp normalize_decision(decision) when is_binary(decision) do
    Map.get(@decision_by_string, decision)
  end

  defp normalize_decision(_decision), do: nil

  defp map_field(map, key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp ctx_field(ctx, key) do
    Map.get(ctx, key) || Map.get(ctx, Atom.to_string(key))
  end

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_value), do: false
end
