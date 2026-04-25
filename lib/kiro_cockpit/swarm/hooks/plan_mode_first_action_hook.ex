defmodule KiroCockpit.Swarm.Hooks.PlanModeFirstActionHook do
  @moduledoc """
  Injects decomposition/read-only guidance on the first action in plan mode.

  Per §27.8, when in planning or waiting_for_approval state and this is the
  first action/tool, inject guidance to help the operator understand they
  should be doing read-only discovery.

  Priority: 96 (pre-action, non-blocking)
  """

  @behaviour KiroCockpit.Swarm.Hook

  alias KiroCockpit.Swarm.{Event, HookResult, PlanMode}

  @impl true
  def name, do: :plan_mode_first_action

  @impl true
  def priority, do: 96

  @impl true
  def filter(%Event{action_name: action}) do
    # Apply to all actions that could be the first action in plan mode
    action in [:read, :shell_read, :write, :shell_write, :terminal, :external, :destructive]
  end

  @impl true
  def on_event(event, ctx) do
    plan_mode = Map.get(ctx, :plan_mode) || PlanMode.new()
    first_action_shown = Map.get(ctx, :first_action_shown, false)

    if PlanMode.planning_locked?(plan_mode) and not first_action_shown do
      guidance = build_guidance(event.action_name, plan_mode)
      # Mark that we've shown the first action guidance
      _updated_ctx = Map.put(ctx, :first_action_shown, true)
      HookResult.modify(event, [guidance], hook_metadata: %{first_action_shown: true})
    else
      HookResult.continue(event)
    end
  end

  defp build_guidance(action, plan_mode) do
    case plan_mode.state do
      :planning ->
        "You are in plan mode (planning). " <>
          "Focus on read-only discovery: explore the codebase, understand the project structure, " <>
          "and gather information. " <>
          "Avoid making changes until the plan is approved. " <>
          "Action '#{action}' is allowed for discovery purposes."

      :waiting_for_approval ->
        "You are in plan mode (waiting for approval). " <>
          "The plan draft is ready for review. " <>
          "You can continue read-only discovery while waiting. " <>
          "Action '#{action}' is allowed for discovery purposes. " <>
          "Once approved, you can proceed with implementation."

      _ ->
        "Action '#{action}' detected."
    end
  end
end
