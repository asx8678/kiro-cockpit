defmodule KiroCockpit.Swarm.Hooks.PlanModeFirstActionHook do
  @moduledoc """
  Injects decomposition/read-only guidance on actions in plan mode.

  Per §27.6/§36.2, when in planning or waiting_for_approval state, inject
  guidance to help the operator understand that direct reads are allowed for
  discovery while shell/command/mutating tools are blocked until approval.

  ## Design (kiro-2tt reviewer fix)

  Guidance is **per-event and stateless**: every action that fires while
  `PlanMode.planning_locked?/1` is true receives guidance. No process-dictionary
  sentinel, no accumulated state, no lifecycle reset needed.

  Rationale (§4.1): process-dictionary sentinels are not durable — they
  evaporate on process crash/migration, cannot cross process boundaries (hooks
  may run in different processes across ActionBoundary calls), and a nil
  `session_id` produces a shared key that corrupts tracking across sessions.

  The guidance is informational (non-blocking), so re-injecting it on each
  action while planning-locked is harmless and arguably more helpful: an
  operator who joins mid-session still sees the context. When the plan
  transitions out of planning/waiting_for_approval, guidance stops naturally
  because `planning_locked?/1` returns false.

  The `ctx` key `:first_action_shown` is retained for backward compatibility
  with tests that explicitly suppress guidance by setting it to `true`.

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

    # Per-event, stateless: inject guidance whenever planning is locked AND
    # the caller hasn't explicitly suppressed it via ctx (:first_action_shown
    # is retained for backward compatibility with unit tests only).
    # No process-dictionary sentinel — see moduledoc.
    suppressed? = Map.get(ctx, :first_action_shown, false)

    if PlanMode.planning_locked?(plan_mode) and not suppressed? do
      guidance = build_guidance(event, plan_mode)
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
