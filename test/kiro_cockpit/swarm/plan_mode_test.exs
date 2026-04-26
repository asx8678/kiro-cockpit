defmodule KiroCockpit.Swarm.PlanModeTest do
  use ExUnit.Case, async: true

  alias KiroCockpit.Swarm.PlanMode

  # ── Constructor ───────────────────────────────────────────────────────

  describe "new/1" do
    test "creates a PlanMode in idle state by default" do
      pm = PlanMode.new()
      assert PlanMode.state(pm) == :idle
      assert pm.plan_id == nil
      assert pm.rejected_count == 0
    end

    test "accepts an optional plan_id" do
      pm = PlanMode.new("plan_001")
      assert pm.plan_id == "plan_001"
      assert PlanMode.state(pm) == :idle
    end
  end

  # ── Introspection ─────────────────────────────────────────────────────

  describe "states/0" do
    test "returns all 9 states including rejected and failed" do
      states = PlanMode.states()

      expected =
        ~w(idle planning waiting_for_approval approved executing verifying completed rejected failed)a

      assert states == expected
    end
  end

  # ── Derivation helpers ─────────────────────────────────────────────────

  describe "from_plan/1" do
    test "derives waiting_for_approval from draft plan" do
      pm = PlanMode.from_plan(%{status: "draft", id: "plan-1"})
      assert pm.state == :waiting_for_approval
      assert pm.plan_id == "plan-1"
    end

    test "derives approved from approved plan" do
      pm = PlanMode.from_plan(%{status: "approved", id: "plan-2"})
      assert pm.state == :approved
    end

    test "derives executing from running plan" do
      pm = PlanMode.from_plan(%{status: "running"})
      assert pm.state == :executing
    end

    test "derives completed from completed plan" do
      pm = PlanMode.from_plan(%{status: "completed"})
      assert pm.state == :completed
    end

    test "derives rejected from rejected plan" do
      pm = PlanMode.from_plan(%{status: "rejected"})
      assert pm.state == :rejected
    end

    test "derives failed from failed plan" do
      pm = PlanMode.from_plan(%{status: "failed"})
      assert pm.state == :failed
    end

    test "derives rejected from superseded plan (terminal safe state)" do
      pm = PlanMode.from_plan(%{status: "superseded"})
      assert pm.state == :rejected
    end

    test "derives idle from unknown status" do
      pm = PlanMode.from_plan(%{status: "unknown_status"})
      assert pm.state == :idle
    end

    test "derives idle from nil plan_id" do
      pm = PlanMode.from_plan(%{status: nil})
      assert pm.state == :idle
    end
  end

  describe "from_plan_status/1" do
    test "derives waiting_for_approval from draft" do
      assert PlanMode.from_plan_status("draft").state == :waiting_for_approval
    end

    test "derives approved from approved" do
      assert PlanMode.from_plan_status("approved").state == :approved
    end

    test "derives executing from running" do
      assert PlanMode.from_plan_status("running").state == :executing
    end

    test "derives idle from nil" do
      assert PlanMode.from_plan_status(nil).state == :idle
    end
  end

  describe "for_planning/0" do
    test "returns a PlanMode in planning state" do
      pm = PlanMode.for_planning()
      assert pm.state == :planning
      assert pm.plan_id == nil
    end
  end

  describe "planning_locked?/1" do
    test "returns true for planning" do
      {:ok, pm} = PlanMode.enter_plan_mode(PlanMode.new())
      assert PlanMode.planning_locked?(pm)
    end

    test "returns true for waiting_for_approval" do
      {:ok, pm} =
        PlanMode.new()
        |> PlanMode.enter_plan_mode()
        |> then(fn {:ok, pm} -> PlanMode.draft_generated(pm) end)

      assert PlanMode.planning_locked?(pm)
    end

    test "returns false for idle" do
      refute PlanMode.planning_locked?(PlanMode.new())
    end

    test "returns false for approved" do
      {:ok, pm} = full_approve()
      refute PlanMode.planning_locked?(pm)
    end

    test "returns false for executing" do
      {:ok, pm} = full_execute()
      refute PlanMode.planning_locked?(pm)
    end
  end

  describe "terminal?/1" do
    test "returns true for completed, rejected, failed" do
      {:ok, pm_completed} = full_complete()
      {:ok, pm_rejected} = full_reject()
      {:ok, pm_failed} = full_fail()

      assert PlanMode.terminal?(pm_completed)
      assert PlanMode.terminal?(pm_rejected)
      assert PlanMode.terminal?(pm_failed)
    end

    test "returns false for non-terminal states" do
      for state <- [:idle, :planning, :waiting_for_approval, :approved, :executing, :verifying] do
        pm = %PlanMode{state: state}
        refute PlanMode.terminal?(pm)
      end
    end
  end

  describe "execution_unlocked?/1" do
    test "returns true for approved, executing, verifying" do
      {:ok, pm_approved} = full_approve()
      {:ok, pm_executing} = full_execute()
      {:ok, pm_verifying} = full_verify()

      assert PlanMode.execution_unlocked?(pm_approved)
      assert PlanMode.execution_unlocked?(pm_executing)
      assert PlanMode.execution_unlocked?(pm_verifying)
    end

    test "returns false for planning and waiting_for_approval" do
      {:ok, pm_planning} = PlanMode.enter_plan_mode(PlanMode.new())

      {:ok, pm_waiting} =
        PlanMode.new()
        |> PlanMode.enter_plan_mode()
        |> then(fn {:ok, pm} -> PlanMode.draft_generated(pm) end)

      refute PlanMode.execution_unlocked?(pm_planning)
      refute PlanMode.execution_unlocked?(pm_waiting)
    end
  end

  describe "valid_events/1" do
    test "idle has enter_plan_mode" do
      assert :enter_plan_mode in PlanMode.valid_events(PlanMode.new())
    end

    test "planning has draft_generated and cancel" do
      {:ok, pm} = PlanMode.enter_plan_mode(PlanMode.new())
      events = PlanMode.valid_events(pm)
      assert :draft_generated in events
      assert :cancel in events
    end

    test "waiting_for_approval has approve, reject, revise" do
      {:ok, pm} =
        PlanMode.new()
        |> PlanMode.enter_plan_mode()
        |> then(fn {:ok, pm} -> PlanMode.draft_generated(pm) end)

      events = PlanMode.valid_events(pm)
      assert :approve in events
      assert :reject in events
      assert :revise in events
    end
  end

  # ── Allowed transitions ───────────────────────────────────────────────

  describe "allowed transitions" do
    test "idle → planning via enter_plan_mode" do
      assert {:ok, %PlanMode{state: :planning}} = PlanMode.enter_plan_mode(PlanMode.new())
    end

    test "planning → waiting_for_approval via draft_generated" do
      {:ok, pm} = PlanMode.enter_plan_mode(PlanMode.new())
      assert {:ok, %PlanMode{state: :waiting_for_approval}} = PlanMode.draft_generated(pm)
    end

    test "planning → idle via cancel" do
      {:ok, pm} = PlanMode.enter_plan_mode(PlanMode.new())
      assert {:ok, %PlanMode{state: :idle}} = PlanMode.cancel(pm)
    end

    test "waiting_for_approval → approved via approve" do
      {:ok, pm} = full_draft()
      assert {:ok, %PlanMode{state: :approved}} = PlanMode.approve(pm)
    end

    test "waiting_for_approval → rejected via reject" do
      {:ok, pm} = full_draft()
      assert {:ok, %PlanMode{state: :rejected}} = PlanMode.reject(pm)
    end

    test "waiting_for_approval → planning via revise" do
      {:ok, pm} = full_draft()
      assert {:ok, %PlanMode{state: :planning}} = PlanMode.revise(pm)
    end

    test "approved → executing via start_execution" do
      {:ok, pm} = full_approve()
      assert {:ok, %PlanMode{state: :executing}} = PlanMode.start_execution(pm)
    end

    test "executing → verifying via start_verification" do
      {:ok, pm} = full_execute()
      assert {:ok, %PlanMode{state: :verifying}} = PlanMode.start_verification(pm)
    end

    test "verifying → completed via complete" do
      {:ok, pm} = full_verify()
      assert {:ok, %PlanMode{state: :completed}} = PlanMode.complete(pm)
    end

    test "executing → failed via fail" do
      {:ok, pm} = full_execute()
      assert {:ok, %PlanMode{state: :failed}} = PlanMode.fail(pm)
    end

    test "verifying → failed via fail" do
      {:ok, pm} = full_verify()
      assert {:ok, %PlanMode{state: :failed}} = PlanMode.fail(pm)
    end

    test "full lifecycle: idle → planning → waiting → approved → executing → verifying → completed" do
      {:ok, pm} =
        PlanMode.new("plan_001")
        |> PlanMode.enter_plan_mode()
        |> then(fn {:ok, pm} -> PlanMode.draft_generated(pm) end)
        |> then(fn {:ok, pm} -> PlanMode.approve(pm) end)
        |> then(fn {:ok, pm} -> PlanMode.start_execution(pm) end)
        |> then(fn {:ok, pm} -> PlanMode.start_verification(pm) end)
        |> then(fn {:ok, pm} -> PlanMode.complete(pm) end)

      assert PlanMode.state(pm) == :completed
      assert pm.plan_id == "plan_001"
    end

    test "revise cycle: planning → waiting → revise → planning → waiting → approved" do
      {:ok, pm} =
        PlanMode.new()
        |> PlanMode.enter_plan_mode()
        |> then(fn {:ok, pm} -> PlanMode.draft_generated(pm) end)
        |> then(fn {:ok, pm} -> PlanMode.revise(pm) end)
        |> then(fn {:ok, pm} -> PlanMode.draft_generated(pm) end)
        |> then(fn {:ok, pm} -> PlanMode.approve(pm) end)

      assert PlanMode.state(pm) == :approved
    end
  end

  # ── Invalid transitions ───────────────────────────────────────────────

  describe "invalid transitions" do
    test "cannot enter plan mode from planning" do
      {:ok, pm} = PlanMode.enter_plan_mode(PlanMode.new())
      assert {:error, :invalid_transition} = PlanMode.enter_plan_mode(pm)
    end

    test "cannot enter plan mode from waiting_for_approval" do
      {:ok, pm} = full_draft()
      assert {:error, :invalid_transition} = PlanMode.enter_plan_mode(pm)
    end

    test "cannot approve from planning" do
      {:ok, pm} = PlanMode.enter_plan_mode(PlanMode.new())
      assert {:error, :invalid_transition} = PlanMode.approve(pm)
    end

    test "cannot approve from idle" do
      assert {:error, :invalid_transition} = PlanMode.approve(PlanMode.new())
    end

    test "cannot start execution from waiting_for_approval" do
      {:ok, pm} = full_draft()
      assert {:error, :invalid_transition} = PlanMode.start_execution(pm)
    end

    test "cannot start execution from planning" do
      {:ok, pm} = PlanMode.enter_plan_mode(PlanMode.new())
      assert {:error, :invalid_transition} = PlanMode.start_execution(pm)
    end

    test "cannot complete from executing" do
      {:ok, pm} = full_execute()
      assert {:error, :invalid_transition} = PlanMode.complete(pm)
    end

    test "cannot fail from idle" do
      assert {:error, :invalid_transition} = PlanMode.fail(PlanMode.new())
    end

    test "cannot fail from completed" do
      {:ok, pm} = full_complete()
      assert {:error, :invalid_transition} = PlanMode.fail(pm)
    end

    test "cannot reject from approved" do
      {:ok, pm} = full_approve()
      assert {:error, :invalid_transition} = PlanMode.reject(pm)
    end

    test "cannot draft from idle" do
      assert {:error, :invalid_transition} = PlanMode.draft_generated(PlanMode.new())
    end

    test "cannot verify from approved" do
      {:ok, pm} = full_approve()
      assert {:error, :invalid_transition} = PlanMode.start_verification(pm)
    end

    test "terminal states reject further transitions" do
      {:ok, completed} = full_complete()
      {:ok, rejected} = full_reject()
      {:ok, failed} = full_fail()

      for pm <- [completed, rejected, failed] do
        assert {:error, :invalid_transition} = PlanMode.enter_plan_mode(pm)
        assert {:error, :invalid_transition} = PlanMode.approve(pm)
        assert {:error, :invalid_transition} = PlanMode.start_execution(pm)
      end
    end
  end

  # ── Read-only discovery in planning (§27.8, §27.11 Invariant 2, §36.2) ──

  describe "action allowed during planning — direct reads only" do
    test "read action is allowed in planning state without task" do
      {:ok, pm} = PlanMode.enter_plan_mode(PlanMode.new())
      assert PlanMode.action_allowed?(pm, :read)
      assert :ok = PlanMode.check_action(pm, :read)
    end

    test "shell_read action is blocked in planning state without task" do
      {:ok, pm} = PlanMode.enter_plan_mode(PlanMode.new())
      refute PlanMode.action_allowed?(pm, :shell_read)
      assert {:blocked, reason, guidance} = PlanMode.check_action(pm, :shell_read)
      assert reason == "Action blocked during planning"
      assert guidance =~ "Shell/command"
    end

    test "read action is allowed in waiting_for_approval state" do
      {:ok, pm} = full_draft()
      assert PlanMode.action_allowed?(pm, :read)
    end

    test "shell_read action is blocked in waiting_for_approval state" do
      {:ok, pm} = full_draft()
      refute PlanMode.action_allowed?(pm, :shell_read)
    end
  end

  # ── Write/shell blocked in planning/waiting (§36.2) ───────────────────

  describe "action blocked during planning — mutating actions" do
    test "write action is blocked in planning state" do
      {:ok, pm} = PlanMode.enter_plan_mode(PlanMode.new())
      refute PlanMode.action_allowed?(pm, :write)

      assert {:blocked, reason, guidance} = PlanMode.check_action(pm, :write)
      assert reason =~ "Action blocked"
      assert is_binary(guidance) and guidance != ""
    end

    test "shell_write action is blocked in planning state" do
      {:ok, pm} = PlanMode.enter_plan_mode(PlanMode.new())
      refute PlanMode.action_allowed?(pm, :shell_write)

      assert {:blocked, _reason, guidance} = PlanMode.check_action(pm, :shell_write)
      assert guidance =~ "Finish"
    end

    test "write action is blocked in waiting_for_approval state" do
      {:ok, pm} = full_draft()
      refute PlanMode.action_allowed?(pm, :write)

      assert {:blocked, _reason, guidance} = PlanMode.check_action(pm, :write)
      assert guidance =~ "approval" or guidance =~ "Approve"
    end

    test "shell_write action is blocked in waiting_for_approval state" do
      {:ok, pm} = full_draft()
      refute PlanMode.action_allowed?(pm, :shell_write)
    end

    test "terminal action is blocked in planning state" do
      {:ok, pm} = PlanMode.enter_plan_mode(PlanMode.new())
      refute PlanMode.action_allowed?(pm, :terminal)
    end

    test "external action is blocked in planning state" do
      {:ok, pm} = PlanMode.enter_plan_mode(PlanMode.new())
      refute PlanMode.action_allowed?(pm, :external)
    end

    test "destructive action is blocked in planning state" do
      {:ok, pm} = PlanMode.enter_plan_mode(PlanMode.new())
      refute PlanMode.action_allowed?(pm, :destructive)

      assert {:blocked, _reason, guidance} = PlanMode.check_action(pm, :destructive)
      assert guidance =~ "never auto-approved"
    end
  end

  # ── Execution allowed after approval (§36.2) ──────────────────────────

  describe "execution allowed after approval" do
    test "all actions are allowed in approved state" do
      {:ok, pm} = full_approve()

      for perm <-
            PlanMode.mutating_permissions() ++ PlanMode.read_only_permissions() ++ [:shell_read] do
        assert PlanMode.action_allowed?(pm, perm),
               "Expected #{perm} to be allowed in approved state"
      end
    end

    test "all actions are allowed in executing state" do
      {:ok, pm} = full_execute()

      for perm <-
            PlanMode.mutating_permissions() ++ PlanMode.read_only_permissions() ++ [:shell_read] do
        assert PlanMode.action_allowed?(pm, perm),
               "Expected #{perm} to be allowed in executing state"
      end
    end

    test "all actions are allowed in verifying state" do
      {:ok, pm} = full_verify()

      for perm <-
            PlanMode.mutating_permissions() ++ PlanMode.read_only_permissions() ++ [:shell_read] do
        assert PlanMode.action_allowed?(pm, perm),
               "Expected #{perm} to be allowed in verifying state"
      end
    end
  end

  # ── Reset behavior ────────────────────────────────────────────────────

  describe "reset/1" do
    test "resets from completed to idle" do
      {:ok, pm} = full_complete()
      assert {:ok, reset_pm} = PlanMode.reset(pm)
      assert PlanMode.state(reset_pm) == :idle
    end

    test "resets from rejected to idle" do
      {:ok, pm} = full_reject()
      assert {:ok, reset_pm} = PlanMode.reset(pm)
      assert PlanMode.state(reset_pm) == :idle
    end

    test "resets from failed to idle" do
      {:ok, pm} = full_fail()
      assert {:ok, reset_pm} = PlanMode.reset(pm)
      assert PlanMode.state(reset_pm) == :idle
    end

    test "resets from planning to idle" do
      {:ok, pm} = PlanMode.enter_plan_mode(PlanMode.new())
      assert {:ok, reset_pm} = PlanMode.reset(pm)
      assert PlanMode.state(reset_pm) == :idle
    end

    test "resets from any state" do
      for state <- PlanMode.states() do
        pm = %PlanMode{state: state}
        assert {:ok, reset_pm} = PlanMode.reset(pm)
        assert PlanMode.state(reset_pm) == :idle
      end
    end

    test "preserves plan_id across reset" do
      {:ok, pm} = full_complete("plan_xyz")
      {:ok, reset_pm} = PlanMode.reset(pm)
      assert reset_pm.plan_id == "plan_xyz"
    end

    test "preserves rejected_count across reset" do
      {:ok, pm} =
        PlanMode.new()
        |> PlanMode.enter_plan_mode()
        |> then(fn {:ok, pm} -> PlanMode.draft_generated(pm) end)
        |> then(fn {:ok, pm} -> PlanMode.reject(pm) end)

      assert pm.rejected_count == 1
      {:ok, reset_pm} = PlanMode.reset(pm)
      assert reset_pm.rejected_count == 1
    end

    test "reset then re-enter plan mode works" do
      {:ok, pm} =
        PlanMode.new("plan_001")
        |> PlanMode.enter_plan_mode()
        |> then(fn {:ok, pm} -> PlanMode.draft_generated(pm) end)
        |> then(fn {:ok, pm} -> PlanMode.reject(pm) end)
        |> then(fn {:ok, pm} -> PlanMode.reset(pm) end)
        |> then(fn {:ok, pm} -> PlanMode.enter_plan_mode(pm) end)

      assert PlanMode.state(pm) == :planning
    end
  end

  # ── Rejected count tracking ───────────────────────────────────────────

  describe "rejected_count" do
    test "increments on rejection" do
      {:ok, pm} =
        PlanMode.new()
        |> PlanMode.enter_plan_mode()
        |> then(fn {:ok, pm} -> PlanMode.draft_generated(pm) end)
        |> then(fn {:ok, pm} -> PlanMode.reject(pm) end)

      assert pm.rejected_count == 1
    end

    test "increments across multiple rejection cycles" do
      pm =
        PlanMode.new()
        |> then(fn pm ->
          {:ok, pm} = PlanMode.enter_plan_mode(pm)
          {:ok, pm} = PlanMode.draft_generated(pm)
          {:ok, pm} = PlanMode.reject(pm)
          pm
        end)
        |> then(fn pm ->
          {:ok, pm} = PlanMode.reset(pm)
          {:ok, pm} = PlanMode.enter_plan_mode(pm)
          {:ok, pm} = PlanMode.draft_generated(pm)
          {:ok, pm} = PlanMode.reject(pm)
          pm
        end)

      assert pm.rejected_count == 2
    end
  end

  # ── Action guidance strings ───────────────────────────────────────────

  describe "check_action/2 guidance" do
    test "guidance for write in planning mentions finishing the draft" do
      {:ok, pm} = PlanMode.enter_plan_mode(PlanMode.new())
      {:blocked, _reason, guidance} = PlanMode.check_action(pm, :write)
      assert guidance =~ "planning"
    end

    test "guidance for write in waiting_for_approval mentions approval" do
      {:ok, pm} = full_draft()
      {:blocked, _reason, guidance} = PlanMode.check_action(pm, :write)
      assert guidance =~ "approv"
    end

    test "all blocked permissions produce non-empty guidance" do
      {:ok, pm} = PlanMode.enter_plan_mode(PlanMode.new())

      for perm <- PlanMode.mutating_permissions() ++ [:shell_read] do
        {:blocked, reason, guidance} = PlanMode.check_action(pm, perm)
        assert is_binary(reason) and reason != "", "reason for #{perm} should not be empty"
        assert is_binary(guidance) and guidance != "", "guidance for #{perm} should not be empty"
      end
    end

    test "idle state returns :ok for all permissions" do
      pm = PlanMode.new()

      all_perms =
        PlanMode.mutating_permissions() ++ PlanMode.read_only_permissions() ++ [:shell_read]

      for perm <- all_perms do
        assert :ok = PlanMode.check_action(pm, perm)
      end
    end
  end

  # ── Helper predicates ─────────────────────────────────────────────────

  describe "read_only_discovery_allowed?/1" do
    test "returns true during planning and waiting_for_approval" do
      {:ok, planning} = PlanMode.enter_plan_mode(PlanMode.new())
      {:ok, waiting} = full_draft()

      assert PlanMode.read_only_discovery_allowed?(planning)
      assert PlanMode.read_only_discovery_allowed?(waiting)
    end

    test "returns true in approved, executing, verifying, completed" do
      {:ok, approved} = full_approve()
      {:ok, executing} = full_execute()
      {:ok, verifying} = full_verify()
      {:ok, completed} = full_complete()

      assert PlanMode.read_only_discovery_allowed?(approved)
      assert PlanMode.read_only_discovery_allowed?(executing)
      assert PlanMode.read_only_discovery_allowed?(verifying)
      assert PlanMode.read_only_discovery_allowed?(completed)
    end

    test "returns false in rejected and failed" do
      {:ok, rejected} = full_reject()
      {:ok, failed} = full_fail()

      refute PlanMode.read_only_discovery_allowed?(rejected)
      refute PlanMode.read_only_discovery_allowed?(failed)
    end
  end

  describe "mutations_blocked?/1" do
    test "returns true during planning and waiting_for_approval" do
      {:ok, planning} = PlanMode.enter_plan_mode(PlanMode.new())
      {:ok, waiting} = full_draft()

      assert PlanMode.mutations_blocked?(planning)
      assert PlanMode.mutations_blocked?(waiting)
    end

    test "returns false after approval" do
      {:ok, approved} = full_approve()
      refute PlanMode.mutations_blocked?(approved)
    end
  end

  # ── Cancel from planning ─────────────────────────────────────────────

  describe "cancel from planning" do
    test "returns to idle" do
      {:ok, pm} = PlanMode.enter_plan_mode(PlanMode.new())
      assert {:ok, %PlanMode{state: :idle}} = PlanMode.cancel(pm)
    end

    test "cannot cancel from waiting_for_approval" do
      {:ok, pm} = full_draft()
      assert {:error, :invalid_transition} = PlanMode.cancel(pm)
    end
  end

  # ════════════════════════════════════════════════════════════════════════
  # Test helpers
  # ════════════════════════════════════════════════════════════════════════

  defp full_draft(plan_id \\ nil) do
    PlanMode.new(plan_id)
    |> PlanMode.enter_plan_mode()
    |> then(fn {:ok, pm} -> PlanMode.draft_generated(pm) end)
  end

  defp full_approve(plan_id \\ nil) do
    full_draft(plan_id)
    |> then(fn {:ok, pm} -> PlanMode.approve(pm) end)
  end

  defp full_execute(plan_id \\ nil) do
    full_approve(plan_id)
    |> then(fn {:ok, pm} -> PlanMode.start_execution(pm) end)
  end

  defp full_verify(plan_id \\ nil) do
    full_execute(plan_id)
    |> then(fn {:ok, pm} -> PlanMode.start_verification(pm) end)
  end

  defp full_complete(plan_id \\ nil) do
    full_verify(plan_id)
    |> then(fn {:ok, pm} -> PlanMode.complete(pm) end)
  end

  defp full_reject(plan_id \\ nil) do
    full_draft(plan_id)
    |> then(fn {:ok, pm} -> PlanMode.reject(pm) end)
  end

  defp full_fail(plan_id \\ nil) do
    full_execute(plan_id)
    |> then(fn {:ok, pm} -> PlanMode.fail(pm) end)
  end
end
