defmodule KiroCockpit.Swarm.Tasks.Task do
  @moduledoc """
  A swarm task — the fundamental unit of work in the execution layer.

  Per §27.4, tasks gate tools. An agent must have an active task before
  performing non-exempt actions. Per §27.6, exactly one task may be active
  per execution lane (session_id + owner_id).

  ## Statuses

      pending    → in_progress → completed
      pending    → deleted
      in_progress → blocked
      in_progress → deleted
      blocked    → in_progress

  ## Categories (§27.5)

      researching | planning | acting | verifying | debugging | documenting

  Each category deterministically gates which actions are allowed.
  See `KiroCockpit.Swarm.Tasks.TaskScope` for enforcement logic.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias KiroCockpit.Permissions

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(pending in_progress completed blocked deleted)
  @priorities ~w(low medium high)
  @categories ~w(researching planning acting verifying debugging documenting)

  @required_fields ~w(session_id content status priority category owner_id)a

  @type status :: :pending | :in_progress | :completed | :blocked | :deleted
  @type priority :: :low | :medium | :high
  @type category :: :researching | :planning | :acting | :verifying | :debugging | :documenting

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          plan_id: Ecto.UUID.t() | nil,
          session_id: String.t(),
          content: String.t(),
          status: String.t(),
          priority: String.t(),
          category: String.t(),
          notes: [map()],
          depends_on: [String.t()],
          blocks: [String.t()],
          owner_id: String.t(),
          sequence: integer(),
          permission_scope: [String.t()],
          files_scope: [String.t()],
          acceptance_criteria: [String.t()],
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil,
          guidance: [String.t()]
        }

  schema "swarm_tasks" do
    field :session_id, :string
    field :content, :string
    field :status, :string, default: "pending"
    field :priority, :string, default: "medium"
    field :category, :string, default: "researching"
    field :notes, {:array, :map}, default: []
    field :depends_on, {:array, :string}, default: []
    field :blocks, {:array, :string}, default: []
    field :owner_id, :string
    field :sequence, :integer, default: 0
    field :permission_scope, {:array, :string}, default: []
    field :files_scope, {:array, :string}, default: []
    field :acceptance_criteria, {:array, :string}, default: []

    field :guidance, {:array, :string}, virtual: true, default: []

    belongs_to :plan, KiroCockpit.Plans.Plan, type: :binary_id, on_replace: :nilify

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Returns the list of valid statuses.
  """
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc """
  Returns the list of valid priorities.
  """
  @spec priorities() :: [String.t()]
  def priorities, do: @priorities

  @doc """
  Returns the list of valid categories.
  """
  @spec categories() :: [String.t()]
  def categories, do: @categories

  @doc """
  Builds a changeset for creating a new task.

  Defaults are applied for `status` ("pending"), `priority` ("medium"),
  `category` ("researching"), `sequence` (0), and all jsonb array fields.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(task, attrs) do
    task
    |> cast(attrs, [
      :plan_id,
      :session_id,
      :content,
      :status,
      :priority,
      :category,
      :notes,
      :depends_on,
      :blocks,
      :owner_id,
      :sequence,
      :permission_scope,
      :files_scope,
      :acceptance_criteria
    ])
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:priority, @priorities)
    |> validate_inclusion(:category, @categories)
    |> validate_length(:session_id, max: 255)
    |> validate_length(:owner_id, max: 255)
    |> validate_length(:content, min: 1, max: 10_000)
    |> validate_number(:sequence, greater_than_or_equal_to: 0)
    |> normalize_and_validate_permission_scope()
    |> assoc_constraint(:plan)
    |> check_constraint(:status, name: :swarm_tasks_status_check)
    |> check_constraint(:priority, name: :swarm_tasks_priority_check)
    |> check_constraint(:category, name: :swarm_tasks_category_check)
    |> unique_constraint(:owner_id,
      name: :swarm_tasks_one_active_per_lane_index,
      message: "already has an active task for this session"
    )
  end

  @doc """
  Builds a changeset for a safe status transition.

  Allowed transitions per §27.4:

      pending    → in_progress | deleted
      in_progress → completed | blocked | deleted
      blocked    → in_progress

  Any other transition returns an invalid changeset.
  """
  @spec transition_changeset(t(), String.t()) :: Ecto.Changeset.t()
  def transition_changeset(%__MODULE__{status: current} = task, new_status)
      when new_status in @statuses do
    if valid_transition?(current, new_status) do
      task
      |> change(%{status: new_status})
      |> validate_inclusion(:status, @statuses)
      |> check_constraint(:status, name: :swarm_tasks_status_check)
      |> unique_constraint(:owner_id,
        name: :swarm_tasks_one_active_per_lane_index,
        message: "already has an active task for this session"
      )
    else
      task
      |> change(%{status: new_status})
      |> add_error(:status, "invalid transition from #{current} to #{new_status}")
    end
  end

  def transition_changeset(task, _invalid_status) do
    task
    |> change(%{})
    |> add_error(:status, "is not a recognized status")
  end

  @doc """
  Returns `true` if the status transition is valid per §27.4.

  Valid transitions:

      pending    → in_progress | deleted
      in_progress → completed | blocked | deleted
      blocked    → in_progress

  Any status may stay the same (idempotent no-op).
  """
  @spec valid_transition?(String.t(), String.t()) :: boolean()
  def valid_transition?(status, status), do: true

  def valid_transition?("pending", "in_progress"), do: true
  def valid_transition?("pending", "deleted"), do: true
  def valid_transition?("in_progress", "completed"), do: true
  def valid_transition?("in_progress", "blocked"), do: true
  def valid_transition?("in_progress", "deleted"), do: true
  def valid_transition?("blocked", "in_progress"), do: true
  def valid_transition?(_current, _new), do: false

  defp normalize_and_validate_permission_scope(changeset) do
    case get_field(changeset, :permission_scope) do
      permission_scope when is_list(permission_scope) ->
        {canonical, invalid} = normalize_permission_scope(permission_scope)

        if invalid == [] do
          put_change(changeset, :permission_scope, canonical)
        else
          add_error(changeset, :permission_scope, "contains invalid permissions",
            invalid: invalid
          )
        end

      _other ->
        changeset
    end
  end

  defp normalize_permission_scope(permission_scope) do
    Enum.reduce(permission_scope, {[], []}, fn raw_permission, {canonical, invalid} ->
      case Permissions.parse_permission(raw_permission) do
        {:ok, permission} ->
          {[to_string(permission) | canonical], invalid}

        {:error, _reason} ->
          {canonical, [raw_permission | invalid]}
      end
    end)
    |> then(fn {canonical, invalid} ->
      {canonical |> Enum.reverse() |> Enum.uniq(), Enum.reverse(invalid)}
    end)
  end
end
