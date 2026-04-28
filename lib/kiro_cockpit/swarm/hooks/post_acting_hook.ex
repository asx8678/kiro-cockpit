defmodule KiroCockpit.Swarm.Hooks.PostActingHook do
  @moduledoc """
  Reminds the agent to verify or document after making changes.

  Per §27.2, this post-action hook (priority 90, non-blocking) injects
  guidance after mutating actions (writes, shell commands, acting-category
  tasks) prompting the agent to verify its changes (run tests, check
  output) or document what was done.

  ## When it fires

  After any write, shell_write, terminal, or acting-category action.
  The guidance is informational — it does not block execution.

  ## Guidance content

  For write actions: "Verify changes by running relevant tests or
  inspecting the output."

  For shell_write/terminal: "Verify the command succeeded and check
  for side effects."

  For acting-category events: "Document what was changed and verify
  the change meets the task's acceptance criteria."

  The hook respects `ctx[:post_acting_suppressed]` — set to `true`
  to skip guidance (useful in automated or batch contexts where
  per-action reminders are too noisy).

  Priority: 90 (post-action, non-blocking)
  """

  @behaviour KiroCockpit.Swarm.Hook

  alias KiroCockpit.Swarm.{Event, HookResult}

  @write_actions [
    :write,
    :file_write_requested,
    :file_edit_requested,
    :write_file,
    :fs_write_requested
  ]

  @shell_actions [
    :shell_write,
    :shell_write_requested,
    :terminal,
    :terminal_requested
  ]

  @impl true
  def name, do: :post_acting

  @impl true
  def priority, do: 90

  @impl true
  def filter(%Event{action_name: action}) do
    action in @write_actions or action in @shell_actions or
      action in [:kiro_session_prompt, :nano_plan_run]
  end

  @impl true
  def on_event(event, ctx) do
    if suppressed?(ctx) do
      HookResult.continue(event)
    else
      guidance = build_guidance(event)
      HookResult.continue(event, [guidance], hook_metadata: %{post_acting_guidance: true})
    end
  end

  defp build_guidance(%Event{action_name: action}) when action in @write_actions do
    "📝 Post-acting: Verify your changes by running relevant tests or inspecting the output. " <>
      "Consider documenting what was changed if this completes a task step."
  end

  defp build_guidance(%Event{action_name: action}) when action in @shell_actions do
    "📝 Post-acting: Verify the command succeeded and check for unintended side effects. " <>
      "Document any configuration or environment changes."
  end

  defp build_guidance(%Event{action_name: :kiro_session_prompt}) do
    "📝 Post-acting: After the Kiro session completes, verify the result " <>
      "matches the task objective and document any deviations."
  end

  defp build_guidance(%Event{action_name: :nano_plan_run}) do
    "📝 Post-acting: After plan execution, verify each step's output " <>
      "and document any issues encountered."
  end

  defp build_guidance(_event) do
    "📝 Post-acting: Verify the action result and document significant changes."
  end

  defp suppressed?(ctx) do
    truthy?(Map.get(ctx, :post_acting_suppressed)) or
      truthy?(Map.get(ctx, "post_acting_suppressed"))
  end

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_), do: false
end
