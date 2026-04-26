defmodule KiroCockpit.Swarm.Hooks.PlanModeFirstActionHook do
  @moduledoc """
  Injects decomposition/read-only guidance on the first action in plan mode.

  Per §27.6/§36.2, when in planning or waiting_for_approval state and this is
  the first action/tool, inject guidance to help the operator understand that
  direct reads are allowed for discovery while shell/command/mutating tools are
  blocked until approval.

  Priority: 96 (pre-action, non-blocking)
  """

  @behaviour KiroCockpit.Swarm.Hook

  alias KiroCockpit.Permissions
  alias KiroCockpit.Swarm.{Event, HookResult, PlanMode}

  @permissions Permissions.permissions()

  @impl true
  def name, do: :plan_mode_first_action

  @impl true
  def priority, do: 96

  @impl true
  def filter(%Event{} = event) do
    # Apply to wrapper/tool actions that carry a permission level, plus direct
    # permission-shaped action names used by foundation tests.
    permission_for_event(event) in @permissions
  end

  @impl true
  def on_event(event, ctx) do
    plan_mode = Map.get(ctx, :plan_mode) || PlanMode.new()
    first_action_shown = Map.get(ctx, :first_action_shown, false)

    if PlanMode.planning_locked?(plan_mode) and not first_action_shown do
      guidance = build_guidance(event, plan_mode)
      # Mark that we've shown the first action guidance
      _updated_ctx = Map.put(ctx, :first_action_shown, true)
      HookResult.modify(event, [guidance], hook_metadata: %{first_action_shown: true})
    else
      HookResult.continue(event)
    end
  end

  defp build_guidance(event, plan_mode) do
    action = event.action_name
    permission = permission_for_event(event)
    permission_guidance = permission_guidance(permission)

    case plan_mode.state do
      :planning ->
        "You are in plan mode (planning). " <>
          "Focus on read-only discovery and planning output. Direct reads are allowed; " <>
          "shell commands and mutations are blocked until the plan is approved. " <>
          "Action '#{action}' requested #{permission_label(permission)}. #{permission_guidance}"

      :waiting_for_approval ->
        "You are in plan mode (waiting for approval). " <>
          "The plan draft is ready for review. Direct reads remain allowed while shell/command/mutating tools are blocked. " <>
          "Action '#{action}' requested #{permission_label(permission)}. #{permission_guidance} " <>
          "Once approved, you can proceed with implementation."

      _ ->
        "Action '#{action}' detected."
    end
  end

  defp permission_guidance(:read) do
    "This direct read action is allowed for discovery purposes."
  end

  defp permission_guidance(_permission) do
    "Shell/command/mutating tools are blocked in plan mode until the plan is approved."
  end

  defp permission_label(nil), do: "no explicit permission"
  defp permission_label(permission), do: "#{permission} permission"

  defp permission_for_event(%Event{permission_level: permission})
       when permission in @permissions do
    permission
  end

  defp permission_for_event(%Event{action_name: action}) when action in @permissions do
    action
  end

  defp permission_for_event(_event), do: nil
end
