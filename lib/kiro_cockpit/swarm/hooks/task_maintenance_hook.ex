defmodule KiroCockpit.Swarm.Hooks.TaskMaintenanceHook do
  @moduledoc """
  Reminds about stale, inactive, or blocked tasks in the execution lane.

  Per §27.2, this post-action hook (priority 90, non-blocking) checks
  task health after every non-exempt action and injects reminders when:

    1. The active task has been running for too long without progress
       (stale active task)
    2. There are blocked tasks that need attention
    3. There are pending tasks but no active task (stall condition)

  ## Trusted context keys

  Task health signals come from **trusted** `ctx` only:

    - `ctx[:active_task]` — the currently active task struct (or nil)
    - `ctx[:pending_tasks]` — count of pending tasks (integer)
    - `ctx[:blocked_tasks]` — count of blocked tasks (integer)
    - `ctx[:active_task_stale?]` — whether the active task appears stale

  When these keys are absent, the hook falls through quietly — it does
  not query the database directly (hooks should remain pure functions
  of event + ctx for testability and determinism).

  ## Suppression

  Set `ctx[:task_maintenance_suppressed]` to `true` to silence
  reminders (useful in batch operations or automated flows).

  Priority: 90 (post-action, non-blocking)
  """

  @behaviour KiroCockpit.Swarm.Hook

  alias KiroCockpit.Swarm.{Event, HookResult}
  alias KiroCockpit.Swarm.Tasks.TaskManager

  @exempt_actions [
    :task_create,
    :task_activate,
    :task_complete,
    :task_block,
    :plan_approved,
    :nano_plan_generate,
    :nano_plan_approve,
    :nano_plan_run
  ]

  @impl true
  def name, do: :task_maintenance

  @impl true
  def priority, do: 90

  @impl true
  def filter(%Event{action_name: action}) do
    action not in @exempt_actions
  end

  @impl true
  def on_event(event, ctx) do
    if suppressed?(ctx) do
      HookResult.continue(event)
    else
      messages = collect_maintenance_messages(event, ctx)

      if messages == [] do
        HookResult.continue(event)
      else
        HookResult.continue(event, messages, hook_metadata: %{task_maintenance_reminders: true})
      end
    end
  end

  defp collect_maintenance_messages(event, ctx) do
    []
    |> maybe_add_stale_active_message(ctx)
    |> maybe_add_blocked_tasks_message(event, ctx)
    |> maybe_add_stall_message(ctx)
  end

  defp maybe_add_stale_active_message(messages, ctx) do
    if stale_active_task?(ctx) do
      messages ++
        [
          "🔧 Task maintenance: Active task appears stale. " <>
            "Consider completing, blocking, or re-scoping it."
        ]
    else
      messages
    end
  end

  defp maybe_add_blocked_tasks_message(messages, event, ctx) do
    blocked_count = blocked_task_count(event, ctx)

    if blocked_count > 0 do
      messages ++
        [
          "🔧 Task maintenance: #{blocked_count} blocked task(s) need attention. " <>
            "Resolve blockers, revise the plan, or ask the user."
        ]
    else
      messages
    end
  end

  defp maybe_add_stall_message(messages, ctx) do
    pending_count = pending_task_count(ctx)
    active_task = ctx_active_task(ctx)

    if is_nil(active_task) and pending_count > 0 do
      messages ++
        [
          "🔧 Task maintenance: #{pending_count} pending task(s) but no active task. " <>
            "Activate a task to continue execution."
        ]
    else
      messages
    end
  end

  defp stale_active_task?(ctx) do
    truthy?(Map.get(ctx, :active_task_stale?)) or
      truthy?(Map.get(ctx, "active_task_stale?"))
  end

  defp blocked_task_count(event, ctx) do
    case Map.get(ctx, :blocked_tasks) || Map.get(ctx, "blocked_tasks") do
      count when is_integer(count) -> count
      _ -> count_blocked_from_db(event)
    end
  end

  defp pending_task_count(ctx) do
    case Map.get(ctx, :pending_tasks) || Map.get(ctx, "pending_tasks") do
      count when is_integer(count) -> count
      _ -> 0
    end
  end

  defp ctx_active_task(ctx) do
    Map.get(ctx, :active_task) || Map.get(ctx, "active_task")
  end

  # Best-effort DB lookup when ctx doesn't provide counts.
  # Returns 0 on any error — never crashes.
  defp count_blocked_from_db(%Event{session_id: session_id, agent_id: agent_id})
       when is_binary(session_id) and is_binary(agent_id) do
    try do
      TaskManager.count_by_status(session_id, agent_id, "blocked")
    rescue
      _ -> 0
    end
  end

  defp count_blocked_from_db(_event), do: 0

  defp suppressed?(ctx) do
    truthy?(Map.get(ctx, :task_maintenance_suppressed)) or
      truthy?(Map.get(ctx, "task_maintenance_suppressed"))
  end

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_), do: false
end
