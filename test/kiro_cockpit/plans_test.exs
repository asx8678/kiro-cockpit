defmodule KiroCockpit.PlansTest do
  use KiroCockpit.DataCase

  alias KiroCockpit.Plans
  alias KiroCockpit.Plans.{Plan, PlanStep, PlanEvent}

  defp default_opts do
    %{
      plan_markdown: "# Plan",
      execution_prompt: "Execute",
      raw_model_output: %{},
      project_snapshot_hash: "hash123"
    }
  end

  describe "create_plan/5" do
    test "creates a draft plan with steps and a creation event" do
      session_id = "sess_test123"
      user_request = "Add OAuth authentication"
      mode = :nano

      steps = [
        %{
          phase_number: 1,
          step_number: 1,
          title: "Research OAuth providers",
          details: "Look up popular OAuth providers",
          files: %{"README.md" => "read"},
          permission_level: "read",
          status: "planned"
        },
        %{
          phase_number: 1,
          step_number: 2,
          title: "Implement callback",
          details: "Add OAuth callback route",
          files: %{"lib/kiro_cockpit_web/router.ex" => "write"},
          permission_level: "write",
          status: "planned"
        }
      ]

      assert {:ok, %Plan{status: "draft"} = plan} =
               Plans.create_plan(
                 session_id,
                 user_request,
                 mode,
                 steps,
                 Map.put(default_opts(), :raw_model_output, %{"foo" => "bar"})
               )

      assert plan.session_id == session_id
      assert plan.mode == "nano"
      assert plan.user_request == user_request
      assert plan.plan_markdown == "# Plan"
      assert plan.execution_prompt == "Execute"
      assert plan.raw_model_output == %{"foo" => "bar"}
      assert plan.project_snapshot_hash == "hash123"

      # Preloaded associations
      assert length(plan.plan_steps) == 2
      assert length(plan.plan_events) == 1
      assert hd(plan.plan_events).event_type == "created"
    end

    test "validates mode and status" do
      assert {:error, changeset} =
               Plans.create_plan("sess", "request", :invalid_mode, [], default_opts())

      assert %{mode: ["is invalid"]} = errors_on(changeset)
    end

    test "persists plan steps with subagent permission_level" do
      session_id = "sess_subagent"

      steps = [
        %{
          phase_number: 1,
          step_number: 1,
          title: "Delegate task to subagent",
          details: "Run subagent",
          files: %{},
          permission_level: "subagent",
          status: "planned"
        }
      ]

      assert {:ok, plan} =
               Plans.create_plan(session_id, "request", :nano, steps, default_opts())

      assert length(plan.plan_steps) == 1
      assert hd(plan.plan_steps).permission_level == "subagent"
    end

    test "persists plan steps with memory_write permission_level" do
      session_id = "sess_memory_write"

      steps = [
        %{
          phase_number: 1,
          step_number: 1,
          title: "Promote findings to memory",
          details: "Save memory",
          files: %{},
          permission_level: "memory_write",
          status: "planned"
        }
      ]

      assert {:ok, plan} =
               Plans.create_plan(session_id, "request", :nano, steps, default_opts())

      assert length(plan.plan_steps) == 1
      assert hd(plan.plan_steps).permission_level == "memory_write"
    end
  end

  describe "get_plan/1" do
    test "returns a plan with preloaded steps and events" do
      session_id = "sess_test456"
      {:ok, plan} = Plans.create_plan(session_id, "request", :nano, [], default_opts())

      fetched = Plans.get_plan(plan.id)
      assert fetched.id == plan.id
      assert length(fetched.plan_steps) == 0
      assert length(fetched.plan_events) == 1
    end

    test "returns nil for missing plan" do
      assert nil == Plans.get_plan(Ecto.UUID.generate())
    end
  end

  describe "list_plans/2" do
    test "lists plans for a session" do
      session_id = "sess_test789"
      {:ok, _plan1} = Plans.create_plan(session_id, "request1", :nano, [], default_opts())
      {:ok, _plan2} = Plans.create_plan(session_id, "request2", :nano_deep, [], default_opts())

      # Different session
      {:ok, _} = Plans.create_plan("other_session", "request3", :nano, [], default_opts())

      plans = Plans.list_plans(session_id)
      assert length(plans) == 2
      assert Enum.all?(plans, &(&1.session_id == session_id))

      # Filter by status
      draft_plans = Plans.list_plans(session_id, status: "draft")
      assert length(draft_plans) == 2
    end
  end

  describe "approve_plan/1" do
    test "transitions draft to approved and adds event" do
      {:ok, plan} = Plans.create_plan("sess", "request", :nano, [], default_opts())
      assert plan.status == "draft"

      assert {:ok, approved_plan} = Plans.approve_plan(plan.id)
      assert approved_plan.status == "approved"
      assert approved_plan.approved_at != nil
      assert length(approved_plan.plan_events) == 2
      assert Enum.any?(approved_plan.plan_events, &(&1.event_type == "approved"))
    end

    test "fails to approve a non-draft plan" do
      {:ok, plan} = Plans.create_plan("sess", "request", :nano, [], default_opts())
      {:ok, _} = Plans.approve_plan(plan.id)
      # Already approved, approve again should fail
      assert {:error, :invalid_transition} = Plans.approve_plan(plan.id)
    end

    test "fails to approve a rejected plan" do
      {:ok, plan} = Plans.create_plan("sess", "request", :nano, [], default_opts())
      {:ok, _} = Plans.reject_plan(plan.id)
      assert {:error, :invalid_transition} = Plans.approve_plan(plan.id)
    end

    test "returns not_found for a missing plan" do
      assert {:error, :not_found} = Plans.approve_plan(Ecto.UUID.generate())
    end
  end

  describe "approve_plan_with_tasks/4" do
    alias KiroCockpit.Swarm.Tasks.TaskManager

    test "atomically approves plan, creates tasks, and activates first task" do
      # Create a plan with steps
      steps = [
        %{
          phase_number: 1,
          step_number: 1,
          title: "Step 1",
          details: "First step details",
          files: %{"file1.ex" => "read"},
          permission_level: "read",
          status: "planned"
        },
        %{
          phase_number: 1,
          step_number: 2,
          title: "Step 2",
          details: "Second step details",
          files: %{"file2.ex" => "write"},
          permission_level: "write",
          status: "planned"
        }
      ]

      {:ok, plan} = Plans.create_plan("sess-atomic", "request", :nano, steps, default_opts())
      assert plan.status == "draft"
      assert length(plan.plan_steps) == 2

      # Approve with task creation
      assert {:ok, %{plan: approved_plan, tasks: tasks, active_task: active_task}} =
               Plans.approve_plan_with_tasks(plan.id, "kiro-executor", TaskManager)

      # Verify plan is approved
      assert approved_plan.status == "approved"
      assert approved_plan.approved_at != nil

      # Verify tasks were created
      assert length(tasks) == 2

      # Verify exactly one task is active
      assert active_task != nil
      assert active_task.status == "in_progress"

      # Verify tasks exist in the database
      db_tasks = TaskManager.list("sess-atomic", plan_id: plan.id)
      assert length(db_tasks) == 2

      # Verify one is in_progress
      in_progress_count = Enum.count(db_tasks, &(&1.status == "in_progress"))
      assert in_progress_count == 1
    end

    test "gracefully handles plan with no steps, approving without tasks" do
      {:ok, plan} = Plans.create_plan("sess-empty", "request", :nano, [], default_opts())
      assert plan.plan_steps == []

      # Should succeed with empty tasks and nil active_task (graceful handling)
      assert {:ok, %{plan: approved_plan, tasks: [], active_task: nil}} =
               Plans.approve_plan_with_tasks(plan.id, "kiro-executor", TaskManager)

      # Verify plan is approved (no rollback - graceful success)
      assert approved_plan.status == "approved"

      # Verify no tasks were created
      db_tasks = TaskManager.list("sess-empty", plan_id: plan.id)
      assert db_tasks == []
    end

    test "fails to approve non-draft plan" do
      steps = [
        %{
          phase_number: 1,
          step_number: 1,
          title: "Step 1",
          details: "Details",
          permission_level: "read",
          status: "planned"
        }
      ]

      {:ok, plan} = Plans.create_plan("sess", "request", :nano, steps, default_opts())
      {:ok, _} = Plans.approve_plan(plan.id)

      # Should fail with invalid_transition
      assert {:error, :invalid_transition} =
               Plans.approve_plan_with_tasks(plan.id, "kiro-executor", TaskManager)
    end
  end

  describe "reject_plan/2" do
    test "transitions to rejected with reason" do
      {:ok, plan} = Plans.create_plan("sess", "request", :nano, [], default_opts())
      assert {:ok, rejected_plan} = Plans.reject_plan(plan.id, "user cancelled")
      assert rejected_plan.status == "rejected"
      assert length(rejected_plan.plan_events) == 2
      event = Enum.find(rejected_plan.plan_events, &(&1.event_type == "rejected"))
      assert event.payload == %{"reason" => "user cancelled"}
    end

    test "fails to reject a terminal plan" do
      {:ok, plan} = Plans.create_plan("sess", "request", :nano, [], default_opts())
      {:ok, _} = Plans.reject_plan(plan.id)
      # plan is now rejected (terminal)
      assert {:error, :invalid_transition} = Plans.reject_plan(plan.id)
    end

    test "returns not_found for a missing plan" do
      assert {:error, :not_found} = Plans.reject_plan(Ecto.UUID.generate())
    end
  end

  describe "revise_plan/3" do
    test "supersedes old plan and creates new draft" do
      {:ok, old_plan} = Plans.create_plan("sess", "original request", :nano, [], default_opts())
      assert old_plan.status == "draft"

      assert {:ok, new_plan} = Plans.revise_plan(old_plan.id, "revised request")
      assert new_plan.status == "draft"
      assert new_plan.user_request == "revised request"
      assert new_plan.session_id == old_plan.session_id
      assert new_plan.mode == old_plan.mode

      # Old plan should be superseded
      old = Plans.get_plan(old_plan.id)
      assert old.status == "superseded"

      # New plan has a revision event
      assert length(new_plan.plan_events) == 1
      assert hd(new_plan.plan_events).event_type == "revised"
    end

    test "returns not_found for a missing plan" do
      assert {:error, :not_found} = Plans.revise_plan(Ecto.UUID.generate(), "revise")
    end
  end

  describe "update_status/3" do
    test "transitions approved plans to running" do
      {:ok, plan} = Plans.create_plan("sess", "request", :nano, [], default_opts())
      {:ok, approved_plan} = Plans.approve_plan(plan.id)

      assert {:ok, running_plan} = Plans.update_status(approved_plan.id, "running")
      assert running_plan.status == "running"
      assert Enum.any?(running_plan.plan_events, &(&1.event_type == "running"))
    end

    test "transitions running plans to completed" do
      {:ok, plan} = Plans.create_plan("sess", "request", :nano, [], default_opts())
      {:ok, approved_plan} = Plans.approve_plan(plan.id)
      {:ok, running_plan} = Plans.update_status(approved_plan.id, "running")

      assert {:ok, completed_plan} = Plans.update_status(running_plan.id, "completed")
      assert completed_plan.status == "completed"
      assert completed_plan.completed_at != nil
    end

    test "transitions running plans to failed with payload" do
      {:ok, plan} = Plans.create_plan("sess", "request", :nano, [], default_opts())
      {:ok, approved_plan} = Plans.approve_plan(plan.id)
      {:ok, running_plan} = Plans.update_status(approved_plan.id, "running")

      assert {:ok, failed_plan} =
               Plans.update_status(running_plan.id, "failed", %{"error" => "oops"})

      assert failed_plan.status == "failed"
      event = Enum.find(failed_plan.plan_events, &(&1.event_type == "failed"))
      assert event.payload == %{"error" => "oops"}
    end

    test "allows superseding a plan" do
      {:ok, plan} = Plans.create_plan("sess", "request", :nano, [], default_opts())

      assert {:ok, superseded_plan} = Plans.update_status(plan.id, "superseded")
      assert superseded_plan.status == "superseded"
    end

    test "fails to transition to invalid status" do
      {:ok, plan} = Plans.create_plan("sess", "request", :nano, [], default_opts())
      assert {:error, :invalid_transition} = Plans.update_status(plan.id, "draft")
    end

    test "fails to run a draft plan" do
      {:ok, plan} = Plans.create_plan("sess", "request", :nano, [], default_opts())
      assert {:error, :invalid_transition} = Plans.update_status(plan.id, "running")
    end

    test "fails to reopen a completed plan as running" do
      {:ok, plan} = Plans.create_plan("sess", "request", :nano, [], default_opts())
      {:ok, approved_plan} = Plans.approve_plan(plan.id)
      {:ok, running_plan} = Plans.update_status(approved_plan.id, "running")
      {:ok, completed_plan} = Plans.update_status(running_plan.id, "completed")

      assert {:error, :invalid_transition} = Plans.update_status(completed_plan.id, "running")
    end

    test "returns not_found for a missing plan" do
      assert {:error, :not_found} = Plans.update_status(Ecto.UUID.generate(), "running")
    end
  end

  describe "constraints" do
    test "invalid mode is rejected" do
      changeset =
        Plan.changeset(%Plan{}, %{
          session_id: "sess",
          mode: "invalid",
          status: "draft",
          user_request: "req",
          plan_markdown: "md",
          execution_prompt: "ex",
          project_snapshot_hash: "hash"
        })

      assert %{mode: ["is invalid"]} = errors_on(changeset)
    end

    test "invalid status is rejected" do
      changeset =
        Plan.changeset(%Plan{}, %{
          session_id: "sess",
          mode: "nano",
          status: "invalid",
          user_request: "req",
          plan_markdown: "md",
          execution_prompt: "ex",
          project_snapshot_hash: "hash"
        })

      assert %{status: ["is invalid"]} = errors_on(changeset)
    end

    test "invalid permission_level is rejected" do
      changeset =
        PlanStep.changeset(%PlanStep{}, %{
          plan_id: Ecto.UUID.generate(),
          phase_number: 1,
          step_number: 1,
          title: "test",
          permission_level: "invalid",
          status: "planned"
        })

      assert %{permission_level: ["is invalid"]} = errors_on(changeset)
    end

    test "invalid plan step status is rejected" do
      changeset =
        PlanStep.changeset(%PlanStep{}, %{
          plan_id: Ecto.UUID.generate(),
          phase_number: 1,
          step_number: 1,
          title: "test",
          permission_level: "read",
          status: "invalid"
        })

      assert %{status: ["is invalid"]} = errors_on(changeset)
    end

    test "invalid event_type is rejected" do
      changeset =
        PlanEvent.changeset(%PlanEvent{}, %{
          plan_id: Ecto.UUID.generate(),
          event_type: "invalid",
          created_at: DateTime.utc_now()
        })

      assert %{event_type: ["is invalid"]} = errors_on(changeset)
    end

    test "unique constraint on plan_steps (plan_id, phase_number, step_number)" do
      {:ok, plan} = Plans.create_plan("sess", "req", :nano, [], default_opts())
      # Insert a step manually
      step = %{
        plan_id: plan.id,
        phase_number: 1,
        step_number: 1,
        title: "step1",
        permission_level: "read",
        status: "planned"
      }

      {:ok, _} = Repo.insert(PlanStep.changeset(%PlanStep{}, step))

      # Try to insert another step with same plan, phase, step_number
      assert {:error, changeset} = Repo.insert(PlanStep.changeset(%PlanStep{}, step))
      assert {:plan_id, {"has already been taken", _}} = hd(changeset.errors)
    end
  end

  describe "stale_plan_hash" do
    test "returns the project snapshot hash" do
      {:ok, plan} =
        Plans.create_plan(
          "sess",
          "req",
          :nano,
          [],
          Map.put(default_opts(), :project_snapshot_hash, "abc123")
        )

      assert Plans.stale_plan_hash(plan.id) == "abc123"
    end

    test "returns nil for missing plan" do
      assert nil == Plans.stale_plan_hash(Ecto.UUID.generate())
    end
  end

  describe "run_plan/2" do
    setup do
      dir =
        System.tmp_dir!()
        |> Path.join("plans_run_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "mix.exs"), "defmodule Test.Project do end")
      File.write!(Path.join(dir, "README.md"), "# Test")

      on_exit(fn -> File.rm_rf!(dir) end)

      {:ok, project_dir: dir}
    end

    test "runs an approved plan when not stale", %{project_dir: dir} do
      {:ok, plan} =
        Plans.create_plan(
          "sess",
          "req",
          :nano,
          [],
          Map.put(default_opts(), :project_snapshot_hash, compute_hash(dir))
        )

      {:ok, approved} = Plans.approve_plan(plan.id)

      assert {:ok, running} = Plans.run_plan(approved.id, project_dir: dir)
      assert running.status == "running"
    end

    test "refuses to run a stale plan via boundary when hooks enabled", %{project_dir: dir} do
      {:ok, plan} =
        Plans.create_plan(
          "sess_stale_run",
          "req",
          :nano,
          [],
          default_opts()
        )

      {:ok, approved} = Plans.approve_plan(plan.id)

      # The project snapshot_hash is "hash123" which won't match the real dir.
      # With hooks enabled, staleness is checked inside ActionBoundary via
      # TaskEnforcementHook, which blocks the run and persists a Bronze trace.
      assert {:error, {:swarm_blocked, reason}} =
               Plans.run_plan(approved.id,
                 project_dir: dir,
                 swarm_hooks: true,
                 pre_hooks: [KiroCockpit.Swarm.Hooks.TaskEnforcementHook],
                 post_hooks: []
               )

      assert reason =~ "Stale plan"

      # Plan must NOT transition to running
      refreshed = Plans.get_plan(approved.id)
      assert refreshed.status == "approved"

      # Bronze trace should be persisted for the blocked attempt
      events = KiroCockpit.Swarm.Events.list_by_session("sess_stale_run", limit: 10)
      assert length(events) >= 1
      trace = List.first(events)
      assert trace.event_type == "hook_trace"
      assert trace.hook_results["outcome"] == "blocked"
      assert trace.hook_results["action"] == "nano_plan_run"
    end

    test "run_plan stale check skipped when hooks disabled (default test config)", %{
      project_dir: dir
    } do
      {:ok, plan} =
        Plans.create_plan(
          "sess_stale_skip",
          "req",
          :nano,
          [],
          default_opts()
        )

      {:ok, approved} = Plans.approve_plan(plan.id)

      # With hooks disabled (default test config), staleness check is skipped
      # and the plan transitions to running directly
      assert {:ok, running} = Plans.run_plan(approved.id, project_dir: dir)
      assert running.status == "running"
    end

    test "refuses to run when project_dir is nil" do
      {:ok, plan} =
        Plans.create_plan(
          "sess",
          "req",
          :nano,
          [],
          default_opts()
        )

      {:ok, approved} = Plans.approve_plan(plan.id)

      assert {:error, :stale_plan_unknown} = Plans.run_plan(approved.id, [])
    end

    test "refuses to run a draft plan", %{project_dir: dir} do
      {:ok, plan} =
        Plans.create_plan(
          "sess",
          "req",
          :nano,
          [],
          default_opts()
        )

      assert {:error, :invalid_transition} = Plans.run_plan(plan.id, project_dir: dir)
    end

    test "refuses to run a not-found plan", %{project_dir: dir} do
      assert {:error, :not_found} =
               Plans.run_plan(Ecto.UUID.generate(), project_dir: dir)
    end

    test "refuses to run when context builder fails via boundary", %{project_dir: dir} do
      {:ok, plan} =
        Plans.create_plan(
          "sess_cb_fail",
          "req",
          :nano,
          [],
          Map.put(default_opts(), :project_snapshot_hash, compute_hash(dir))
        )

      {:ok, approved} = Plans.approve_plan(plan.id)

      defmodule PlansTestBrokenBuilder do
        @moduledoc false
        def build(_opts), do: {:error, :simulated_failure}
      end

      # With hooks enabled, the broken context builder triggers stale_plan_unknown
      # inside the boundary, which TaskEnforcementHook blocks.
      assert {:error, {:swarm_blocked, reason}} =
               Plans.run_plan(approved.id,
                 project_dir: dir,
                 swarm_hooks: true,
                 context_builder_module: PlansTestBrokenBuilder,
                 pre_hooks: [KiroCockpit.Swarm.Hooks.TaskEnforcementHook],
                 post_hooks: []
               )

      assert reason =~ "Stale plan"

      # Plan should NOT be running
      refreshed = Plans.get_plan(approved.id)
      assert refreshed.status == "approved"
    end

    test "run_plan boundary uses nano-planner default agent_id when none provided", %{
      project_dir: dir
    } do
      {:ok, plan} =
        Plans.create_plan(
          "sess_default_agent",
          "req",
          :nano,
          [],
          Map.put(default_opts(), :project_snapshot_hash, compute_hash(dir))
        )

      {:ok, approved} = Plans.approve_plan(plan.id)

      # Run with swarm hooks enabled — agent_id defaults to "nano-planner"
      assert {:ok, running} =
               Plans.run_plan(approved.id,
                 project_dir: dir,
                 swarm_hooks: true
               )

      assert running.status == "running"

      # Verify Bronze trace has nano-planner as the top-level agent_id
      events = KiroCockpit.Swarm.Events.list_by_session("sess_default_agent", limit: 10)
      assert length(events) >= 1
      trace = List.first(events)
      assert trace.event_type == "hook_trace"
      assert trace.agent_id == "nano-planner"
    end

    test "run_plan boundary uses explicit agent_id when provided", %{
      project_dir: dir
    } do
      {:ok, plan} =
        Plans.create_plan(
          "sess_explicit",
          "req",
          :nano,
          [],
          Map.put(default_opts(), :project_snapshot_hash, compute_hash(dir))
        )

      {:ok, approved} = Plans.approve_plan(plan.id)

      assert {:ok, running} =
               Plans.run_plan(approved.id,
                 project_dir: dir,
                 swarm_hooks: true,
                 agent_id: "custom-agent"
               )

      assert running.status == "running"

      events = KiroCockpit.Swarm.Events.list_by_session("sess_explicit", limit: 10)
      trace = List.first(events)
      assert trace.agent_id == "custom-agent"
    end
  end

  defp compute_hash(project_dir) do
    {:ok, snapshot} = KiroCockpit.NanoPlanner.ContextBuilder.build(project_dir: project_dir)
    snapshot.hash
  end
end
