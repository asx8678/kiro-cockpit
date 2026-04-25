defmodule KiroCockpit.Swarm.PlanMode do
  @moduledoc """
  Pure, read-only plan-mode state machine for the Swarm runtime.

  Tracks the lifecycle of a planning session: from idle through planning,
  approval, execution, verification, and completion. No side effects —
  no DB writes, no IO, no process state. The Postgres row is the source
  of truth (§4.1); this struct is a coordination artifact.

  ## States (§27.8)

      idle → planning → waiting_for_approval → approved → executing → verifying → completed
                                           ↘ rejected                    ↘ failed

  Two additional terminal states beyond the core seven:
    - `rejected` — user explicitly rejected the draft plan
    - `failed`   — execution or verification failed

  Both are useful: `rejected` signals operator intent and should produce
  different guidance than a generic reset. `failed` preserves the failure
  context so callers can decide between retry and reset.

  ## Invariant 2 (§27.11)

  "Plan mode allows read-only discovery only."

  During `planning` and `waiting_for_approval`, only `:read` and
  `:shell_read` actions are permitted. All mutating actions (`:write`,
  `:shell_write`, `:terminal`, `:external`, `:destructive`) are blocked
  with actionable guidance explaining *why* and *what to do next*.

  ## Scope

  This module is intentionally independent of hooks, tasks, and the DB.
  Wiring to `HookManager` and `TaskManager` happens in `kiro-yhe`.
  """

  alias KiroCockpit.Permissions

  # ── Types ──────────────────────────────────────────────────────────────

  @type state ::
          :idle
          | :planning
          | :waiting_for_approval
          | :approved
          | :executing
          | :verifying
          | :completed
          | :rejected
          | :failed

  @type permission :: Permissions.permission()

  @type action_result :: :ok | {:blocked, String.t(), String.t()}

  @type t :: %__MODULE__{
          state: state(),
          plan_id: String.t() | nil,
          rejected_count: non_neg_integer()
        }

  defstruct state: :idle, plan_id: nil, rejected_count: 0

  @states ~w(idle planning waiting_for_approval approved executing verifying completed rejected failed)a

  @read_only_permissions [:read, :shell_read]

  @mutating_permissions [:write, :shell_write, :terminal, :external, :destructive]

  # ── Valid transitions table ───────────────────────────────────────────
  #
  # Key = {from_state, event},  Value = to_state
  # Events map 1:1 to the public transition functions.

  @transitions %{
    {:idle, :enter_plan_mode} => :planning,
    {:planning, :draft_generated} => :waiting_for_approval,
    {:planning, :cancel} => :idle,
    {:waiting_for_approval, :approve} => :approved,
    {:waiting_for_approval, :reject} => :rejected,
    {:waiting_for_approval, :revise} => :planning,
    {:approved, :start_execution} => :executing,
    {:executing, :start_verification} => :verifying,
    {:executing, :fail} => :failed,
    {:verifying, :complete} => :completed,
    {:verifying, :fail} => :failed
  }

  # ── Constructor ────────────────────────────────────────────────────────

  @doc """
  Creates a new PlanMode in the `:idle` state, optionally with a plan_id.
  """
  @spec new(String.t() | nil) :: t()
  def new(plan_id \\ nil) do
    %__MODULE__{state: :idle, plan_id: plan_id, rejected_count: 0}
  end

  # ── Introspection ──────────────────────────────────────────────────────

  @doc "Returns the list of all valid states."
  @spec states() :: [state()]
  def states, do: @states

  @doc "Returns the list of read-only discovery permissions allowed during planning."
  @spec read_only_permissions() :: [permission()]
  def read_only_permissions, do: @read_only_permissions

  @doc "Returns the list of mutating permissions blocked during planning."
  @spec mutating_permissions() :: [permission()]
  def mutating_permissions, do: @mutating_permissions

  @doc "Returns the current state."
  @spec state(t()) :: state()
  def state(%__MODULE__{state: s}), do: s

  @doc "Returns true when the state machine is in a planning-locked state (read-only discovery only)."
  @spec planning_locked?(t()) :: boolean()
  def planning_locked?(%__MODULE__{state: s}), do: s in [:planning, :waiting_for_approval]

  @doc "Returns true when the state machine is in a terminal state."
  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{state: s}), do: s in [:completed, :rejected, :failed]

  @doc "Returns true when mutations are unlocked (after approval, during execution/verification)."
  @spec execution_unlocked?(t()) :: boolean()
  def execution_unlocked?(%__MODULE__{state: s}) do
    s in [:approved, :executing, :verifying]
  end

  @doc "Returns all valid events from the current state."
  @spec valid_events(t()) :: [atom()]
  def valid_events(%__MODULE__{state: s}) do
    @transitions
    |> Enum.filter(fn {{from, _event}, _to} -> from == s end)
    |> Enum.map(fn {{_from, event}, _to} -> event end)
  end

  # ── Transition functions ───────────────────────────────────────────────

  @doc """
  Enters plan mode: idle → planning.

  Only valid from `:idle`. This is the entry point that triggers
  PlanModeFirstActionHook (wired externally in kiro-yhe).
  """
  @spec enter_plan_mode(t()) :: {:ok, t()} | {:error, :invalid_transition}
  def enter_plan_mode(plan_mode), do: transition(plan_mode, :enter_plan_mode)

  @doc """
  Draft has been generated: planning → waiting_for_approval.

  The structured plan is ready for user review.
  """
  @spec draft_generated(t()) :: {:ok, t()} | {:error, :invalid_transition}
  def draft_generated(plan_mode), do: transition(plan_mode, :draft_generated)

  @doc """
  User approves the draft: waiting_for_approval → approved.

  After approval, execution is unlocked. The first task should be activated.
  """
  @spec approve(t()) :: {:ok, t()} | {:error, :invalid_transition}
  def approve(plan_mode), do: transition(plan_mode, :approve)

  @doc """
  User rejects the draft: waiting_for_approval → rejected.

  A terminal state. Use `reset/1` to return to idle.
  """
  @spec reject(t()) :: {:ok, t()} | {:error, :invalid_transition}
  def reject(plan_mode), do: transition(plan_mode, :reject)

  @doc """
  User requests revision: waiting_for_approval → planning.

  Sends the planner back to produce a revised draft.
  """
  @spec revise(t()) :: {:ok, t()} | {:error, :invalid_transition}
  def revise(plan_mode), do: transition(plan_mode, :revise)

  @doc """
  Cancels planning: planning → idle.

  Only valid from `:planning` state.
  """
  @spec cancel(t()) :: {:ok, t()} | {:error, :invalid_transition}
  def cancel(plan_mode), do: transition(plan_mode, :cancel)

  @doc """
  Starts execution: approved → executing.

  Execution is now unlocked; mutations are allowed within task scope.
  """
  @spec start_execution(t()) :: {:ok, t()} | {:error, :invalid_transition}
  def start_execution(plan_mode), do: transition(plan_mode, :start_execution)

  @doc """
  Starts verification: executing → verifying.

  All implementation work is done; verification steps are running.
  """
  @spec start_verification(t()) :: {:ok, t()} | {:error, :invalid_transition}
  def start_verification(plan_mode), do: transition(plan_mode, :start_verification)

  @doc """
  Verification succeeds: verifying → completed.

  Terminal state. Use `reset/1` to return to idle for a new plan.
  """
  @spec complete(t()) :: {:ok, t()} | {:error, :invalid_transition}
  def complete(plan_mode), do: transition(plan_mode, :complete)

  @doc """
  Execution or verification fails: executing|verifying → failed.

  Terminal state. Use `reset/1` to return to idle.
  """
  @spec fail(t()) :: {:ok, t()} | {:error, :invalid_transition}
  def fail(plan_mode), do: transition(plan_mode, :fail)

  @doc """
  Resets to idle from any state.

  Always succeeds. Preserves `plan_id` and `rejected_count` so callers
  can track revision history across resets.
  """
  @spec reset(t()) :: {:ok, t()}
  def reset(%__MODULE__{} = plan_mode) do
    {:ok, %__MODULE__{plan_id: plan_mode.plan_id, rejected_count: plan_mode.rejected_count}}
  end

  # ── Action / permission predicates ────────────────────────────────────

  @doc """
  Checks whether a permission-level action is allowed in the current state.

  Returns `:ok` if the action is permitted, or
  `{:blocked, reason, guidance}` with actionable guidance for the operator.

  ## Rules (§27.8, §27.11 Invariant 2)

    - `:idle` — no plan-mode restrictions (other policies apply externally).
    - `:planning` / `:waiting_for_approval` — read-only discovery only.
    - `:approved` / `:executing` / `:verifying` — mutations unlocked by scope.
    - `:completed` / `:rejected` / `:failed` — no plan-mode restrictions.

  ## Examples

      iex> plan_mode = KiroCockpit.Swarm.PlanMode.new()
      iex> KiroCockpit.Swarm.PlanMode.check_action(plan_mode, :read)
      :ok

      iex> {:ok, pm} = KiroCockpit.Swarm.PlanMode.enter_plan_mode(KiroCockpit.Swarm.PlanMode.new())
      iex> KiroCockpit.Swarm.PlanMode.check_action(pm, :write)
      {:blocked, "Mutating action blocked during planning",
       "Wait for plan approval before making changes. Approve the plan to unlock execution."}
  """
  @spec check_action(t(), permission()) :: action_result()
  def check_action(%__MODULE__{state: state}, permission) do
    cond do
      state in [:idle, :completed, :rejected, :failed] ->
        :ok

      state in [:planning, :waiting_for_approval] ->
        if permission in @read_only_permissions do
          :ok
        else
          {:blocked, "Mutating action blocked during planning",
           guidance_for_blocked_permission(permission, state)}
        end

      state in [:approved, :executing, :verifying] ->
        :ok

      true ->
        {:blocked, "Unknown plan mode state", "Reset plan mode to idle and try again."}
    end
  end

  @doc """
  Boolean shortcut: returns `true` if the action is allowed, `false` otherwise.

  For the full result with guidance, use `check_action/2`.
  """
  @spec action_allowed?(t(), permission()) :: boolean()
  def action_allowed?(plan_mode, permission) do
    match?(:ok, check_action(plan_mode, permission))
  end

  @doc """
  Returns true if read-only discovery actions are allowed in the current state.

  Read-only discovery (`:read`, `:shell_read`) is allowed in `:planning`
  and `:waiting_for_approval` without requiring an active task (§27.8).
  """
  @spec read_only_discovery_allowed?(t()) :: boolean()
  def read_only_discovery_allowed?(%__MODULE__{state: state}) do
    state in [
      :idle,
      :planning,
      :waiting_for_approval,
      :approved,
      :executing,
      :verifying,
      :completed
    ]
  end

  @doc """
  Returns true if mutating actions (write/shell/implementation) are blocked.

  Mutating actions are blocked during `:planning` and `:waiting_for_approval`
  (§27.11 Invariant 2).
  """
  @spec mutations_blocked?(t()) :: boolean()
  def mutations_blocked?(%__MODULE__{} = plan_mode), do: planning_locked?(plan_mode)

  # ── Private ────────────────────────────────────────────────────────────

  defp transition(%__MODULE__{state: from} = plan_mode, event) do
    case Map.fetch(@transitions, {from, event}) do
      {:ok, to} ->
        new_plan_mode = apply_transition_side_effects(plan_mode, from, event, to)
        {:ok, %{new_plan_mode | state: to}}

      :error ->
        {:error, :invalid_transition}
    end
  end

  # Track rejection count so callers can detect excessive revision loops.
  defp apply_transition_side_effects(plan_mode, :waiting_for_approval, :reject, :rejected) do
    %{plan_mode | rejected_count: plan_mode.rejected_count + 1}
  end

  defp apply_transition_side_effects(plan_mode, _from, _event, _to) do
    plan_mode
  end

  # Guidance strings are actionable — they tell the operator *what to do*,
  # not just *what went wrong*.
  defp guidance_for_blocked_permission(:write, :planning) do
    "File modifications are not allowed while planning. " <>
      "Finish the plan draft and get approval before making changes."
  end

  defp guidance_for_blocked_permission(:write, :waiting_for_approval) do
    "File modifications are blocked until the plan is approved. " <>
      "Approve the plan to unlock write access, or request revisions."
  end

  defp guidance_for_blocked_permission(:shell_write, :planning) do
    "Shell commands that modify files are not allowed while planning. " <>
      "Use read-only commands (git status, mix test --dry-run) for discovery."
  end

  defp guidance_for_blocked_permission(:shell_write, :waiting_for_approval) do
    "Shell commands that modify files are blocked until approval. " <>
      "Approve the plan to unlock shell write access."
  end

  defp guidance_for_blocked_permission(:terminal, state) do
    "Interactive terminal sessions are blocked during #{state}. " <>
      "Approve the plan to unlock terminal access."
  end

  defp guidance_for_blocked_permission(:external, state) do
    "External network access is blocked during #{state}. " <>
      "Approve the plan to unlock external access."
  end

  defp guidance_for_blocked_permission(:destructive, state) do
    "Destructive actions are blocked during #{state}. " <>
      "These are never auto-approved; explicit operator approval is required."
  end

  defp guidance_for_blocked_permission(_perm, state) do
    "This action is blocked during #{state}. " <>
      "Wait for plan approval before making changes."
  end
end
