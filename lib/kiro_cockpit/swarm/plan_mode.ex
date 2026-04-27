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

  During `planning` and `waiting_for_approval`, direct file reads (`:read`) are
  allowed for local discovery. Shell/command tools (`:shell_read` included),
  writes, terminals, external access, and destructive actions are blocked with
  actionable guidance explaining *why* and *what to do next*.

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

  @type locked_reason :: :plan_not_found | :plan_lookup_failed | :unknown_plan_status | nil

  @type t :: %__MODULE__{
          state: state(),
          plan_id: String.t() | nil,
          rejected_count: non_neg_integer(),
          locked_reason: locked_reason()
        }

  defstruct state: :idle, plan_id: nil, rejected_count: 0, locked_reason: nil

  @states ~w(idle planning waiting_for_approval approved executing verifying completed rejected failed locked)a

  @read_only_permissions [:read]

  @mutating_permissions [
    :write,
    :shell_write,
    :terminal,
    :external,
    :destructive,
    :subagent,
    :memory_write
  ]

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
    {:verifying, :fail} => :failed,
    {:locked, :reset} => :idle
  }

  # ── Constructor ────────────────────────────────────────────────────────

  @doc """
  Creates a new PlanMode in the `:idle` state, optionally with a plan_id.
  """
  @spec new(String.t() | nil) :: t()
  def new(plan_id \\ nil) do
    %__MODULE__{state: :idle, plan_id: plan_id, rejected_count: 0}
  end

  @doc """
  Creates a PlanMode in the `:locked` state — the fail-closed state for
  unknown or missing durable plan state (kiro-6dw).

  When a plan_id exists but the plan cannot be loaded from the durable
  store, or the plan has an unrecognized status, the boundary must fail
  closed rather than falling back to permissive `:idle`. The `:locked`
  state blocks all non-read actions with actionable guidance explaining
  the root cause.

  ## `:locked` vs `:idle`

    * `:idle` — no plan exists; plan-mode restrictions don't apply.
    * `:locked` — a plan *should* exist but its state is unknown; all
      mutating actions are blocked until the durable state is resolved.

  ## Parameters

    * `plan_id` — the plan correlation ID that failed to resolve.
    * `reason` — atom explaining why the plan state is unknown
      (`:plan_not_found`, `:plan_lookup_failed`, `:unknown_plan_status`).
  """
  # credo:disable-for-next-line Credo.Check.Warning.SpecWithStruct
  def locked(plan_id, reason)
      when (is_binary(plan_id) or is_nil(plan_id)) and
             reason in [:plan_not_found, :plan_lookup_failed, :unknown_plan_status] do
    %__MODULE__{state: :locked, plan_id: plan_id, rejected_count: 0, locked_reason: reason}
  end

  def locked(plan_id) when is_binary(plan_id) or is_nil(plan_id) do
    locked(plan_id, :plan_not_found)
  end

  def locked, do: locked(nil, :plan_not_found)

  # ── Introspection ──────────────────────────────────────────────────────

  @doc "Returns the list of all valid states."
  @spec states() :: [state()]
  def states, do: @states

  @doc "Returns the list of direct read permissions allowed during locked planning."
  @spec read_only_permissions() :: [permission()]
  def read_only_permissions, do: @read_only_permissions

  @doc "Returns the list of mutating permissions blocked during planning."
  @spec mutating_permissions() :: [permission()]
  def mutating_permissions, do: @mutating_permissions

  @doc "Returns the current state."
  @spec state(t()) :: state()
  def state(%__MODULE__{state: s}), do: s

  @doc "Returns true when the state machine is in a planning-locked, read-only state."
  @spec planning_locked?(t()) :: boolean()
  def planning_locked?(%__MODULE__{state: s}), do: s in [:planning, :waiting_for_approval]

  @doc "Returns true when the state machine is in a terminal state."
  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{state: s}), do: s in [:completed, :rejected, :failed]

  @doc """
  Returns true when the state machine is in the fail-closed `:locked` state.

  The `:locked` state means a plan_id is correlated but the durable plan
  state is unknown or missing. All non-read actions are blocked until
  the plan state is resolved (kiro-6dw).
  """
  @spec locked?(t()) :: boolean()
  def locked?(%__MODULE__{state: :locked}), do: true
  def locked?(%__MODULE__{}), do: false

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

  # ── Derivation helpers ──────────────────────────────────────────────────

  @doc """
  Derives a PlanMode struct from a plan's status.

  Maps plan statuses to runtime PlanMode states:

    | Plan status / condition        | PlanMode state                    |
    |--------------------------------|-----------------------------------|
    | `draft`                        | `:waiting_for_approval`           |
    | `approved`                     | `:approved`                       |
    | `running`                      | `:executing`                      |
    | `completed`                    | `:completed`                      |
    | `rejected`                     | `:rejected`                       |
    | `failed`                       | `:failed`                         |
    | `superseded`                   | `:rejected` (terminal)            |
    | nil / no plan                  | `:idle` (no plan → no restriction) |
    | unknown string status          | `:locked` (:unknown_plan_status) |
    | plan_id missing from DB        | `:locked` (:plan_not_found)       |
    | plan_id lookup failure         | `:locked` (:plan_lookup_failed)   |
    | corrupt/non-binary status      | `:locked` (:unknown_plan_status)  |

  The plan_id is preserved from the plan struct for trace correlation.
  """
  @spec from_plan(map()) :: t()
  def from_plan(%{status: status, id: plan_id}) when is_binary(status) do
    %{from_plan_status(status) | plan_id: plan_id}
  end

  def from_plan(%{status: _status, id: plan_id}) do
    # Non-binary or nil status with a plan_id — plan exists but its
    # status is corrupt/unknown. Fail closed as locked (kiro-6dw).
    locked(plan_id, :unknown_plan_status)
  end

  def from_plan(%{status: status}) when is_binary(status) do
    from_plan_status(status)
  end

  # nil status without an id — no plan exists, so no restriction.
  # This is the "no plan at all" case; :idle is correct (kiro-6dw).
  def from_plan(%{status: nil}) do
    %__MODULE__{state: :idle}
  end

  # Non-nil, non-binary status without an id — corrupt but untraceable.
  # Fail closed as locked (kiro-6dw).
  def from_plan(%{}) do
    locked(nil, :unknown_plan_status)
  end

  @status_to_state %{
    "draft" => :waiting_for_approval,
    "approved" => :approved,
    "running" => :executing,
    "completed" => :completed,
    "rejected" => :rejected,
    "failed" => :failed,
    "superseded" => :rejected
  }

  @doc """
  Derives a PlanMode from a plan status string, without a plan_id.
  """
  @spec from_plan_status(String.t() | nil) :: t()
  def from_plan_status(status) when is_binary(status) do
    case Map.fetch(@status_to_state, status) do
      {:ok, state} ->
        %__MODULE__{state: state}

      :error ->
        # Unknown status — fail closed (kiro-6dw)
        %__MODULE__{state: :locked, locked_reason: :unknown_plan_status}
    end
  end

  # No status at all — genuinely no plan exists.
  # :idle is correct: there is no plan-mode restriction when there
  # is no plan. Callers with a plan_id that failed to load should
  # use PlanMode.locked/2 instead (kiro-6dw).
  #
  # Note: for a plan with a non-binary/corrupt status, callers
  # should use from_plan/1 or locked/2 which carry the plan_id
  # and return :locked with :unknown_plan_status. from_plan_status/1
  # without a plan_id has no way to know whether a plan exists,
  # so nil → :idle is the correct default (kiro-6dw).
  def from_plan_status(nil) do
    %__MODULE__{state: :idle}
  end

  # Non-binary, non-nil status — this shouldn't happen in normal flows
  # since DB statuses are strings. Fail closed as locked (kiro-6dw).
  def from_plan_status(_corrupt) do
    %__MODULE__{state: :locked, locked_reason: :unknown_plan_status}
  end

  @doc """
  Returns a PlanMode in the `:planning` state, suitable for plan generation.

  Use this as the default plan_mode for `NanoPlanner.plan/3` boundary opts
  so that the planning lifecycle state is automatically wired without
  requiring callers to construct a PlanMode explicitly.
  """
  @spec for_planning() :: t()
  def for_planning do
    %__MODULE__{state: :planning}
  end

  # ── Action / permission predicates ────────────────────────────────────

  @doc """
  Checks whether a permission-level action is allowed in the current state.

  Returns `:ok` if the action is permitted, or
  `{:blocked, reason, guidance}` with actionable guidance for the operator.

  ## Rules (§27.8, §27.11 Invariant 2)

    - `:idle` — no plan-mode restrictions (other policies apply externally).
    - `:planning` / `:waiting_for_approval` — direct reads only; commands/tools are blocked.
    - `:approved` / `:executing` / `:verifying` — mutations unlocked by scope.
    - `:completed` / `:rejected` / `:failed` — no plan-mode restrictions.

  ## Examples

      iex> plan_mode = KiroCockpit.Swarm.PlanMode.new()
      iex> KiroCockpit.Swarm.PlanMode.check_action(plan_mode, :read)
      :ok

      iex> {:ok, pm} = KiroCockpit.Swarm.PlanMode.enter_plan_mode(KiroCockpit.Swarm.PlanMode.new())
      iex> KiroCockpit.Swarm.PlanMode.check_action(pm, :read)
      :ok
  """
  @spec check_action(t(), permission()) :: action_result()
  def check_action(%__MODULE__{state: state} = plan_mode, permission) do
    cond do
      state in [:idle, :completed, :rejected, :failed] ->
        :ok

      state == :locked ->
        # kiro-6dw: locked state blocks all non-read actions — fail-closed
        # for unknown/missing durable plan state.
        if permission in @read_only_permissions do
          :ok
        else
          {:blocked, "Action blocked: plan state is locked (unknown)",
           guidance_for_locked_permission(permission, plan_mode)}
        end

      state in [:planning, :waiting_for_approval] ->
        if permission in @read_only_permissions do
          :ok
        else
          {:blocked, "Action blocked during planning",
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
  Returns true if direct read discovery is allowed in the current state.

  Locked planning states allow direct reads for local discovery, but shell/command
  tools remain blocked until approval/execution unlocks them (§27.6, §36.2).
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
      :completed,
      :locked
    ]
  end

  @doc """
  Returns true if mutating actions (write/shell/implementation) are blocked.

  Mutating actions are blocked during `:planning` and `:waiting_for_approval`
  (§27.11 Invariant 2).
  """
  @spec mutations_blocked?(t()) :: boolean()
  def mutations_blocked?(%__MODULE__{} = plan_mode) do
    planning_locked?(plan_mode) or locked?(plan_mode)
  end

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
  defp guidance_for_blocked_permission(:read, :planning) do
    "File reads are tool actions and are not allowed while planning. " <>
      "Use existing context to draft the plan, then request approval before tool use."
  end

  defp guidance_for_blocked_permission(:read, :waiting_for_approval) do
    "File reads are blocked until the plan is approved. " <>
      "Approve the plan to unlock read access, or request revisions."
  end

  defp guidance_for_blocked_permission(:write, :planning) do
    "File modifications are not allowed while planning. " <>
      "Finish the plan draft and get approval before making changes."
  end

  defp guidance_for_blocked_permission(:write, :waiting_for_approval) do
    "File modifications are blocked until the plan is approved. " <>
      "Approve the plan to unlock write access, or request revisions."
  end

  defp guidance_for_blocked_permission(:shell_read, :planning) do
    "Shell/command tools are not allowed while planning. " <>
      "Produce the plan first, then execute diagnostics after approval or delegation."
  end

  defp guidance_for_blocked_permission(:shell_read, :waiting_for_approval) do
    "Shell/command tools are blocked until the plan is approved. " <>
      "Approve the plan to unlock command execution."
  end

  defp guidance_for_blocked_permission(:shell_write, :planning) do
    "Shell commands that modify files are not allowed while planning. " <>
      "Finish and approve the plan before running commands."
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

  defp guidance_for_blocked_permission(:subagent, state) do
    "Subagent invocation is blocked during #{state}. " <>
      "Approve the plan to unlock subagent delegation."
  end

  defp guidance_for_blocked_permission(:memory_write, state) do
    "Memory write is blocked during #{state}. " <>
      "Approve the plan to unlock memory promotion."
  end

  defp guidance_for_blocked_permission(_perm, state) do
    "This action is blocked during #{state}. " <>
      "Wait for plan approval before making changes."
  end

  # kiro-6dw: Guidance for actions blocked in the fail-closed :locked state.
  # The locked state means a plan_id is correlated but durable plan state
  # is unknown or missing. Guidance is actionable — tells the operator what
  # to investigate and how to recover.
  defp guidance_for_locked_permission(permission, plan_mode) do
    reason_text =
      case plan_mode.locked_reason do
        :plan_not_found -> "Plan not found in the database (it may have been deleted)."
        :plan_lookup_failed -> "Plan lookup failed (database may be unavailable)."
        :unknown_plan_status -> "Plan has an unrecognized status."
        nil -> "Plan state is unknown."
      end

    "#{permission_label(permission)} are blocked because the plan state " <>
      "is locked (unknown). #{reason_text} " <>
      "Verify the plan exists and has a valid status, or reset plan mode to idle."
  end

  defp permission_label(:read), do: "Reads"
  defp permission_label(:write), do: "Writes"
  defp permission_label(:shell_read), do: "Shell diagnostics"
  defp permission_label(:shell_write), do: "Shell commands"
  defp permission_label(:terminal), do: "Terminal sessions"
  defp permission_label(:external), do: "External access"
  defp permission_label(:destructive), do: "Destructive actions"
  defp permission_label(:subagent), do: "Subagent invocations"
  defp permission_label(:memory_write), do: "Memory writes"
  defp permission_label(other), do: "#{other} actions"
end
