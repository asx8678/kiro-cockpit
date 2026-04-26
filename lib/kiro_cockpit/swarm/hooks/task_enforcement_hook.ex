defmodule KiroCockpit.Swarm.Hooks.TaskEnforcementHook do
  @moduledoc """
  Enforces task requirements for non-exempt actions.

  Per §27.6, this hook:
  1. Requires an active task for non-exempt actions
  2. Allows read-only discovery in plan mode (planning/waiting) without a task
  3. Enforces category permission scope via TaskScope
  4. Enforces file scope when event payload/metadata includes target paths
  5. Blocks with actionable guidance when requirements aren't met

  Priority: 95 (pre-action, can block)
  """

  @behaviour KiroCockpit.Swarm.Hook

  alias KiroCockpit.Swarm.{Event, HookResult, PlanMode}
  alias KiroCockpit.Swarm.Tasks.{TaskManager, TaskScope}

  @permissions [:read, :write, :shell_read, :shell_write, :terminal, :external, :destructive]

  @impl true
  def name, do: :task_enforcement

  @impl true
  def priority, do: 95

  @impl true
  def filter(%Event{} = event) do
    # Apply to wrapper/tool actions that carry a permission level, plus the
    # direct permission-shaped action names used by foundation tests.
    permission_for_event(event) in @permissions
  end

  @impl true
  def on_event(event, ctx) do
    with :ok <- check_active_task_requirement(event, ctx),
         :ok <- check_category_permission(event, ctx),
         :ok <- check_file_scope(event, ctx) do
      HookResult.continue(event)
    else
      {:blocked, reason, guidance} ->
        HookResult.block(event, reason, [guidance])
    end
  end

  # Check if an active task is required for this action
  defp check_active_task_requirement(event, ctx) do
    plan_mode = Map.get(ctx, :plan_mode) || PlanMode.new()
    active_task = get_active_task(event)
    permission = permission_for_event(event)

    cond do
      # Exempt: read-only actions in planning/waiting mode (no task required)
      read_only_permission?(permission) and PlanMode.planning_locked?(plan_mode) ->
        :ok

      # Active task exists - continue to category check
      active_task != nil ->
        :ok

      # No active task and not in planning/waiting mode with read-only action
      active_task == nil ->
        {:blocked, "No active task",
         "Create or activate a task before performing this action. " <>
           "Use `task create` or `task activate` to start a task."}
    end
  end

  # Check if the task's category allows the action
  defp check_category_permission(event, _ctx) do
    active_task = get_active_task(event)

    if active_task do
      permission = permission_for_event(event)

      case TaskScope.permission_allowed?(active_task, permission) do
        {:ok, :allowed} ->
          :ok

        {:error, :category_denied} ->
          category = active_task.category
          guidance = "Category '#{category}' does not allow #{permission} actions."
          {:blocked, "Category permission denied", guidance}

        {:error, :scope_denied} ->
          guidance = "Task permission scope does not allow #{permission} actions."
          {:blocked, "Task scope permission denied", guidance}
      end
    else
      :ok
    end
  end

  # Check file scope if the event includes target paths
  defp check_file_scope(event, _ctx) do
    active_task = get_active_task(event)
    target_paths = extract_target_paths(event)
    check_file_scope_with_task(active_task, target_paths)
  end

  defp check_file_scope_with_task(nil, _target_paths), do: :ok

  defp check_file_scope_with_task(_active_task, []), do: :ok

  defp check_file_scope_with_task(active_task, target_paths) do
    Enum.reduce_while(target_paths, :ok, fn path, _acc ->
      case TaskScope.file_allowed?(active_task, path) do
        {:ok, :allowed} ->
          {:cont, :ok}

        {:error, :out_of_scope} ->
          {:halt, {:blocked, "File out of scope", "File '#{path}' is outside task's file scope."}}
      end
    end)
  end

  # Helper functions

  defp get_active_task(event) do
    if event.session_id && event.agent_id do
      TaskManager.get_active(event.session_id, event.agent_id)
    else
      nil
    end
  end

  defp read_only_permission?(permission) when permission in [:read, :shell_read], do: true
  defp read_only_permission?(_permission), do: false

  defp permission_for_event(%Event{permission_level: permission})
       when permission in @permissions do
    permission
  end

  defp permission_for_event(%Event{action_name: action}) when action in @permissions do
    action
  end

  defp permission_for_event(_event), do: nil

  defp extract_target_paths(event) do
    # Look for target paths in payload or metadata
    payload_paths = extract_paths_from_map(event.payload)
    metadata_paths = extract_paths_from_map(event.metadata)
    Enum.uniq(payload_paths ++ metadata_paths)
  end

  defp extract_paths_from_map(map) do
    Enum.flat_map([:target_path, :paths, :file, :files], fn key ->
      case Map.get(map, key) || Map.get(map, Atom.to_string(key)) do
        path when is_binary(path) -> [path]
        list when is_list(list) -> Enum.filter(list, &is_binary/1)
        _ -> []
      end
    end)
  end
end
