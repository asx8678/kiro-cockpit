defmodule KiroCockpit.Plans do
  @moduledoc """
  Context for NanoPlanner plans, steps, and events.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias KiroCockpit.Repo
  alias KiroCockpit.Plans.{Plan, PlanStep, PlanEvent}

  @type plan_id :: Ecto.UUID.t()
  @type session_id :: String.t()

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

    Multi.new()
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
  """
  @spec list_plans(session_id, keyword()) :: [Plan.t()]
  def list_plans(session_id, opts \\ []) do
    query =
      from p in Plan,
        where: p.session_id == ^session_id,
        order_by: [desc: p.inserted_at]

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
  @spec approve_plan(plan_id) :: {:ok, Plan.t()} | {:error, Ecto.Changeset.t() | term()}
  def approve_plan(plan_id) do
    plan = Repo.get!(Plan, plan_id)

    if plan.status != "draft" do
      {:error, :invalid_transition}
    else
      Multi.new()
      |> Multi.update(
        :plan,
        Plan.changeset(plan, %{status: "approved", approved_at: DateTime.utc_now()})
      )
      |> Multi.run(:event, fn repo, %{plan: plan} ->
        event_attrs = %{
          plan_id: plan.id,
          event_type: "approved",
          payload: %{},
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

  @doc """
  Rejects a plan, adding a rejection event.
  """
  @spec reject_plan(plan_id, String.t() | nil) ::
          {:ok, Plan.t()} | {:error, Ecto.Changeset.t() | term()}
  def reject_plan(plan_id, reason \\ nil) do
    plan = Repo.get!(Plan, plan_id)

    if plan.status in ["rejected", "superseded", "failed", "completed"] do
      {:error, :invalid_transition}
    else
      Multi.new()
      |> Multi.update(:plan, Plan.changeset(plan, %{status: "rejected"}))
      |> Multi.run(:event, fn repo, %{plan: plan} ->
        event_attrs = %{
          plan_id: plan.id,
          event_type: "rejected",
          payload: if(reason, do: %{"reason" => reason}, else: %{}),
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

  @doc """
  Revises a plan: creates a new plan version, supersedes the old one.
  """
  @spec revise_plan(plan_id, String.t(), keyword()) ::
          {:ok, Plan.t()} | {:error, Ecto.Changeset.t() | term()}
  def revise_plan(plan_id, revision_request, opts \\ []) do
    old_plan = Repo.get!(Plan, plan_id) |> Repo.preload(:plan_steps)

    # Create a new plan with the revision request as user_request (or keep original?)
    # For simplicity, we'll treat revision_request as the new user request.
    # The old plan's steps may be used as a starting point; but we'll just create empty steps.
    # The caller (NanoPlanner) will generate new steps.
    # We'll also mark old plan as superseded.
    Multi.new()
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

  @doc """
  Updates a plan's status and adds an event.
  Used for running, completed, failed, superseded transitions.
  """
  @spec update_status(plan_id, String.t(), map()) ::
          {:ok, Plan.t()} | {:error, Ecto.Changeset.t() | term()}
  def update_status(plan_id, status, payload \\ %{}) do
    plan = Repo.get!(Plan, plan_id)

    # Guard: only allow status transitions used for running, completed, failed, superseded
    unless status in ["running", "completed", "failed", "superseded"] do
      {:error, :invalid_transition}
    else
      Multi.new()
      |> Multi.update(:plan, Plan.changeset(plan, %{status: status}))
      |> Multi.run(:event, fn repo, %{plan: plan} ->
        event_attrs = %{
          plan_id: plan.id,
          event_type: status,
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
end
