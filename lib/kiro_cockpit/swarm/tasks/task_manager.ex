defmodule KiroCockpit.Swarm.Tasks.TaskManager do
  @moduledoc """
  Context for swarm task lifecycle management.

  Per §27.4 and §35 Phase 10, this module provides:

  - CRUD: create, list, get, delete
  - Activation: `activate/2` — transitions a task to `in_progress`,
    enforcing exactly-one-active-task per execution lane (session_id + owner_id)
  - Completion: `complete/2` — transitions a task to `completed`
  - Blocking: `block/2` — transitions a task to `blocked`
  - Active lookup: `get_active/2` — finds the current in_progress task for a lane

  ## Dual-write discipline (§6.3)

  All state transitions that could emit events use `Ecto.Multi` to
  ensure canonical state and events are written atomically. For this
  Phase 10 foundation, we persist task state changes; event emission
  is a thin `Multi.insert` of an event row when the full event schema
  lands in a later phase.

  ## Execution lane

  An execution lane is identified by `session_id + owner_id`. At most
  one task may be `in_progress` per lane at any time. `activate/2`
  performs a friendly pre-check and the database partial unique index
  enforces the invariant under concurrent activation races.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias KiroCockpit.Repo
  alias KiroCockpit.Swarm.Tasks.Task

  # Dialyzer false positives: Ecto.Multi opacity and Repo.insert success-typing
  # are well-known Ecto/Dialyzer interaction issues.
  @dialyzer {:nowarn_function, create: 1}
  @dialyzer {:nowarn_function, create_all: 1}
  @dialyzer {:nowarn_function, transition_with_multi: 2}

  @type task_id :: Ecto.UUID.t()
  @type session_id :: String.t()
  @type owner_id :: String.t()

  # -------------------------------------------------------------------
  # Create
  # -------------------------------------------------------------------

  @doc """
  Creates a new task with the given attributes.

  Required attributes: `session_id`, `content`, `owner_id`.
  Defaults: `status` → "pending", `priority` → "medium",
  `category` → "researching", `sequence` → 0.

  Returns `{:ok, Task.t()}` or `{:error, Ecto.Changeset.t()}`.
  """
  @spec create(map()) :: {:ok, Task.t()} | {:error, Ecto.Changeset.t()} | {:error, term()}
  def create(attrs) do
    changeset = Task.changeset(%Task{}, attrs)

    Multi.new()
    |> Multi.insert(:task, changeset)
    |> Repo.transaction()
    |> case do
      {:ok, %{task: task}} -> {:ok, task}
      {:error, :task, changeset, _changes} -> {:error, changeset}
    end
  end

  @doc """
  Creates multiple tasks in a single transaction.

  Useful when a plan is approved and all its tasks need to be
  persisted atomically (§35 Phase 10 acceptance: "Every approved
  plan creates pending tasks").

  Expects a list of attribute maps. Returns `{:ok, [Task.t()]}` on success
  or `{:error, failed_index, changeset, _changes}` on failure.
  """
  @spec create_all([map()]) ::
          {:ok, [Task.t()]} | {:error, term()}
  def create_all(attrs_list) when is_list(attrs_list) do
    attrs_list
    |> Enum.with_index()
    |> Enum.reduce(Multi.new(), fn {attrs, idx}, multi ->
      changeset = Task.changeset(%Task{}, attrs)
      Multi.insert(multi, {:task, idx}, changeset)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, results} ->
        tasks =
          results
          |> Enum.filter(fn {key, _} -> match?({:task, _}, key) end)
          |> Enum.sort_by(fn {{:task, idx}, _} -> idx end)
          |> Enum.map(fn {_, task} -> task end)

        {:ok, tasks}

      {:error, _failed_step, _changeset, _changes} ->
        {:error, :transaction_failed}
    end
  end

  # -------------------------------------------------------------------
  # Read
  # -------------------------------------------------------------------

  @doc """
  Retrieves a task by ID.

  Returns `{:ok, Task.t()}` or `{:error, :not_found}`.
  """
  @spec get(task_id) :: {:ok, Task.t()} | {:error, :not_found}
  def get(task_id) do
    case Repo.get(Task, task_id) do
      nil -> {:error, :not_found}
      task -> {:ok, task}
    end
  end

  @doc """
  Lists tasks for a given session, optionally filtered by status or plan_id.

  Tasks are ordered by `sequence` then `inserted_at`.
  """
  @spec list(session_id, keyword()) :: [Task.t()]
  def list(session_id, opts \\ []) do
    query =
      from t in Task,
        where: t.session_id == ^session_id,
        order_by: [asc: t.sequence, asc: t.inserted_at]

    query =
      if status = Keyword.get(opts, :status) do
        where(query, [t], t.status == ^status)
      else
        query
      end

    query =
      if plan_id = Keyword.get(opts, :plan_id) do
        where(query, [t], t.plan_id == ^plan_id)
      else
        query
      end

    Repo.all(query)
  end

  @doc """
  Finds the currently active (`in_progress`) task for an execution lane.

  Per §27.6 enforcement flow, there should be at most one active task
  per session_id + owner_id lane. This function returns the first
  matching task or `nil`.
  """
  @spec get_active(session_id, owner_id) :: Task.t() | nil
  def get_active(session_id, owner_id) do
    query =
      from t in Task,
        where:
          t.session_id == ^session_id and
            t.owner_id == ^owner_id and
            t.status == "in_progress",
        limit: 1

    Repo.one(query)
  end

  @doc """
  Lists all tasks for a plan, ordered by sequence.

  Convenience wrapper for `list/2` with `plan_id` filter.
  """
  @spec list_for_plan(session_id, Ecto.UUID.t()) :: [Task.t()]
  def list_for_plan(session_id, plan_id) do
    list(session_id, plan_id: plan_id)
  end

  # -------------------------------------------------------------------
  # Status transitions
  # -------------------------------------------------------------------

  @doc """
  Activates a task: transitions it from `pending` or `blocked` to `in_progress`.

  Enforces exactly-one-active-task per execution lane. If another task
  is already `in_progress` for the same session_id + owner_id, returns
  `{:error, :active_task_exists}`.

  Per §6.3 dual-write discipline, this uses `Ecto.Multi` to atomically:
  1. Verify no other active task exists (conditional)
  2. Transition the task status

  Returns `{:ok, Task.t()}` or `{:error, reason}`.
  """
  @spec activate(task_id) :: {:ok, Task.t()} | {:error, term()}
  def activate(task_id) do
    with {:ok, task} <- fetch_task(Repo, task_id) do
      activate_with_exclusive_check(task)
    end
  end

  @doc """
  Completes a task: transitions it from `in_progress` to `completed`.

  Per §6.3, uses `Ecto.Multi` for the transition.
  Returns `{:ok, Task.t()}` or `{:error, reason}`.
  """
  @spec complete(task_id) :: {:ok, Task.t()} | {:error, term()}
  def complete(task_id) do
    with {:ok, task} <- fetch_task(Repo, task_id) do
      transition_with_multi(task, "completed")
    end
  end

  @doc """
  Blocks a task: transitions it from `in_progress` to `blocked`.

  Per §6.3, uses `Ecto.Multi` for the transition.
  Returns `{:ok, Task.t()}` or `{:error, reason}`.
  """
  @spec block(task_id) :: {:ok, Task.t()} | {:error, term()}
  def block(task_id) do
    with {:ok, task} <- fetch_task(Repo, task_id) do
      transition_with_multi(task, "blocked")
    end
  end

  @doc """
  Soft-deletes a task: transitions it from `pending` or `in_progress` to `deleted`.

  Per §6.3, uses `Ecto.Multi` for the transition.
  Returns `{:ok, Task.t()}` or `{:error, reason}`.
  """
  @spec delete(task_id) :: {:ok, Task.t()} | {:error, term()}
  def delete(task_id) do
    with {:ok, task} <- fetch_task(Repo, task_id) do
      transition_with_multi(task, "deleted")
    end
  end

  # -------------------------------------------------------------------
  # Private helpers
  # -------------------------------------------------------------------

  @spec get_active_query(session_id, owner_id) :: Ecto.Query.t()
  defp get_active_query(session_id, owner_id) do
    from t in Task,
      where:
        t.session_id == ^session_id and
          t.owner_id == ^owner_id and
          t.status == "in_progress",
      limit: 1
  end

  @spec fetch_task(Ecto.Repo.t(), task_id) :: {:ok, Task.t()} | {:error, :not_found}
  defp fetch_task(repo, task_id) do
    case repo.get(Task, task_id) do
      nil -> {:error, :not_found}
      task -> {:ok, task}
    end
  end

  @spec activate_with_exclusive_check(Task.t()) :: {:ok, Task.t()} | {:error, term()}
  defp activate_with_exclusive_check(%Task{id: task_id, session_id: sid, owner_id: oid} = task) do
    case Repo.one(get_active_query(sid, oid)) do
      nil ->
        transition_with_multi(task, "in_progress")

      %{id: ^task_id} ->
        # Same task already active — idempotent success
        {:ok, task}

      _other ->
        {:error, :active_task_exists}
    end
  end

  @spec transition_with_multi(Task.t(), String.t()) :: {:ok, Task.t()} | {:error, term()}
  defp transition_with_multi(task, target_status) do
    changeset = Task.transition_changeset(task, target_status)

    Multi.new()
    |> Multi.update(:task, changeset)
    |> Repo.transaction()
    |> case do
      {:ok, %{task: task}} ->
        {:ok, task}

      {:error, :task, %Ecto.Changeset{} = changeset, _changes} ->
        if active_task_unique_error?(changeset) do
          {:error, :active_task_exists}
        else
          {:error, changeset}
        end
    end
  end

  defp active_task_unique_error?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:owner_id, {_message, opts}} ->
        Keyword.get(opts, :constraint) == :unique and
          Keyword.get(opts, :constraint_name) == "swarm_tasks_one_active_per_lane_index"

      _other ->
        false
    end)
  end
end
