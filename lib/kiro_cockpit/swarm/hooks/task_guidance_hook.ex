defmodule KiroCockpit.Swarm.Hooks.TaskGuidanceHook do
  @moduledoc """
  Injects guidance after task operations and plan approval events.

  Per §27.9, this hook provides actionable guidance for:
  - Task creation with no active task
  - Task activation (in_progress)
  - Task completion
  - Task blocking
  - Plan approval

  Priority: 85 (post-action, non-blocking)
  """

  @behaviour KiroCockpit.Swarm.Hook

  alias KiroCockpit.Swarm.{Event, HookResult}
  alias KiroCockpit.Swarm.Tasks.TaskManager

  @impl true
  def name, do: :task_guidance

  @impl true
  def priority, do: 85

  @impl true
  def filter(%Event{action_name: action}) do
    # Apply to task-related actions and plan approval
    action in [:task_create, :task_activate, :task_complete, :task_block, :plan_approved]
  end

  @impl true
  def on_event(event, ctx) do
    guidance = build_guidance(event, ctx)

    if guidance do
      HookResult.continue(event, [guidance])
    else
      HookResult.continue(event)
    end
  end

  defp build_guidance(event, _ctx) do
    case event.action_name do
      :task_create ->
        # Check if there's an active task
        active_task = get_active_task(event)

        if active_task == nil do
          "Activate the next task with status=in_progress before execution."
        else
          nil
        end

      :task_activate ->
        "Task is active. Proceed within its category and permission scope."

      :task_complete ->
        "Pick the next pending task or run final verification."

      :task_block ->
        "Resolve blocker, revise plan, or ask user."

      :plan_approved ->
        "Create/activate Phase 1 task and begin read-only inspection."

      _ ->
        nil
    end
  end

  defp get_active_task(event) do
    if event.session_id && event.agent_id do
      TaskManager.get_active(event.session_id, event.agent_id)
    else
      nil
    end
  end
end
