defmodule KiroCockpit.Plans do
  @moduledoc """
  Context for NanoPlanner plans, steps, and events.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias KiroCockpit.Plans.{Plan, PlanEvent, PlanStep}
  alias KiroCockpit.Repo

  @type plan_id :: Ecto.UUID.t()
  @type session_id :: String.t()

  @multi_new &Multi.new/0
  @spec new_multi() :: Multi.t()
  defp new_multi, do: @multi_new.()

  @doc """
  Creates a new draft plan with steps and a creation event.
  """
  @spec create_plan(session_id, String.t(), atom() | String.t(), list(map()), map() | keyword()) ::
          {:ok, Plan.t()} | {:error, Ecto.Changeset.t() | term()}
  def create_plan(session_id, user_request, mode, steps, opts \\ []) do
    opts = if is_map(opts), do: Map.to_list(opts), else: opts
    mode_str = to_string(mode)

    plan_attrs = %{
      session_id: session_id,
      mode: mode_str,
      status: "draft",
      user_request: user_request,
      plan_markdown: Keyword.get(opts, :plan_markdown, ""),
      execution_prompt: Keyword.get(opts, :execution_prompt, ""),
      raw_model_output: Keyword.get(opts, :raw_model_output, %{}),
      project_snapshot_hash: Keyword.get(opts, :project_snapshot_hash, "")
    }

    new_multi()
    |> Multi.insert(:plan, Plan.changeset(%Plan{}, plan_attrs))
    |> Multi.run(:steps, fn repo, %{plan: plan} ->
      # Insert each step, associating with the plan
      now = DateTime.utc_now()

      steps_with_plan_id =
        Enum.map(steps, fn step_attrs ->
          step_attrs
          |> Map.put(:plan_id, plan.id)
          |> Map.put(:inserted_at, now)
          |> Map.put(:updated_at, now)
        end)

      {_, inserted} =
        repo.insert_all(PlanStep, steps_with_plan_id, returning: true)

      {:ok, inserted}
    end)
    |> Multi.run(:event, fn repo, %{plan: plan} ->
      event_attrs = %{
        plan_id: plan.id,
        event_type: "created",
        payload: %{"user_request" => user_request},
        created_at: DateTime.utc_now()
      }

      repo.insert(PlanEvent.changeset(%PlanEvent{}, event_attrs))
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{plan: plan}} ->
        # Preload steps and events for immediate use
        {:ok, Repo.preload(plan, [:plan_steps, :plan_events])}

      {:error, _failed_step, reason, _changes} ->
        {:error, reason}
    end
  end

  @doc """
  Retrieves a plan by ID, preloaded with steps and events.
  """
  @spec get_plan(plan_id) :: Plan.t() | nil
  def get_plan(plan_id) do
    case Repo.get(Plan, plan_id) do
      nil -> nil
      plan -> Repo.preload(plan, [:plan_steps, :plan_events])
    end
  end

  @doc """
  Lists plans for a given session, optionally filtered by status.
  Preloads plan_steps and plan_events.
  """
  @spec list_plans(session_id, keyword()) :: [Plan.t()]
  def list_plans(session_id, opts \\ []) do
    query =
      from p in Plan,
        where: p.session_id == ^session_id,
        order_by: [desc: p.inserted_at],
        preload: [:plan_steps, :plan_events]

    query =
      if status = Keyword.get(opts, :status) do
        where(query, [p], p.status == ^status)
      else
        query
      end

    Repo.all(query)
  end

  @doc """
  Approves a draft plan, adding an approval event.

  This is the simple approval without task creation. For atomic
  approval with task derivation and activation, use `approve_plan_with_tasks/4`.
  """
  @spec approve_plan(plan_id, keyword()) ::
          {:ok, Plan.t()} | {:error, Ecto.Changeset.t() | term()}
  def approve_plan(plan_id, opts \\ []) do
    with {:ok, plan} <- fetch_plan(plan_id),
         :ok <- require_status(plan, "draft") do
      result =
        update_plan_with_event(
          plan,
          %{status: "approved", approved_at: DateTime.utc_now()},
          "approved",
          %{}
        )

      case result do
        {:ok, approved_plan} ->
          fire_plan_approved_hook(approved_plan, opts)
          result

        _ ->
          result
      end
    end
  end

  @doc """
  Atomically approves a draft plan, creates derived swarm tasks, and activates
  the first pending task.

  All operations (plan approval, event creation, task creation, first task
  activation) are wrapped in a single database transaction. If any step fails,
  the entire transaction rolls back, leaving the plan in its original "draft"
  status with no tasks created.

  Returns `{:ok, %{plan: Plan.t(), tasks: [Task.t()], active_task: Task.t()}}`
  on success, or `{:error, reason}` on failure.

  ## Options

    * `:agent_id` — owner_id for derived swarm tasks (default: "kiro-executor")
    * `:task_manager_module` — module implementing task operations
      (default: `KiroCockpit.Swarm.Tasks.TaskManager`)
    * `:derive_tasks_fn` — optional function to derive task attrs from plan
      (for testing injection)
  """
  @spec approve_plan_with_tasks(plan_id, String.t(), module(), keyword()) ::
          {:ok, %{plan: Plan.t(), tasks: [struct()], active_task: struct() | nil}}
          | {:error, term()}
  def approve_plan_with_tasks(plan_id, agent_id, _task_manager_mod, opts \\ []) do
    # Fetch plan with preloaded steps (required for task derivation)
    with plan when not is_nil(plan) <- Repo.get(Plan, plan_id),
         plan = Repo.preload(plan, :plan_steps),
         :ok <- require_status(plan, "draft") do
      do_approve_plan_with_tasks(plan, agent_id, opts)
    end
  end

  # Execute the atomic approval transaction.
  # Extracted to reduce nesting depth in approve_plan_with_tasks/4.
  defp do_approve_plan_with_tasks(plan, agent_id, opts) do
    alias KiroCockpit.Swarm.Tasks.Task

    # Derive task attributes (can be injected for testing)
    derive_fn = Keyword.get(opts, :derive_tasks_fn, &derive_tasks_from_plan/2)
    attrs_list = derive_fn.(plan, agent_id)

    multi_result =
      new_multi()
      |> build_approval_multi(plan, attrs_list, agent_id)
      |> Repo.transaction()
      |> handle_approval_transaction_result()

    case multi_result do
      {:ok, result} ->
        fire_plan_approved_hook(result.plan, opts)
        {:ok, result}

      error ->
        error
    end
  end

  # Build the Multi pipeline for atomic plan approval.
  defp build_approval_multi(multi, plan, attrs_list, agent_id) do
    alias KiroCockpit.Swarm.Tasks.Task

    multi
    |> Multi.update(
      :plan,
      Plan.changeset(plan, %{
        status: "approved",
        approved_at: DateTime.utc_now()
      })
    )
    |> Multi.insert(:event, fn %{plan: updated_plan} ->
      PlanEvent.changeset(%PlanEvent{}, %{
        plan_id: updated_plan.id,
        event_type: "approved",
        payload: %{},
        created_at: DateTime.utc_now()
      })
    end)
    |> Multi.run(:tasks, fn repo, %{plan: updated_plan} ->
      insert_derived_tasks(repo, Task, updated_plan.id, attrs_list)
    end)
    |> Multi.run(:active_task, fn repo, %{tasks: tasks} ->
      activate_first_task_or_skip(repo, tasks, agent_id)
    end)
  end

  # Insert derived tasks or return empty list if none to create.
  defp insert_derived_tasks(_repo, _task_schema, _plan_id, []), do: {:ok, []}

  defp insert_derived_tasks(repo, task_schema, plan_id, attrs_list) do
    now = DateTime.utc_now()

    tasks_with_timestamps =
      Enum.map(attrs_list, fn attrs ->
        attrs
        |> Map.put(:id, Ecto.UUID.generate())
        |> Map.put(:plan_id, plan_id)
        |> Map.put(:inserted_at, now)
        |> Map.put(:updated_at, now)
      end)

    {_, inserted} = repo.insert_all(task_schema, tasks_with_timestamps, returning: true)
    {:ok, inserted}
  end

  # Activate first task if tasks exist, otherwise skip gracefully.
  defp activate_first_task_or_skip(_repo, [], _agent_id), do: {:ok, nil}

  defp activate_first_task_or_skip(repo, tasks, agent_id) do
    activate_first_task_in_tx(repo, tasks, nil, agent_id)
  end

  # Handle transaction result, preloading associations on success.
  defp handle_approval_transaction_result(
         {:ok, %{plan: plan, tasks: tasks, active_task: active_task}}
       ) do
    plan_with_assocs = Repo.preload(plan, [:plan_steps, :plan_events])
    {:ok, %{plan: plan_with_assocs, tasks: tasks, active_task: active_task}}
  end

  defp handle_approval_transaction_result({:error, _failed_step, reason, _changes}) do
    {:error, reason}
  end

  # ── Task Activation Helpers ─────────────────────────────────────────────

  # Find the first pending task from a list of task attribute maps.
  # Returns the first task with status "pending" when sorted by sequence,
  # or nil if no pending tasks exist.
  defp find_first_pending_task(tasks) do
    tasks
    |> Enum.sort_by(fn t -> t.sequence || 0 end)
    |> Enum.find(fn t -> (t.status || "pending") == "pending" end)
  end

  # Attempt to atomically activate a pending task within a transaction.
  # Uses update_all with a WHERE clause that checks status == "pending"
  # to ensure we only activate if it hasn't been activated by another process.
  #
  # Returns {:ok, activated_task} on success, or {:ok, nil} if the task
  # was already activated by another process (race condition handled gracefully).
  defp attempt_activate_task(repo, task_id) do
    alias KiroCockpit.Swarm.Tasks.Task

    now = DateTime.utc_now()

    {count, returned} =
      repo.update_all(
        from(t in Task, where: t.id == ^task_id and t.status == "pending"),
        [set: [status: "in_progress", updated_at: now]],
        returning: true
      )

    case {count, returned} do
      {1, [activated | _]} ->
        {:ok, activated}

      {1, nil} ->
        # Some adapters don't return rows - reload the task
        case repo.get(Task, task_id) do
          nil -> {:ok, nil}
          activated -> {:ok, activated}
        end

      {0, _} ->
        # Another process already activated or task no longer pending
        {:ok, nil}
    end
  end

  # Atomically activate the first pending task within a transaction.
  # Uses a conditional update to enforce the one-active-task-per-lane invariant.
  # Relies on DB unique constraint for race condition safety, removing pre-check.
  defp activate_first_task_in_tx(repo, tasks, _plan, _agent_id) do
    case find_first_pending_task(tasks) do
      nil ->
        {:ok, nil}

      task ->
        attempt_activate_task(repo, task.id)
    end
  end

  @doc """
  Rejects a plan, adding a rejection event.
  """
  @spec reject_plan(plan_id, String.t() | nil) ::
          {:ok, Plan.t()} | {:error, Ecto.Changeset.t() | term()}
  def reject_plan(plan_id, reason \\ nil) do
    with {:ok, plan} <- fetch_plan(plan_id),
         :ok <- rejectable?(plan.status) do
      update_plan_with_event(plan, %{status: "rejected"}, "rejected", rejection_payload(reason))
    end
  end

  @doc """
  Revises a plan: creates a new plan version, supersedes the old one.
  """
  @spec revise_plan(plan_id, String.t(), keyword()) ::
          {:ok, Plan.t()} | {:error, Ecto.Changeset.t() | term()}
  def revise_plan(plan_id, revision_request, opts \\ []) do
    with {:ok, old_plan} <- fetch_plan(plan_id) do
      old_plan = Repo.preload(old_plan, :plan_steps)

      # Create a new plan with the revision request as user_request (or keep original?)
      # For simplicity, we'll treat revision_request as the new user request.
      # The old plan's steps may be used as a starting point; but we'll just create empty steps.
      # The caller (NanoPlanner) will generate new steps.
      # We'll also mark old plan as superseded.
      new_multi()
      |> Multi.update(:old_plan, Plan.changeset(old_plan, %{status: "superseded"}))
      |> Multi.run(:new_plan, fn repo, %{old_plan: old_plan} ->
        new_plan_attrs = %{
          session_id: old_plan.session_id,
          mode: old_plan.mode,
          status: "draft",
          user_request: revision_request,
          plan_markdown: Keyword.get(opts, :plan_markdown, old_plan.plan_markdown),
          execution_prompt: Keyword.get(opts, :execution_prompt, old_plan.execution_prompt),
          raw_model_output: Keyword.get(opts, :raw_model_output, old_plan.raw_model_output),
          project_snapshot_hash:
            Keyword.get(opts, :project_snapshot_hash, old_plan.project_snapshot_hash)
        }

        repo.insert(Plan.changeset(%Plan{}, new_plan_attrs))
      end)
      |> Multi.run(:event, fn repo, %{new_plan: new_plan} ->
        event_attrs = %{
          plan_id: new_plan.id,
          event_type: "revised",
          payload: %{"previous_plan_id" => plan_id},
          created_at: DateTime.utc_now()
        }

        repo.insert(PlanEvent.changeset(%PlanEvent{}, event_attrs))
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{new_plan: new_plan}} ->
          {:ok, Repo.preload(new_plan, [:plan_steps, :plan_events])}

        {:error, _failed_step, reason, _changes} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Runs an approved plan, routing through ActionBoundary for stale/plan-mode
  enforcement and Bronze trace capture.

  Staleness checking is performed inside the boundary via
  `TaskEnforcementHook`, which inspects the trusted context computed by
  `Staleness.trusted_context/3`. If the boundary blocks a stale plan, a
  Bronze `hook_trace` with outcome `blocked` is persisted.

  ## Options

    * `:project_dir` — trusted project directory for staleness check
      (required; returns `{:error, :stale_plan_unknown}` if absent)
    * `:context_builder_module` — module implementing `build/1` for
      staleness checks (default `NanoPlanner.ContextBuilder`)
    * `:payload` — map merged into the status-change event payload
      (default `%{"source" => "run"}`)
    * `:swarm_hooks` — explicitly enable/disable hook boundary
      (default: app config, `false` in test)
    * `:pre_hooks` — list of pre-action hook modules
    * `:post_hooks` — list of post-action hook modules
    * `:hook_manager_module` — module for hook execution
    * `:task_manager_module` — module for active task lookup
    * `:staleness_module` — module for trusted_context (default Staleness)
    * `:stale_plan_override?` / `:stale_plan_confirmed?` —
      trusted server-side override to allow stale plan execution

  Returns `{:ok, Plan.t()}` on success, or one of:

    * `{:error, :not_found}` — plan does not exist
    * `{:error, :invalid_transition}` — plan is not in `"approved"` status
    * `{:error, :stale_plan_unknown}` — cannot determine project directory
    * `{:error, {:swarm_blocked, reason}}` — pre-hooks blocked execution
      (stale plan, plan-mode gate, etc.)
  """
  @spec run_plan(plan_id(), keyword()) ::
          {:ok, Plan.t()} | {:error, term()}
  def run_plan(plan_id, opts \\ []) do
    alias KiroCockpit.Swarm.ActionBoundary

    with {:ok, plan} <- fetch_plan(plan_id),
         :ok <- require_status(plan, "approved"),
         {:ok, project_dir} <- resolve_project_dir(opts) do
      # Run plan transition through the action boundary (kiro-ux7).
      # Staleness checking happens inside the boundary via
      # TaskEnforcementHook, which inspects trusted ctx computed from
      # Staleness.trusted_context/3. If blocked, Bronze trace captures
      # the blocked attempt with outcome "blocked".
      if plan_run_boundary_enabled?(opts) do
        boundary_opts = plan_run_boundary_opts(plan, project_dir, opts)

        case ActionBoundary.run(:nano_plan_run, boundary_opts, fn ->
               do_run_plan_transition(plan, opts)
             end) do
          {:ok, result} -> result
          {:error, {:swarm_blocked, reason, _messages}} -> {:error, {:swarm_blocked, reason}}
        end
      else
        do_run_plan_transition(plan, opts)
      end
    end
  end

  # Perform the actual approved→running transition.
  defp do_run_plan_transition(plan, opts) do
    payload = Keyword.get(opts, :payload, %{"source" => "run"})
    update_plan_with_event(plan, %{status: "running"}, "running", payload)
  end

  defp plan_run_boundary_enabled?(opts) do
    case Keyword.get(opts, :swarm_hooks) do
      nil -> Application.get_env(:kiro_cockpit, :swarm_action_hooks_enabled, true)
      explicit -> explicit
    end
  end

  defp plan_run_boundary_opts(plan, project_dir, opts) do
    session_id = Keyword.get(opts, :session_id, plan.session_id)
    # Default agent_id to "nano-planner" so Bronze persistence can satisfy
    # the required agent_id field (kiro-00j issue 6).
    agent_id = Keyword.get(opts, :agent_id, "nano-planner")
    # Default plan_mode from the fetched plan (approved => approved) unless caller overrides
    plan_mode = Keyword.get(opts, :plan_mode, KiroCockpit.Swarm.PlanMode.from_plan(plan))

    [
      session_id: session_id,
      agent_id: agent_id,
      plan_id: plan.id,
      permission_level: :write,
      project_dir: project_dir,
      plan_mode: plan_mode,
      # Forward the enabled flag from the caller's swarm_hooks opt
      enabled: plan_run_boundary_enabled?(opts)
    ]
    |> maybe_put_opt(opts, :stale_plan_override?)
    |> maybe_put_opt(opts, :stale_plan_confirmed?)
    |> maybe_put_opt(opts, :context_builder_module)
    |> maybe_put_opt(opts, :staleness_module)
    |> maybe_put_opt(opts, :pre_hooks)
    |> maybe_put_opt(opts, :post_hooks)
    |> maybe_put_opt(opts, :hook_manager_module)
    |> maybe_put_opt(opts, :task_manager_module)
  end

  defp maybe_put_opt(kw, opts, key) do
    case Keyword.get(opts, key) do
      nil -> kw
      value -> Keyword.put(kw, key, value)
    end
  end

  defp resolve_project_dir(opts) do
    case Keyword.get(opts, :project_dir) do
      dir when is_binary(dir) and dir != "" -> {:ok, dir}
      _ -> {:error, :stale_plan_unknown}
    end
  end

  @doc """
  Updates a plan's status and adds an event.
  Used for running, completed, failed, superseded transitions.
  """
  @spec update_status(plan_id, String.t(), map()) ::
          {:ok, Plan.t()} | {:error, Ecto.Changeset.t() | term()}
  def update_status(plan_id, status, payload \\ %{}) do
    with {:ok, plan} <- fetch_plan(plan_id),
         :ok <- valid_status_transition?(plan.status, status) do
      update_plan_with_event(plan, status_attrs(status), status, payload)
    end
  end

  @doc """
  Returns the stale-plan hash for a given plan.
  """
  @spec stale_plan_hash(plan_id) :: String.t() | nil
  def stale_plan_hash(plan_id) do
    case Repo.get(Plan, plan_id, select: [:project_snapshot_hash]) do
      nil -> nil
      plan -> plan.project_snapshot_hash
    end
  end

  defp fetch_plan(plan_id) do
    case Repo.get(Plan, plan_id) do
      nil -> {:error, :not_found}
      plan -> {:ok, plan}
    end
  end

  defp require_status(%Plan{status: status}, status), do: :ok
  defp require_status(%Plan{}, _status), do: {:error, :invalid_transition}

  defp rejectable?(status) when status in ["rejected", "superseded", "failed", "completed"] do
    {:error, :invalid_transition}
  end

  defp rejectable?(_status), do: :ok

  defp valid_status_transition?("approved", "running"), do: :ok
  defp valid_status_transition?("running", "completed"), do: :ok
  defp valid_status_transition?("running", "failed"), do: :ok
  defp valid_status_transition?(_current_status, "superseded"), do: :ok
  defp valid_status_transition?(_current_status, _new_status), do: {:error, :invalid_transition}

  defp status_attrs("completed") do
    %{status: "completed", completed_at: DateTime.utc_now()}
  end

  defp status_attrs(status), do: %{status: status}

  defp rejection_payload(nil), do: %{}
  defp rejection_payload(reason), do: %{"reason" => reason}

  # Fire :plan_approved post-hook for Bronze trace and guidance injection.
  # Uses ActionBoundary.run_lifecycle_post_hooks which checks app config
  # (swarm_action_hooks_enabled) before running. Never crashes the caller.
  # Derives task attribute maps from an approved plan's plan_steps.
  #
  # Field mapping per §36.8:
  #   plan_id           → will be set during insertion
  #   session_id         → plan.session_id
  #   owner_id           → execution agent id
  #   sequence           → phase_number * 100 + step_number (stable)
  #   content            → "Phase N, Step M: title" + details
  #   status             → "pending"
  #   category           → permission-based heuristic:
  #       write/shell_write/terminal/destructive/subagent/memory_write → "acting"
  #       read/shell_read                               → "researching"
  #       validation-only (no mutation permissions)      → "verifying"
  #   permission_scope   → [step.permission_level, "read"]
  #   files_scope        → Map.keys(step.files) if map
  #   acceptance_criteria → [step.validation] if present
  @spec derive_tasks_from_plan(Plan.t(), String.t()) :: [map()]
  defp derive_tasks_from_plan(plan, agent_id) do
    steps = plan.plan_steps || []

    steps
    |> Enum.sort_by(fn step -> {step.phase_number, step.step_number} end)
    |> Enum.map(fn step ->
      perm = step.permission_level || "read"
      category = category_for_permission(perm, step)
      files = extract_files_scope(step)
      validation = if step.validation && step.validation != "", do: [step.validation], else: []

      content =
        case step.details do
          nil ->
            "Phase #{step.phase_number}, Step #{step.step_number}: #{step.title}"

          "" ->
            "Phase #{step.phase_number}, Step #{step.step_number}: #{step.title}"

          details ->
            "Phase #{step.phase_number}, Step #{step.step_number}: #{step.title}\n#{details}"
        end

      # Include read as baseline permission alongside step's explicit level
      permission_scope =
        [perm, "read"]
        |> Enum.uniq()
        |> Enum.filter(&valid_permission?/1)

      %{
        # Will be set during insertion
        plan_id: nil,
        session_id: plan.session_id,
        owner_id: agent_id,
        sequence: step.phase_number * 100 + step.step_number,
        content: content,
        status: "pending",
        category: category,
        priority: "medium",
        permission_scope: permission_scope,
        files_scope: files,
        acceptance_criteria: validation
      }
    end)
  end

  # Category heuristic: mutation permissions → "acting", read-only → "researching",
  # validation-focused → "verifying".
  @acting_permissions ~w(write shell_write terminal destructive subagent memory_write)
  @researching_permissions ~w(read shell_read)

  defp category_for_permission(perm, step) do
    cond do
      perm in @acting_permissions ->
        "acting"

      perm in @researching_permissions and has_validation?(step) ->
        "verifying"

      perm in @researching_permissions ->
        "researching"

      true ->
        # Unknown permission: default to acting (safest for enforcement)
        "acting"
    end
  end

  defp has_validation?(step), do: step.validation != nil and step.validation != ""

  defp extract_files_scope(%{files: files}) when is_map(files) and map_size(files) > 0 do
    Map.keys(files)
  end

  defp extract_files_scope(%{files: files}) when is_list(files) and files != [] do
    Enum.map(files, &to_string/1)
  end

  defp extract_files_scope(_), do: []

  defp valid_permission?(perm) when is_binary(perm) do
    case KiroCockpit.Permissions.parse_permission(perm) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  defp valid_permission?(_), do: false

  defp fire_plan_approved_hook(plan, opts) do
    alias KiroCockpit.Swarm.ActionBoundary

    agent_id = Keyword.get(opts, :agent_id, "nano-planner")

    ActionBoundary.run_lifecycle_post_hooks(:plan_approved,
      session_id: plan.session_id,
      agent_id: agent_id,
      plan_id: plan.id
    )
  end

  defp update_plan_with_event(plan, attrs, event_type, payload) do
    new_multi()
    |> Multi.update(:plan, Plan.changeset(plan, attrs))
    |> Multi.run(:event, fn repo, %{plan: plan} ->
      event_attrs = %{
        plan_id: plan.id,
        event_type: event_type,
        payload: payload,
        created_at: DateTime.utc_now()
      }

      repo.insert(PlanEvent.changeset(%PlanEvent{}, event_attrs))
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{plan: plan}} -> {:ok, Repo.preload(plan, [:plan_steps, :plan_events])}
      {:error, _failed_step, reason, _changes} -> {:error, reason}
    end
  end
end
