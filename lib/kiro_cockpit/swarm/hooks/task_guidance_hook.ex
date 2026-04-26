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
  alias KiroCockpit.Swarm.Tasks.{Guidance, TaskManager}

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
        active_task = get_active_task(event)
        guidance = Guidance.for_create(is_nil(active_task) == false)
        if guidance == [], do: nil, else: hd(guidance)

      :task_activate ->
        hd(Guidance.for_activate())

      :task_complete ->
        hd(Guidance.for_complete())

      :task_block ->
        hd(Guidance.for_block())

      :plan_approved ->
        hd(Guidance.for_plan_approved())

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
