defmodule KiroCockpit.Swarm.Hooks.TaskEnforcementHook do
  @moduledoc """
  Enforces task requirements for non-exempt actions.

  Per §27.6, this hook:
  1. Requires an active task for non-exempt actions
  2. Allows direct read-only discovery in plan mode (planning/waiting) without a task
  3. Enforces category permission scope via TaskScope
  4. Enforces file scope when event payload/metadata includes target paths
  5. Blocks with actionable guidance when requirements aren't met

  Priority: 95 (pre-action, can block)
  """

  @behaviour KiroCockpit.Swarm.Hook

  alias KiroCockpit.Permissions
  alias KiroCockpit.Swarm.{Event, HookResult, PlanMode}
  alias KiroCockpit.Swarm.Tasks.{CategoryMatrix, TaskManager, TaskScope}

  @permissions Permissions.permissions()

  @exempt_actions [
    :task_create,
    :task_activate,
    :task_complete,
    :task_block,
    :plan_approved
  ]

  # Lifecycle actions exempt from active-task requirement but still
  # subject to stale/plan-mode checks. These actions initiate or
  # advance the plan/task flow — requiring an active task would be
  # circular (you need a plan to create a task, but the plan
  # generation itself shouldn't need a task first).
  @lifecycle_actions [
    :nano_plan_run,
    :nano_plan_generate,
    :nano_plan_approve
  ]

  @action_permissions %{
    file_read_requested: :read,
    read_file: :read,
    list_files: :read,
    grep: :read,
    search: :read,
    file_write_requested: :write,
    file_edit_requested: :write,
    write_file: :write,
    shell_read_requested: :shell_read,
    shell_write_requested: :shell_write,
    terminal_requested: :terminal,
    external_requested: :external,
    subagent_invoke: :subagent,
    kiro_delegate: :subagent,
    memory_promote: :memory_write,
    memory_write: :memory_write,
    # KiroSession prompt and callback action mappings (kiro-00j)
    kiro_session_prompt: :subagent,
    fs_read_requested: :read,
    fs_write_requested: :write,
    nano_plan_run: :write,
    nano_plan_generate: :subagent,
    nano_plan_approve: :write
  }

  @impl true
  def name, do: :task_enforcement

  @impl true
  def priority, do: 95

  # nano_plan_run and other lifecycle actions are only exempt from the
  # active-task requirement, not from stale/plan-mode checks. Use filter:
  # true so they still run through the full hook chain;
  # check_active_task_requirement special-cases them.
  @impl true
  def filter(%Event{action_name: action}) when action in @lifecycle_actions, do: true
  def filter(%Event{action_name: action}) when action in @exempt_actions, do: false
  def filter(%Event{}), do: true

  @impl true
  def on_event(event, ctx) do
    with :ok <- check_plan_mode(event, ctx),
         :ok <- check_stale_plan(event, ctx),
         :ok <- check_active_task_requirement(event, ctx),
         :ok <- check_category_permission(event, ctx),
         :ok <- check_file_scope(event, ctx) do
      HookResult.continue(event)
    else
      {:blocked, reason, guidance} ->
        HookResult.block(event, reason, [guidance])
    end
  end

  # Apply the outer plan-mode gate before task/category checks.
  defp check_plan_mode(event, ctx) do
    plan_mode = Map.get(ctx, :plan_mode) || PlanMode.new()
    permission = permission_for_event(event)

    case PlanMode.check_action(plan_mode, permission) do
      :ok -> :ok
      {:blocked, reason, guidance} -> {:blocked, reason, guidance}
    end
  end

  # Stale-plan gate (§36.2): block mutating actions when trusted ctx signals
  # a stale active plan. Read-only and diagnostic actions (read, shell_read)
  # remain unaffected. Explicit trusted override models the §32.3 "run anyway
  # with confirmation" path. Never source this decision from untrusted event
  # metadata/payload.
  defp check_stale_plan(event, ctx) do
    permission = permission_for_event(event)

    cond do
      not stale_plan?(ctx) ->
        :ok

      stale_plan_override?(ctx) ->
        :ok

      non_mutating_permission?(permission) ->
        :ok

      true ->
        {:blocked, "Stale plan blocks mutating action",
         "The active plan is stale. Refresh/reapprove it, diff the snapshot, " <>
           "or explicitly confirm a run-anyway override before making changes."}
    end
  end

  # Check if an active task is required for this action.
  # Lifecycle actions (nano_plan_run, nano_plan_generate, nano_plan_approve)
  # are exempt from the active-task requirement but still subject to
  # stale/plan-mode checks — these actions initiate or advance the
  # plan/task flow.
  defp check_active_task_requirement(%Event{action_name: action}, _ctx)
       when action in @lifecycle_actions do
    :ok
  end

  defp check_active_task_requirement(event, ctx) do
    plan_mode = Map.get(ctx, :plan_mode) || PlanMode.new()
    active_task = get_active_task(event)
    permission = permission_for_event(event)

    cond do
      read_only_permission?(permission) and PlanMode.planning_locked?(plan_mode) ->
        :ok

      active_task != nil ->
        :ok

      active_task == nil ->
        {:blocked, "No active task",
         "Create or activate a task before performing this action. " <>
           "Use `task create` or `task activate` to start a task."}
    end
  end

  # Check if the task's category allows the action
  defp check_category_permission(event, ctx) do
    active_task = get_active_task(event)

    if active_task do
      permission = permission_for_event(event)

      case TaskScope.permission_allowed?(
             active_task,
             permission,
             approval_opts(event, ctx, active_task)
           ) do
        {:ok, :allowed} ->
          :ok

        {:error, :category_denied} ->
          category = active_task.category
          guidance = "Category '#{category}' does not allow #{permission} actions."
          {:blocked, "Category permission denied", guidance}

        {:error, :scope_denied} ->
          guidance = "Task permission scope does not allow #{permission} actions."
          {:blocked, "Task scope permission denied", guidance}

        {:error, :needs_approval} ->
          guidance =
            "Category '#{active_task.category}' allows #{permission} with approval. " <>
              "Request approval before proceeding."

          {:blocked, "Permission requires approval", guidance}
      end
    else
      :ok
    end
  end

  # Check file scope if the event includes target paths
  defp check_file_scope(event, _ctx) do
    active_task = get_active_task(event)
    target_paths = extract_target_paths(event)
    permission = permission_for_event(event)
    check_file_scope_with_task(active_task, permission, target_paths)
  end

  defp check_file_scope_with_task(nil, _permission, _target_paths), do: :ok

  defp check_file_scope_with_task(%{files_scope: []}, _permission, []), do: :ok

  defp check_file_scope_with_task(_active_task, permission, []) when permission == :write do
    {:blocked, "Missing file scope target",
     "Write/edit actions for scoped tasks must include a safe relative target path."}
  end

  defp check_file_scope_with_task(_active_task, _permission, []), do: :ok

  defp check_file_scope_with_task(active_task, _permission, target_paths) do
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

  defp read_only_permission?(:read), do: true
  defp read_only_permission?(_permission), do: false

  # Non-mutating permissions: read + diagnostic shell_read (grep, git diff, log)
  # These pass through the stale-plan gate unchanged (§36.2).
  defp non_mutating_permission?(:read), do: true
  defp non_mutating_permission?(:shell_read), do: true
  defp non_mutating_permission?(_permission), do: false

  defp permission_for_event(%Event{permission_level: permission})
       when permission in @permissions do
    permission
  end

  defp permission_for_event(%Event{action_name: action}) when action in @permissions do
    action
  end

  defp permission_for_event(%Event{action_name: action}) do
    Map.get(@action_permissions, action)
  end

  defp approval_opts(event, ctx, active_task) do
    target_paths = extract_target_paths(event)

    [
      approved: truthy?(trusted_lookup(ctx, :approved)),
      policy_allows_write: truthy?(trusted_lookup(ctx, :policy_allows_write)),
      root_cause_stated:
        truthy?(trusted_lookup(ctx, :root_cause_stated)) or
          CategoryMatrix.debugging_write_unlocked?(active_task),
      fixing_test_fixture:
        truthy?(trusted_lookup(ctx, :fixing_test_fixture)) or fixture_scoped_paths?(target_paths),
      docs_scoped:
        truthy?(trusted_lookup(ctx, :docs_scoped)) or
          CategoryMatrix.docs_scoped_paths?(target_paths),
      paths: target_paths,
      subagent_kind: trusted_lookup(ctx, :subagent_kind)
    ]
  end

  defp trusted_lookup(ctx, key) do
    if Map.has_key?(ctx, key), do: Map.get(ctx, key), else: nil
  end

  defp stale_plan?(ctx) do
    truthy?(trusted_lookup(ctx, :stale_plan?)) or truthy?(trusted_lookup(ctx, :stale_plan))
  end

  defp stale_plan_override?(ctx) do
    truthy?(trusted_lookup(ctx, :stale_plan_override?)) or
      truthy?(trusted_lookup(ctx, :stale_plan_override)) or
      truthy?(trusted_lookup(ctx, :stale_plan_confirmed?))
  end

  defp truthy?(value), do: value in [true, "true", 1, "1", :yes, "yes"]

  defp fixture_scoped_paths?([]), do: false

  defp fixture_scoped_paths?(paths) do
    Enum.all?(paths, fn path ->
      String.contains?(path, "fixture") or String.contains?(path, "/fixtures/")
    end)
  end

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
