defmodule KiroCockpit.Swarm.ActionBoundary do
  @moduledoc """
  Action boundary for the Swarm runtime hook system.

  Every runtime action (KiroSession prompt, auto callbacks, plan run) passes
  through this boundary before execution. The boundary runs HookManager
  pre-hooks; if blocked, the executor is never called and a stable blocked
  tuple is returned with Bronze trace persisted. If allowed, the executor
  runs and post-hooks fire for Bronze trace capture.

  ## Flow

    1. Build or hydrate the Event with correlation from active task when possible
    2. Compute trusted stale context if plan_id + project_dir are available
    3. Hydrate steering context (active_task, plan, history) when swarm_ctx is empty
    4. Run HookManager.run(event, pre_hooks, ctx, :pre)
    5. If blocked → return `{:error, {:swarm_blocked, reason, messages}}`
    6. If allowed → execute the zero-arity fun
    7. Run HookManager.run(event, post_hooks, ctx, :post) for Bronze post trace
    8. Return executor result (post block does not undo execution)

  ## Configuration

  Enabled by default via `Application.get_env(:kiro_cockpit, :swarm_action_hooks_enabled, true)`.
  Test config disables by default; explicit tests enable via opts.

  ## Bronze capture

  HookManager persists hook_trace rows on every run (mandatory §27.11 inv. 7).
  Blocked attempts also persist a full trace — the boundary never silently
  drops a blocked event.

  ## Steering context hydration

  When `swarm_ctx` lacks steering-critical keys (`:active_task`, `:plan`,
  `:task_history`, `:completed_tasks`), the boundary hydrates these from
  the canonical database:

    - `:active_task` — looked up via `TaskManager.get_active/2`
    - `:plan` — loaded via `KiroCockpit.Plans.get_plan/1` when `plan_id` is available
    - `:task_history` / `:completed_tasks` — loaded from task manager
    - `:permission_policy` — built from task scope and permission level

  This ensures `SteeringPreActionHook` and `SteeringAgent` always receive
  full context for LLM-backed steering decisions, even when callers don't
  provide `swarm_ctx`.
  """

  alias KiroCockpit.NanoPlanner.Staleness
  alias KiroCockpit.Swarm.{DataPipeline, Event, HookManager}
  alias KiroCockpit.Swarm.Tasks.{TaskManager, TaskScope}

  @default_pre_hooks [
    KiroCockpit.Swarm.Hooks.PlanModeFirstActionHook,
    KiroCockpit.Swarm.Hooks.TaskEnforcementHook,
    KiroCockpit.Swarm.Hooks.SteeringPreActionHook
  ]

  @default_post_hooks [KiroCockpit.Swarm.Hooks.TaskGuidanceHook]

  @typedoc """
  Context map passed to arity-1 executor functions.

  Contains the modified event after pre-hooks have processed it,
  accumulated messages from hooks, and other boundary context.
  """
  @type executor_context :: %{
          optional(:event) => Event.t(),
          optional(:messages) => [String.t()],
          optional(:hook_messages) => [String.t()]
        }

  @type boundary_result :: {:ok, term()} | {:error, {:swarm_blocked, String.t(), [String.t()]}}

  @doc """
  Run an action through the hook boundary.

  ## Parameters

    * `action` — atom action name (e.g. `:kiro_session_prompt`)
    * `opts` — keyword list with event/boundary options
    * `fun` — zero-arity or arity-1 executor function

  ## Executor Function Support

  The executor function can be:

    * **Arity-0** (`fn -> ... end`) — called with no arguments.
      Hook messages are merged into the event's metadata under `:hook_guidance`
      so they are visible in traces and to post-hooks.
    
    * **Arity-1** (`fn ctx -> ... end`) — called with a context map:
      `%{event: modified_event, messages: messages, hook_messages: messages}`.
      This allows the executor to directly access hook guidance messages
      and inject them into prompts (e.g., for PlanMode or Steering messages).

  ## Options

    * `:session_id` — ACP session ID
    * `:agent_id` — agent identifier
    * `:plan_id` — plan correlation ID (optional)
    * `:task_id` — task correlation ID (optional)
    * `:permission_level` — permission level for the action
    * `:payload` — event payload map
    * `:metadata` — event metadata map
    * `:project_dir` — project directory for staleness checks
    * `:plan_mode` — PlanMode struct for plan-mode gating
    * `:swarm_ctx` — additional trusted context map for hooks
    * `:pre_hooks` — list of pre-action hook modules (default: standard hooks)
    * `:post_hooks` — list of post-action hook modules (default: [])
    * `:hook_manager_module` — module to use for hook execution (default: HookManager)
    * `:task_manager_module` — module for active task lookup (default: TaskManager)
    * `:staleness_module` — module for trusted_context (default: Staleness)
    * `:enabled` — explicitly enable/disable boundary (default: app config)

  ## Returns

    * `{:ok, result}` — executor ran, result is the executor's return value
    * `{:error, {:swarm_blocked, reason, messages}}` — pre-hooks blocked execution
  """
  @spec run(atom(), keyword(), (-> term()) | (executor_context() -> term())) :: boundary_result()
  def run(action, opts, fun) when is_atom(action) and is_function(fun) do
    if boundary_enabled?(opts) do
      run_boundary(action, opts, fun)
    else
      {:ok, call_executor(fun, %{event: nil, messages: [], hook_messages: []})}
    end
  end

  # -- Private implementation ------------------------------------------------

  defp boundary_enabled?(opts) do
    case Keyword.get(opts, :enabled) do
      nil -> Application.get_env(:kiro_cockpit, :swarm_action_hooks_enabled, true)
      explicit -> explicit
    end
  end

  defp run_boundary(action, opts, fun) do
    hm = Keyword.get(opts, :hook_manager_module, HookManager)
    tm = Keyword.get(opts, :task_manager_module, TaskManager)
    staleness_mod = Keyword.get(opts, :staleness_module, Staleness)

    # Build event, hydrating correlation from active task when possible
    event = build_event(action, opts, tm)

    # Build trusted context: merge caller ctx + stale plan context + steering context.
    # Use event.plan_id (which may be hydrated from active task) rather than
    # only opts[:plan_id] so that stale context computation works when the
    # active task carries a plan_id but the caller didn't supply one.
    ctx = build_ctx(opts, event, staleness_mod, tm)

    pre_hooks = Keyword.get(opts, :pre_hooks, @default_pre_hooks)
    post_hooks = Keyword.get(opts, :post_hooks, @default_post_hooks)

    # Bronze Phase 3: Record action_before for audit trail (§35)
    # This captures the action entering the boundary before pre-hooks run
    if DataPipeline.action_capture_enabled?() do
      DataPipeline.record_action_before(event, ctx)
    end

    case hm.run(event, pre_hooks, ctx, :pre) do
      {:ok, modified_event, messages} ->
        # kiro-4dk: Thread modified event and hook messages to executor and post-hooks
        # For arity-0 functions, merge hook messages into event metadata for trace visibility
        # For arity-1 functions, pass context map with event, messages, and hook_messages
        {event_for_executor, executor_ctx} =
          prepare_executor_context(modified_event, messages)

        result = call_executor(fun, executor_ctx)

        # Post-hooks for Bronze trace; never undo execution on post block
        # kiro-4dk: Pass the modified event (not original) so post-hooks see pre-hook changes
        _ = hm.run(event_for_executor, post_hooks, ctx, :post)

        # Bronze Phase 3: Record action_after with result (§35)
        # Pass actual executor result shape so Bronze captures error status correctly.
        if DataPipeline.action_capture_enabled?() do
          DataPipeline.record_action_after(event_for_executor, bronze_result(result), ctx)
        end

        {:ok, result}

      {:blocked, blocked_event, reason, messages} ->
        # Bronze Phase 3: Record action_blocked for fail-closed audit (§35)
        # Blocked actions always persist a Bronze record per §27.11 inv. 7
        if DataPipeline.action_capture_enabled?() do
          blocking_hook = extract_blocking_hook(messages)

          DataPipeline.record_action_blocked(blocked_event, reason, messages, ctx,
            blocking_hook: blocking_hook
          )
        end

        {:error, {:swarm_blocked, reason, messages}}
    end
  end

  # Extract the hook name that blocked from hook result messages
  # This is a best-effort heuristic for audit purposes
  defp extract_blocking_hook(messages) do
    # Look for message patterns that indicate which hook blocked
    # Default to "unknown" if we can't determine
    Enum.find_value(messages, "unknown", fn msg ->
      cond do
        String.contains?(msg, "TaskEnforcement") -> "TaskEnforcementHook"
        String.contains?(msg, "Steering") -> "SteeringPreActionHook"
        String.contains?(msg, "PlanMode") -> "PlanModeFirstActionHook"
        true -> nil
      end
    end)
  end

  # Normalize executor result for Bronze capture.
  # If the executor returned {:error, _}, Bronze result_status must be
  # :error, not :ok. The boundary itself still returns {:ok, result}
  # because it didn't block — but Bronze records the executor truth.
  defp bronze_result({:ok, _} = result), do: result
  defp bronze_result({:error, _} = result), do: result
  defp bronze_result(other), do: {:ok, other}

  # Prepare context for executor based on function arity.
  # For arity-0: merge hook messages into event metadata so they persist in traces.
  # For arity-1: return context map with event, messages, hook_messages.
  defp prepare_executor_context(modified_event, messages) do
    if messages == [] do
      {modified_event, %{event: modified_event, messages: [], hook_messages: []}}
    else
      # Merge hook guidance into event metadata for trace visibility
      existing_guidance = List.wrap(modified_event.metadata[:hook_guidance])

      updated_metadata =
        Map.put(modified_event.metadata, :hook_guidance, existing_guidance ++ messages)

      event_with_guidance = %{modified_event | metadata: updated_metadata}

      executor_ctx = %{
        event: event_with_guidance,
        messages: messages,
        hook_messages: messages
      }

      {event_with_guidance, executor_ctx}
    end
  end

  # Call executor function, handling both arity-0 and arity-1.
  # Arity-1 functions receive the executor context map.
  defp call_executor(fun, _ctx) when is_function(fun, 0) do
    fun.()
  end

  defp call_executor(fun, ctx) when is_function(fun, 1) do
    fun.(ctx)
  end

  # Fallback for other function arities - treat as arity-0
  defp call_executor(fun, _ctx) do
    fun.()
  end

  defp build_event(action, opts, tm) do
    session_id = Keyword.get(opts, :session_id)
    agent_id = Keyword.get(opts, :agent_id)

    # Hydrate task_id / plan_id from active task when event lacks them
    {task_id, plan_id} =
      hydrate_correlation(
        Keyword.get(opts, :task_id),
        Keyword.get(opts, :plan_id),
        session_id,
        agent_id,
        tm
      )

    Event.new(action,
      session_id: session_id,
      agent_id: agent_id,
      plan_id: plan_id,
      task_id: task_id,
      permission_level: Keyword.get(opts, :permission_level),
      payload: Keyword.get(opts, :payload, %{}),
      raw_payload: Keyword.get(opts, :raw_payload, %{}),
      metadata: Keyword.get(opts, :metadata, %{})
    )
  end

  # Hydrate task_id/plan_id from the active task when the caller doesn't
  # provide them. Each is hydrated independently — if the caller supplies
  # a plan_id but no task_id, the active task's task_id is still used.
  # This ensures traces with a provided plan_id still get task_id.
  defp hydrate_correlation(task_id, plan_id, session_id, agent_id, tm)
       when is_binary(session_id) and is_binary(agent_id) do
    if is_nil(task_id) or is_nil(plan_id) do
      case safe_get_active(tm, session_id, agent_id) do
        nil ->
          {task_id, plan_id}

        task ->
          {
            task_id || task.id,
            plan_id || task.plan_id
          }
      end
    else
      {task_id, plan_id}
    end
  end

  defp hydrate_correlation(task_id, plan_id, _session_id, _agent_id, _tm) do
    {task_id, plan_id}
  end

  # Active-task lookup is part of the pre-action boundary. If the task store
  # is unavailable, fail closed later in TaskEnforcementHook rather than
  # crashing the runtime before HookManager can persist a blocked trace.
  defp safe_get_active(tm, session_id, agent_id) do
    tm.get_active(session_id, agent_id)
  rescue
    _ -> nil
  end

  defp build_ctx(opts, event, staleness_mod, tm) do
    base_ctx = Keyword.get(opts, :swarm_ctx, %{})
    plan_mode = Keyword.get(opts, :plan_mode)

    # Add plan_mode to ctx if provided
    ctx =
      if plan_mode do
        Map.put(base_ctx, :plan_mode, plan_mode)
      else
        base_ctx
      end

    # Compute trusted stale context if plan_id + project_dir available.
    # Use event.plan_id (hydrated from active task) rather than only opts[:plan_id]
    # so that active-task plan_id hydration feeds stale context computation.
    project_dir = Keyword.get(opts, :project_dir)
    plan_id = event.plan_id

    ctx =
      if plan_id && project_dir do
        staleness_opts =
          opts
          |> Enum.filter(fn {k, _v} -> k in [:context_builder_module] end)
          |> Enum.into(%{})

        merge_trusted_stale_ctx(ctx, plan_id, project_dir, staleness_mod, staleness_opts)
      else
        ctx
      end

    # Preserve explicit durable override keys from ctx/options
    # (:stale_plan_override? / :stale_plan_confirmed?)
    ctx =
      opts
      |> Enum.filter(fn {k, _v} -> k in [:stale_plan_override?, :stale_plan_confirmed?] end)
      |> Enum.reduce(ctx, fn {k, v}, acc -> Map.put(acc, k, v) end)

    # kiro-6dw: Derive trusted provenance flags from durable server-side state
    # instead of blindly copying from caller opts. Approval/policy/root-cause
    # flags must come from:
    #   - Durable plan/task/approval state in the database
    #   - Trusted internal swarm_ctx (set by NanoPlanner.approve, a trusted call site)
    # Arbitrary caller opts are NOT a trusted source for these flags.
    ctx =
      ctx
      |> derive_approved_from_durable_state(event)
      |> derive_policy_allows_write_from_durable_state(event)

    # kiro-6dw: root_cause_stated, fixing_test_fixture, docs_scoped are
    # category-conditional flags. They may come from:
    #   - Trusted internal swarm_ctx (set by NanoPlanner.approve)
    #   - CategoryMatrix path analysis (fallback in TaskEnforcementHook)
    # They must NOT be blindly accepted from arbitrary caller opts.
    # Only preserve these if they already exist in swarm_ctx (base_ctx);
    # do NOT lift them from top-level opts keys.
    #
    # Note: swarm_ctx values are already in ctx from base_ctx above.
    # The old code copied these from opts top-level keys — that path is
    # removed. TaskEnforcementHook.approval_opts/3 still has CategoryMatrix
    # fallbacks for these flags.

    # Hydrate steering context when empty/incomplete (kiro-oai steering-context-hydration)
    ctx = maybe_hydrate_steering_context(ctx, opts, event, tm)

    ctx
  end

  # kiro-6dw: Derive the :approved flag from durable plan state.
  #
  # Only two trusted sources:
  #   1. swarm_ctx already contains :approved from NanoPlanner.approve
  #      (trusted internal call site) — preserve it.
  #   2. The plan's durable status is "approved" or "running" — derive
  #      :approved = true from the canonical DB row.
  #
  # Never trust arbitrary caller opts for this flag.
  defp derive_approved_from_durable_state(ctx, event) do
    cond do
      # Already set in swarm_ctx by trusted internal caller (NanoPlanner.approve)
      Map.has_key?(ctx, :approved) ->
        ctx

      # Derive from durable plan status
      event.plan_id != nil ->
        approved = plan_status_approved?(event.plan_id)
        Map.put(ctx, :approved, approved)

      true ->
        Map.put(ctx, :approved, false)
    end
  end

  # kiro-6dw: Derive :policy_allows_write from durable state.
  #
  # policy_allows_write is true when the plan is approved/running AND
  # the active task's permission scope includes :write. This must be
  # derived from durable state, not from caller opts.
  defp derive_policy_allows_write_from_durable_state(ctx, event) do
    cond do
      # Already set in swarm_ctx by trusted internal caller
      Map.has_key?(ctx, :policy_allows_write) ->
        ctx

      # Derive: plan must be approved/running AND task must allow write
      Map.get(ctx, :approved) == true and event.task_id != nil ->
        policy = task_allows_write?(event.task_id)
        Map.put(ctx, :policy_allows_write, policy)

      true ->
        Map.put(ctx, :policy_allows_write, false)
    end
  end

  # Check if the plan's durable status is approved or running.
  defp plan_status_approved?(plan_id) do
    case safe_get_plan(plan_id) do
      %{status: status} when status in ["approved", "running"] -> true
      _ -> false
    end
  end

  # Check if the task's permission scope allows write.
  defp task_allows_write?(task_id) do
    # Delegate to TaskScope with only the :approved flag; no other
    # caller-supplied flags — TaskEnforcementHook adds CategoryMatrix
    # fallbacks for root_cause_stated/fixing_test_fixture/docs_scoped.
    task = safe_get_task(task_id)

    if task do
      case TaskScope.permission_allowed?(
             task,
             :write,
             approved: true
           ) do
        {:ok, :allowed} -> true
        _ -> false
      end
    else
      false
    end
  end

  # Safe wrapper for task lookup by ID.
  defp safe_get_task(task_id) do
    KiroCockpit.Repo.get(KiroCockpit.Swarm.Tasks.Task, task_id)
  rescue
    _ -> nil
  end

  # Compute trusted stale context from the plan and merge into ctx.
  # Never trust event payload/metadata for stale state.
  # Passes staleness-related opts (e.g. :context_builder_module) through
  # to Staleness.trusted_context/3 so callers can inject test doubles.
  defp merge_trusted_stale_ctx(ctx, plan_id, project_dir, staleness_mod, staleness_opts) do
    plan = KiroCockpit.Plans.get_plan(plan_id)

    if plan do
      stale_ctx = staleness_mod.trusted_context(plan, project_dir, Map.to_list(staleness_opts))
      Map.merge(ctx, stale_ctx)
    else
      # A referenced plan that cannot be loaded is an unknown stale-plan
      # state. Fail closed rather than silently allowing mutation.
      Map.merge(ctx, %{stale_plan?: true, reason: :stale_plan_unknown})
    end
  rescue
    # Plan lookup/snapshot checks may fail (e.g. DB down); don't crash the
    # runtime. Surface a trusted fail-closed stale context to hooks.
    _ -> Map.merge(ctx, %{stale_plan?: true, reason: :stale_plan_unknown})
  end

  # -------------------------------------------------------------------
  # Steering context hydration (kiro-oai steering-context-hydration)
  # -------------------------------------------------------------------

  # Hydrates steering-critical context keys when swarm_ctx is empty or incomplete.
  # This ensures SteeringPreActionHook and SteeringAgent receive full context
  # for LLM-backed steering decisions.
  #
  # Keys hydrated:
  #   - :active_task — from TaskManager.get_active/2 (if not in ctx)
  #   - :plan — from KiroCockpit.Plans.get_plan/1 when plan_id available (if not in ctx)
  #   - :task_history — list of recent tasks for the session (if not in ctx)
  #   - :completed_tasks — list of completed tasks for scope summary (if not in ctx)
  #   - :permission_policy — built from task scope and permission level (if not in ctx)
  #
  # All DB lookups are defensive — failures are rescued and the boundary continues.
  defp maybe_hydrate_steering_context(ctx, opts, event, tm) do
    ctx
    |> maybe_hydrate_active_task(opts, event, tm)
    |> maybe_hydrate_plan(opts, event)
    |> maybe_hydrate_task_history(opts, event, tm)
    |> maybe_hydrate_completed_tasks(opts, event, tm)
    |> maybe_hydrate_permission_policy(opts, event)
  end

  # Hydrate :active_task from TaskManager if not already in ctx
  defp maybe_hydrate_active_task(ctx, _opts, event, tm) do
    if Map.has_key?(ctx, :active_task) do
      ctx
    else
      case safe_get_active(tm, event.session_id, event.agent_id) do
        nil -> ctx
        task -> Map.put(ctx, :active_task, task)
      end
    end
  end

  # Hydrate :plan from Plans.get_plan/1 if plan_id is available and not in ctx
  defp maybe_hydrate_plan(ctx, _opts, _event) when is_map_key(ctx, :plan), do: ctx
  defp maybe_hydrate_plan(ctx, _opts, %{plan_id: nil}), do: ctx

  defp maybe_hydrate_plan(ctx, _opts, %{plan_id: plan_id}) do
    case safe_get_plan(plan_id) do
      nil -> ctx
      plan -> Map.put(ctx, :plan, plan)
    end
  end

  # Hydrate :task_history — recent tasks for the session (for steering context)
  defp maybe_hydrate_task_history(ctx, _opts, event, tm) do
    if Map.has_key?(ctx, :task_history) do
      ctx
    else
      case safe_list_tasks(tm, event.session_id, limit: 10) do
        nil -> ctx
        tasks -> Map.put(ctx, :task_history, tasks)
      end
    end
  end

  # Hydrate :completed_tasks — completed tasks for scope/permission summaries
  defp maybe_hydrate_completed_tasks(ctx, _opts, event, tm) do
    if Map.has_key?(ctx, :completed_tasks) do
      ctx
    else
      case safe_list_tasks(tm, event.session_id, status: "completed", limit: 5) do
        nil -> ctx
        tasks -> Map.put(ctx, :completed_tasks, tasks)
      end
    end
  end

  # Hydrate :permission_policy — permission/scope summary from active task and level
  defp maybe_hydrate_permission_policy(ctx, opts, _event) do
    if Map.has_key?(ctx, :permission_policy) do
      ctx
    else
      permission_level = Keyword.get(opts, :permission_level)
      active_task = Map.get(ctx, :active_task)

      policy = build_permission_policy(permission_level, active_task)
      Map.put(ctx, :permission_policy, policy)
    end
  end

  # Build permission policy map from permission level and active task scope
  defp build_permission_policy(permission_level, active_task) when is_map(active_task) do
    %{
      level: permission_level,
      files_scope: Map.get(active_task, :files_scope, []),
      category: Map.get(active_task, :category, "unknown"),
      allows_write: permission_level in [:write, :destructive, :subagent],
      allows_destructive: permission_level in [:destructive, :subagent]
    }
  end

  defp build_permission_policy(permission_level, _active_task) do
    %{
      level: permission_level,
      files_scope: [],
      category: "unknown",
      allows_write: permission_level in [:write, :destructive, :subagent],
      allows_destructive: permission_level in [:destructive, :subagent]
    }
  end

  # Safe wrapper for Plans.get_plan/1 — returns nil on any failure
  defp safe_get_plan(plan_id) do
    KiroCockpit.Plans.get_plan(plan_id)
  rescue
    _ -> nil
  end

  # Safe wrapper for TaskManager.list/2 — returns nil on any failure
  defp safe_list_tasks(tm, session_id, list_opts) do
    tm.list(session_id, list_opts)
  rescue
    _ -> nil
  end

  @doc """
  Returns the default pre-hooks list used by the boundary.
  """
  @spec default_pre_hooks() :: [module()]
  def default_pre_hooks, do: @default_pre_hooks

  @doc """
  Returns the default post-hooks list used by the boundary.
  """
  @spec default_post_hooks() :: [module()]
  def default_post_hooks, do: @default_post_hooks

  @doc """
  Run post-hooks only for lifecycle actions (no pre-hook gating).

  Lifecycle actions (task create/activate/complete/block, plan_approved)
  are internal state transitions that don't need pre-hook blocking but
  should fire post-hooks for Bronze trace capture and guidance injection.

  Unlike `run/3`, this does not gate on pre-hooks — the transition has
  already succeeded. Post-hooks fire for Bronze capture and guidance.

  Always returns `:ok`. Persistence errors are rescued and never crash
  the caller.
  """
  @spec run_lifecycle_post_hooks(atom(), keyword()) :: :ok
  def run_lifecycle_post_hooks(action, opts) when is_atom(action) do
    if boundary_enabled?(opts) do
      do_run_lifecycle_post_hooks(action, opts)
    end

    :ok
  rescue
    _ -> :ok
  end

  defp do_run_lifecycle_post_hooks(action, opts) do
    hm = Keyword.get(opts, :hook_manager_module, HookManager)
    tm = Keyword.get(opts, :task_manager_module, TaskManager)
    staleness_mod = Keyword.get(opts, :staleness_module, Staleness)

    event = build_event(action, opts, tm)
    ctx = build_ctx(opts, event, staleness_mod, tm)
    post_hooks = Keyword.get(opts, :post_hooks, @default_post_hooks)

    record_lifecycle_before(event, ctx)

    result = hm.run(event, post_hooks, ctx, :post)

    record_lifecycle_after(event, result, ctx)
  end

  defp record_lifecycle_before(event, ctx) do
    if DataPipeline.action_capture_enabled?() do
      DataPipeline.record_action_before(event, Map.put(ctx, :lifecycle, true))
    end
  end

  defp record_lifecycle_after(event, result, ctx) do
    if DataPipeline.action_capture_enabled?() do
      normalized_result = normalize_lifecycle_result(result)
      DataPipeline.record_action_after(event, normalized_result, Map.put(ctx, :lifecycle, true))
    end
  end

  defp normalize_lifecycle_result({:ok, _evt, _msgs}), do: {:ok, :lifecycle_completed}

  defp normalize_lifecycle_result({:blocked, _evt, _reason, _msgs}),
    do: {:blocked, "post-hook blocked", []}

  defp normalize_lifecycle_result(_), do: {:ok, :lifecycle_completed}
end
