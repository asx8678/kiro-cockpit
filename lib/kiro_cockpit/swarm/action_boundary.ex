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
    3. Run HookManager.run(event, pre_hooks, ctx, :pre)
    4. If blocked → return `{:error, {:swarm_blocked, reason, messages}}`
    5. If allowed → execute the zero-arity fun
    6. Run HookManager.run(event, post_hooks, ctx, :post) for Bronze post trace
    7. Return executor result (post block does not undo execution)

  ## Configuration

  Enabled by default via `Application.get_env(:kiro_cockpit, :swarm_action_hooks_enabled, true)`.
  Test config disables by default; explicit tests enable via opts.

  ## Bronze capture

  HookManager persists hook_trace rows on every run (mandatory §27.11 inv. 7).
  Blocked attempts also persist a full trace — the boundary never silently
  drops a blocked event.
  """

  alias KiroCockpit.NanoPlanner.Staleness
  alias KiroCockpit.Swarm.{Event, HookManager}
  alias KiroCockpit.Swarm.Tasks.TaskManager

  @default_pre_hooks [
    KiroCockpit.Swarm.Hooks.PlanModeFirstActionHook,
    KiroCockpit.Swarm.Hooks.TaskEnforcementHook,
    KiroCockpit.Swarm.Hooks.SteeringPreActionHook
  ]

  @default_post_hooks [KiroCockpit.Swarm.Hooks.TaskGuidanceHook]

  @type boundary_result :: {:ok, term()} | {:error, {:swarm_blocked, String.t(), [String.t()]}}

  @doc """
  Run an action through the hook boundary.

  ## Parameters

    * `action` — atom action name (e.g. `:kiro_session_prompt`)
    * `opts` — keyword list with event/boundary options
    * `fun` — zero-arity executor function

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
  @spec run(atom(), keyword(), (-> term())) :: boundary_result()
  def run(action, opts, fun) when is_atom(action) and is_function(fun, 0) do
    if boundary_enabled?(opts) do
      run_boundary(action, opts, fun)
    else
      {:ok, fun.()}
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

    # Build trusted context: merge caller ctx + stale plan context.
    # Use event.plan_id (which may be hydrated from active task) rather than
    # only opts[:plan_id] so that stale context computation works when the
    # active task carries a plan_id but the caller didn't supply one.
    ctx = build_ctx(opts, event, staleness_mod)

    pre_hooks = Keyword.get(opts, :pre_hooks, @default_pre_hooks)
    post_hooks = Keyword.get(opts, :post_hooks, @default_post_hooks)

    case hm.run(event, pre_hooks, ctx, :pre) do
      {:ok, _modified_event, _messages} ->
        result = fun.()

        # Post-hooks for Bronze trace; never undo execution on post block
        _ = hm.run(event, post_hooks, ctx, :post)

        {:ok, result}

      {:blocked, _event, reason, messages} ->
        {:error, {:swarm_blocked, reason, messages}}
    end
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

  defp build_ctx(opts, event, staleness_mod) do
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

    # Copy approved/policy flags from opts into ctx for TaskEnforcementHook
    ctx =
      [:approved, :policy_allows_write, :root_cause_stated, :fixing_test_fixture, :docs_scoped]
      |> Enum.reduce(ctx, fn key, acc ->
        case Keyword.get(opts, key) do
          nil -> acc
          value -> Map.put(acc, key, value)
        end
      end)

    ctx
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
      hm = Keyword.get(opts, :hook_manager_module, HookManager)
      tm = Keyword.get(opts, :task_manager_module, TaskManager)
      staleness_mod = Keyword.get(opts, :staleness_module, Staleness)

      event = build_event(action, opts, tm)
      ctx = build_ctx(opts, event, staleness_mod)
      post_hooks = Keyword.get(opts, :post_hooks, @default_post_hooks)

      _ = hm.run(event, post_hooks, ctx, :post)
    end

    :ok
  rescue
    _ -> :ok
  end
end
