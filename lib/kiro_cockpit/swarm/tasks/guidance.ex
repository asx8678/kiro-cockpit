defmodule KiroCockpit.Swarm.Tasks.Guidance do
  @moduledoc """
  Shared guidance strings for task lifecycle transitions (§27.9).

  These helpers are used by both `KiroCockpit.Swarm.Tasks.TaskManager`
  (to populate the virtual `guidance` field on returned task structs)
  and `KiroCockpit.Swarm.Hooks.TaskGuidanceHook` (to inject post-action
  guidance messages).

  ## Guidance (spec §27.9)

    | Transition       | Condition                        | Guidance string                                     |
    |------------------|----------------------------------|-----------------------------------------------------|
    | TaskCreate       | No active task in lane           | Activate the next task…                              |
    | TaskUpdate       | → in_progress                    | Task is active. Proceed within its category…         |
    | TaskUpdate       | → completed                      | Pick the next pending task…                          |
    | TaskUpdate       | → blocked                        | Resolve blocker, revise plan, or ask user.           |
    | PlanApproved     | —                                | Create/activate Phase 1 task…                        |
  """

  @doc """
  Returns guidance for the `create` transition.

  When `active_task_exists?` is `false`, the caller should create a
  new task and activate it. Returns `[]` when there is already an
  active task in the lane.
  """
  @spec for_create(boolean()) :: [String.t()]
  def for_create(active_task_exists? \\ false)

  def for_create(false),
    do: ["Activate the next task with status=in_progress before execution."]

  def for_create(true), do: []

  @doc """
  Returns guidance for the `activate` transition (→ in_progress).
  """
  @spec for_activate :: [String.t()]
  def for_activate, do: ["Task is active. Proceed within its category and permission scope."]

  @doc """
  Returns guidance for the `complete` transition (→ completed).
  """
  @spec for_complete :: [String.t()]
  def for_complete, do: ["Pick the next pending task or run final verification."]

  @doc """
  Returns guidance for the `block` transition (→ blocked).
  """
  @spec for_block :: [String.t()]
  def for_block, do: ["Resolve blocker, revise plan, or ask user."]

  @doc """
  Returns guidance for the `plan_approved` event.
  """
  @spec for_plan_approved :: [String.t()]
  def for_plan_approved, do: ["Create/activate Phase 1 task and begin read-only inspection."]
end
