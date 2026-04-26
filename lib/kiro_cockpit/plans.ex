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
  Runs an approved plan after verifying it is not stale.

  This is the fail-closed entry point for plan execution. It checks:

    1. The plan exists and is in `"approved"` status
    2. The project snapshot has not changed (via `Staleness.check/3`)

  If both checks pass, transitions the plan to `"running"`.

  ## Options

    * `:project_dir` — trusted project directory for staleness check
      (required; returns `{:error, :stale_plan_unknown}` if absent)
    * `:context_builder_module` — module implementing `build/1` for
      staleness checks (default `NanoPlanner.ContextBuilder`)
    * `:payload` — map merged into the status-change event payload
      (default `%{"source" => "run"}`)

  Returns `{:ok, Plan.t()}` on success, or one of:

    * `{:error, :not_found}` — plan does not exist
    * `{:error, :invalid_transition}` — plan is not in `"approved"` status
    * `{:error, :stale_plan}` — project has changed since plan was created
    * `{:error, :stale_plan_unknown}` — cannot determine staleness
  """
  @spec run_plan(plan_id(), keyword()) ::
          {:ok, Plan.t()} | {:error, term()}
  def run_plan(plan_id, opts \\ []) do
    alias KiroCockpit.NanoPlanner.Staleness
    alias KiroCockpit.Swarm.ActionBoundary

    with {:ok, plan} <- fetch_plan(plan_id),
         :ok <- require_status(plan, "approved"),
         {:ok, project_dir} <- resolve_project_dir(opts),
         :ok <- Staleness.check(plan, project_dir, opts) do
      # Run plan transition through the action boundary (kiro-00j).
      # Hooks enforce stale plan checks, active task/category/scope
      # before the approved→running transition. nano_plan_run is
      # exempt from active task requirement (lifecycle action).
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
    plan_mode = Keyword.get(opts, :plan_mode)

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
