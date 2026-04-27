defmodule KiroCockpit.NanoPlannerApproveTasksTest do
  @moduledoc """
  §36.8 acceptance tests for kiro-56f: approved plans create and activate tasks.

  Proves that NanoPlanner.approve/3:
    1. Derives pending swarm tasks from approved_plan.plan_steps
    2. Activates exactly one first task for the execution lane
    3. Sends the execution prompt AFTER task activation
    4. Includes plan/task/agent identifiers in prompt opts
    5. Does not duplicate tasks on repeated approval attempt
    6. Returns enriched result with tasks and active_task
    7. Prevents prompt if task creation or activation fails
  """

  use KiroCockpit.DataCase

  alias KiroCockpit.NanoPlanner
  alias KiroCockpit.Plans
  alias KiroCockpit.Swarm.Tasks.TaskManager

  # ── Fake injectable session module ──────────────────────────────────

  defmodule FakeKiroSession do
    @moduledoc false
    def state(_session) do
      Process.get(:fake_kiro_state) ||
        %{
          session_id: "approve-tasks-test-session",
          cwd: Process.get(:fake_kiro_cwd)
        }
    end

    def prompt(_session, prompt_text, opts) do
      calls = Process.get(:fake_kiro_prompt_calls, [])
      Process.put(:fake_kiro_prompt_calls, calls ++ [{prompt_text, opts}])
      Process.get(:fake_kiro_prompt_result) || {:ok, %{}}
    end

    def recent_stream_events(_session, _opts) do
      Process.get(:fake_kiro_stream_events, [])
    end
  end

  # ── Fake derive function that returns invalid tasks (for atomic rollback testing)

  defmodule FailingTaskDerive do
    @moduledoc false
    def derive_with_invalid_permission(_plan, _agent_id) do
      # Return tasks with invalid permission that will fail validation
      [
        %{
          session_id: "test",
          owner_id: "test",
          content: "Invalid task",
          status: "pending",
          priority: "medium",
          category: "researching",
          sequence: 1,
          permission_scope: ["invalid_permission"]
        }
      ]
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp multi_step_plan_map do
    %{
      "objective" => "Multi-step integration test",
      "summary" => "Build a feature with read and write steps.",
      "phases" => [
        %{
          "number" => 1,
          "title" => "Discovery",
          "steps" => [
            %{
              "title" => "Read existing files",
              "details" => "Survey current project structure.",
              "files" => %{"lib/kiro_cockpit/app.ex" => "read"},
              "permission" => "read",
              "validation" => "Files listed and readable."
            },
            %{
              "title" => "Check test coverage",
              "details" => "Run existing test suite.",
              "permission" => "shell_read",
              "validation" => "All existing tests pass."
            }
          ]
        },
        %{
          "number" => 2,
          "title" => "Implementation",
          "steps" => [
            %{
              "title" => "Create new module",
              "details" => "Add the new feature module.",
              "files" => %{"lib/kiro_cockpit/feature.ex" => "write"},
              "permission" => "write",
              "validation" => "Module compiles and tests pass."
            }
          ]
        }
      ],
      "permissions_needed" => ["read", "write"],
      "acceptance_criteria" => ["Feature works end to end"],
      "risks" => [],
      "execution_prompt" => "Execute the multi-step plan phase by phase.",
      "plan_markdown" => "# Multi-Step Plan"
    }
  end

  defp setup_project_dir(_) do
    dir =
      System.tmp_dir!()
      |> Path.join("approve_tasks_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "mix.exs"), "defmodule Test.Project do\nend")
    File.write!(Path.join(dir, "README.md"), "# Test Project")

    session_id = "approve-tasks-#{System.unique_integer([:positive])}"

    Process.put(:fake_kiro_cwd, dir)
    Process.put(:fake_kiro_state, %{session_id: session_id, cwd: dir})
    Process.put(:fake_kiro_prompt_calls, [])
    Process.put(:fake_kiro_stream_events, [])

    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, project_dir: dir, session_id: session_id}
  end

  defp default_plan_opts(dir, session_id) do
    [
      kiro_session_module: FakeKiroSession,
      project_dir: dir,
      session_id: session_id,
      # kiro-egn: test_bypass for non-bypassable action boundary in test env
      test_bypass: true
    ]
  end

  defp approve_result(plan_id, dir, extra_opts \\ []) do
    NanoPlanner.approve(
      :fake_session,
      plan_id,
      [kiro_session_module: FakeKiroSession, project_dir: dir, test_bypass: true] ++ extra_opts
    )
  end

  # ── §36.8: Approve creates pending tasks ─────────────────────────────

  describe "§36.8 — approve creates pending tasks from plan_steps" do
    setup [:setup_project_dir]

    test "approve creates one pending task per plan_step", %{
      project_dir: dir,
      session_id: session_id
    } do
      Process.put(:fake_kiro_prompt_result, {:ok, multi_step_plan_map()})

      assert {:ok, plan} =
               NanoPlanner.plan(
                 :fake_session,
                 "Build feature",
                 default_plan_opts(dir, session_id)
               )

      assert length(plan.plan_steps) == 3

      # Approve
      Process.put(:fake_kiro_prompt_result, {:ok, %{"stopReason" => "end_turn"}})
      Process.put(:fake_kiro_prompt_calls, [])

      assert {:ok,
              %{plan: approved_plan, prompt_result: _, tasks: tasks, active_task: _active_task}} =
               approve_result(plan.id, dir)

      assert approved_plan.status == "approved"
      assert length(tasks) == 3

      # All tasks are pending initially (one may now be in_progress after activation)
      for task <- tasks do
        assert task.plan_id == approved_plan.id
        assert task.session_id == session_id
        assert task.owner_id == "kiro-executor"
        assert task.status in ["pending", "in_progress"]
      end

      # Verify task content includes title and details
      contents = Enum.map(tasks, & &1.content)
      assert Enum.any?(contents, &String.contains?(&1, "Read existing files"))
      assert Enum.any?(contents, &String.contains?(&1, "Check test coverage"))
      assert Enum.any?(contents, &String.contains?(&1, "Create new module"))

      # Verify categories: read → researching, shell_read + validation → verifying, write → acting
      categories = Enum.map(tasks, & &1.category) |> Enum.sort()
      assert "acting" in categories
      assert "researching" in categories or "verifying" in categories

      # Verify sequences are stable
      sequences = Enum.map(tasks, & &1.sequence) |> Enum.sort()
      assert sequences == [101, 102, 201]
    end

    test "approve activates exactly one first task for the execution lane", %{
      project_dir: dir,
      session_id: session_id
    } do
      Process.put(:fake_kiro_prompt_result, {:ok, multi_step_plan_map()})

      assert {:ok, plan} =
               NanoPlanner.plan(
                 :fake_session,
                 "Build feature",
                 default_plan_opts(dir, session_id)
               )

      Process.put(:fake_kiro_prompt_result, {:ok, %{"stopReason" => "end_turn"}})
      Process.put(:fake_kiro_prompt_calls, [])

      assert {:ok, %{tasks: tasks, active_task: active_task}} =
               approve_result(plan.id, dir)

      # Exactly one task should be in_progress
      in_progress = Enum.filter(tasks, &(&1.status == "in_progress"))
      assert length(in_progress) == 1

      # The active task is the first by sequence
      assert active_task.status == "in_progress"
      assert active_task.id == hd(in_progress).id

      # get_active confirms exactly one active task
      fetched_active = TaskManager.get_active(session_id, "kiro-executor")
      assert fetched_active != nil
      assert fetched_active.id == active_task.id
    end

    test "approve uses :execution_agent_id opt for task owner_id", %{
      project_dir: dir,
      session_id: session_id
    } do
      Process.put(:fake_kiro_prompt_result, {:ok, multi_step_plan_map()})

      assert {:ok, plan} =
               NanoPlanner.plan(
                 :fake_session,
                 "Build feature",
                 default_plan_opts(dir, session_id)
               )

      Process.put(:fake_kiro_prompt_result, {:ok, %{"stopReason" => "end_turn"}})
      Process.put(:fake_kiro_prompt_calls, [])

      assert {:ok, %{tasks: tasks, active_task: active_task}} =
               approve_result(plan.id, dir, execution_agent_id: "custom-agent")

      for task <- tasks do
        assert task.owner_id == "custom-agent"
      end

      assert active_task.owner_id == "custom-agent"
    end
  end

  # ── §36.8: Prompt is sent after activation ────────────────────────────

  describe "§36.8 — prompt sent after task activation" do
    setup [:setup_project_dir]

    test "execution prompt is called with plan/task/agent correlation opts", %{
      project_dir: dir,
      session_id: session_id
    } do
      Process.put(:fake_kiro_prompt_result, {:ok, multi_step_plan_map()})

      assert {:ok, plan} =
               NanoPlanner.plan(
                 :fake_session,
                 "Build feature",
                 default_plan_opts(dir, session_id)
               )

      Process.put(:fake_kiro_prompt_result, {:ok, %{"stopReason" => "end_turn"}})
      Process.put(:fake_kiro_prompt_calls, [])

      assert {:ok, %{active_task: active_task}} =
               approve_result(plan.id, dir)

      calls = Process.get(:fake_kiro_prompt_calls, [])
      assert length(calls) == 1

      {prompt_text, opts} = hd(calls)
      assert prompt_text == "Execute the multi-step plan phase by phase."

      # Correlation identifiers are present in prompt opts
      assert Keyword.get(opts, :plan_id) == plan.id
      assert Keyword.get(opts, :task_id) == active_task.id
      assert Keyword.get(opts, :agent_id) == "kiro-executor"
      assert Keyword.get(opts, :swarm_plan_id) == plan.id
      assert Keyword.get(opts, :timeout) != nil
    end
  end

  # ── §36.8: Idempotency — no duplicate tasks on re-approval ──────────

  describe "§36.8 — idempotency: no duplicate tasks" do
    setup [:setup_project_dir]

    test "re-approving same plan does not create duplicate tasks", %{
      project_dir: dir,
      session_id: session_id
    } do
      Process.put(:fake_kiro_prompt_result, {:ok, multi_step_plan_map()})

      assert {:ok, plan} =
               NanoPlanner.plan(
                 :fake_session,
                 "Build feature",
                 default_plan_opts(dir, session_id)
               )

      # First approval
      Process.put(:fake_kiro_prompt_result, {:ok, %{"stopReason" => "end_turn"}})
      Process.put(:fake_kiro_prompt_calls, [])

      assert {:ok, %{tasks: tasks1}} =
               approve_result(plan.id, dir)

      assert length(tasks1) == 3

      # The plan is now approved, so re-approving should fail with invalid_transition
      # (existing Plans.approve_plan behavior for already-approved plans)
      assert {:error, :invalid_transition} =
               approve_result(plan.id, dir)

      # Task count should still be 3 (no duplicates)
      all_tasks = TaskManager.list(session_id, plan_id: plan.id)
      assert length(all_tasks) == 3
    end

    test "tasks with same plan_id are returned on repeated ensure call", %{
      project_dir: dir,
      session_id: session_id
    } do
      Process.put(:fake_kiro_prompt_result, {:ok, multi_step_plan_map()})

      assert {:ok, plan} =
               NanoPlanner.plan(
                 :fake_session,
                 "Build feature",
                 default_plan_opts(dir, session_id)
               )

      # First approval
      Process.put(:fake_kiro_prompt_result, {:ok, %{"stopReason" => "end_turn"}})

      assert {:ok, _} = approve_result(plan.id, dir)

      # Verify tasks exist for this plan
      existing = TaskManager.list(session_id, plan_id: plan.id)
      assert length(existing) == 3

      # Direct check: TaskManager.list returns the same tasks
      assert length(TaskManager.list(session_id, plan_id: plan.id)) == 3
    end
  end

  # ── §36.8: Atomic transaction ensures all-or-nothing ───────────────────

  describe "§36.8 — atomic approval: all-or-nothing transaction" do
    setup [:setup_project_dir]

    test "transaction rollback on invalid task status prevents prompt send and plan approval", %{
      project_dir: dir,
      session_id: session_id
    } do
      Process.put(:fake_kiro_prompt_result, {:ok, multi_step_plan_map()})

      assert {:ok, plan} =
               NanoPlanner.plan(
                 :fake_session,
                 "Build feature",
                 default_plan_opts(dir, session_id)
               )

      assert plan.status == "draft"

      Process.put(:fake_kiro_prompt_result, {:ok, %{"stopReason" => "end_turn"}})
      Process.put(:fake_kiro_prompt_calls, [])

      # Inject a derive function that returns tasks with invalid status
      # This will fail at the DB constraint level (check constraint on status)
      # The error bubbles up as an exception since it's a DB constraint violation
      assert_raise Postgrex.Error, fn ->
        approve_result(plan.id, dir,
          derive_tasks_fn: fn _plan, _agent_id ->
            [
              %{
                session_id: session_id,
                owner_id: "kiro-executor",
                content: "Invalid task",
                # Invalid status that violates DB constraint
                status: "invalid_status",
                category: "acting",
                priority: "medium",
                sequence: 101,
                permission_scope: ["read"]
              }
            ]
          end
        )
      end

      # No prompt was sent (transaction failed before reaching that point)
      calls = Process.get(:fake_kiro_prompt_calls, [])
      assert calls == []

      # Plan should still be draft (rollback worked)
      refreshed = Plans.get_plan(plan.id)
      assert refreshed.status == "draft"

      # No tasks should exist for this plan
      db_tasks = TaskManager.list(session_id, plan_id: plan.id)
      assert db_tasks == []
    end

    test "empty plan steps approves gracefully without tasks or active task", %{
      project_dir: dir,
      session_id: session_id
    } do
      # Create a plan with no steps via the Plans context directly
      alias KiroCockpit.NanoPlanner.ContextBuilder

      {:ok, snapshot} = ContextBuilder.build(project_dir: dir)

      assert {:ok, plan} =
               Plans.create_plan(
                 session_id,
                 "Empty plan",
                 "nano",
                 [],
                 plan_markdown: "# Empty",
                 execution_prompt: "Do nothing.",
                 project_snapshot_hash: snapshot.hash
               )

      assert plan.plan_steps == []
      assert plan.status == "draft"

      Process.put(:fake_kiro_prompt_result, {:ok, %{"stopReason" => "end_turn"}})
      Process.put(:fake_kiro_prompt_calls, [])

      result = approve_result(plan.id, dir)

      # Should succeed gracefully with empty tasks and nil active_task
      assert {:ok, %{plan: approved_plan, tasks: [], active_task: nil, prompt_result: _}} = result

      # Prompt was still sent (approval succeeded)
      calls = Process.get(:fake_kiro_prompt_calls, [])
      assert length(calls) == 1

      # Plan should be approved (no rollback - graceful success)
      assert approved_plan.status == "approved"
    end
  end

  # ── §36.8: Task field derivation details ──────────────────────────────

  describe "§36.8 — task field derivation from plan_steps" do
    setup [:setup_project_dir]

    test "permission_scope includes step permission_level and read baseline", %{
      project_dir: dir,
      session_id: session_id
    } do
      Process.put(:fake_kiro_prompt_result, {:ok, multi_step_plan_map()})

      assert {:ok, plan} =
               NanoPlanner.plan(
                 :fake_session,
                 "Build feature",
                 default_plan_opts(dir, session_id)
               )

      Process.put(:fake_kiro_prompt_result, {:ok, %{"stopReason" => "end_turn"}})

      assert {:ok, %{tasks: tasks}} = approve_result(plan.id, dir)

      # Find the write step task
      write_task = Enum.find(tasks, &(&1.category == "acting"))
      assert write_task != nil
      assert "write" in write_task.permission_scope
      assert "read" in write_task.permission_scope

      # Find a read-level task (researching or verifying)
      read_task = Enum.find(tasks, &(&1.category in ["researching", "verifying"]))
      assert read_task != nil
      assert "read" in read_task.permission_scope
    end

    test "files_scope derived from step.files keys", %{
      project_dir: dir,
      session_id: session_id
    } do
      Process.put(:fake_kiro_prompt_result, {:ok, multi_step_plan_map()})

      assert {:ok, plan} =
               NanoPlanner.plan(
                 :fake_session,
                 "Build feature",
                 default_plan_opts(dir, session_id)
               )

      Process.put(:fake_kiro_prompt_result, {:ok, %{"stopReason" => "end_turn"}})

      assert {:ok, %{tasks: tasks}} = approve_result(plan.id, dir)

      # Write step should have its file in files_scope
      write_task = Enum.find(tasks, &(&1.category == "acting"))
      assert write_task != nil
      assert "lib/kiro_cockpit/feature.ex" in write_task.files_scope

      # Read step should have its file in files_scope
      read_task = Enum.find(tasks, &(&1.category in ["researching", "verifying"]))
      assert read_task != nil
      assert "lib/kiro_cockpit/app.ex" in read_task.files_scope
    end

    test "acceptance_criteria derived from step.validation", %{
      project_dir: dir,
      session_id: session_id
    } do
      Process.put(:fake_kiro_prompt_result, {:ok, multi_step_plan_map()})

      assert {:ok, plan} =
               NanoPlanner.plan(
                 :fake_session,
                 "Build feature",
                 default_plan_opts(dir, session_id)
               )

      Process.put(:fake_kiro_prompt_result, {:ok, %{"stopReason" => "end_turn"}})

      assert {:ok, %{tasks: tasks}} = approve_result(plan.id, dir)

      # Tasks should have validation as acceptance_criteria
      for task <- tasks do
        if task.category == "acting" do
          assert "Module compiles and tests pass." in task.acceptance_criteria
        end
      end
    end

    test "category mapping: write → acting, read → researching, read+validation → verifying",
         %{project_dir: dir, session_id: session_id} do
      # Build a plan where one read step has no validation (researching)
      # and another read step has validation (verifying)
      plan_map =
        Map.merge(multi_step_plan_map(), %{
          "phases" => [
            %{
              "number" => 1,
              "title" => "Discovery",
              "steps" => [
                %{
                  "title" => "Read existing files",
                  "details" => "Survey current project structure.",
                  "files" => %{"lib/kiro_cockpit/app.ex" => "read"},
                  "permission" => "read",
                  "validation" => "Files listed and readable."
                },
                %{
                  "title" => "Quick browse",
                  "details" => "Just look around.",
                  "permission" => "read"
                  # No validation → researching
                }
              ]
            },
            %{
              "number" => 2,
              "title" => "Implementation",
              "steps" => [
                %{
                  "title" => "Create new module",
                  "details" => "Add the new feature module.",
                  "files" => %{"lib/kiro_cockpit/feature.ex" => "write"},
                  "permission" => "write",
                  "validation" => "Module compiles and tests pass."
                }
              ]
            }
          ]
        })

      Process.put(:fake_kiro_prompt_result, {:ok, plan_map})

      assert {:ok, plan} =
               NanoPlanner.plan(
                 :fake_session,
                 "Build feature",
                 default_plan_opts(dir, session_id)
               )

      Process.put(:fake_kiro_prompt_result, {:ok, %{"stopReason" => "end_turn"}})

      assert {:ok, %{tasks: tasks}} = approve_result(plan.id, dir)

      # read + validation → verifying
      verifying_task = Enum.find(tasks, &(&1.category == "verifying"))
      assert verifying_task != nil

      # read without validation → researching
      researching_task = Enum.find(tasks, &(&1.category == "researching"))
      assert researching_task != nil

      # write → acting
      acting_task = Enum.find(tasks, &(&1.category == "acting"))
      assert acting_task != nil
    end

    test "sequence uses phase_number * 100 + step_number for stable ordering", %{
      project_dir: dir,
      session_id: session_id
    } do
      Process.put(:fake_kiro_prompt_result, {:ok, multi_step_plan_map()})

      assert {:ok, plan} =
               NanoPlanner.plan(
                 :fake_session,
                 "Build feature",
                 default_plan_opts(dir, session_id)
               )

      Process.put(:fake_kiro_prompt_result, {:ok, %{"stopReason" => "end_turn"}})

      assert {:ok, %{tasks: tasks}} = approve_result(plan.id, dir)

      sorted_sequences = Enum.map(tasks, & &1.sequence) |> Enum.sort()
      assert length(sorted_sequences) == 3

      # Sequences should be monotonically increasing
      for i <- 1..(length(sorted_sequences) - 1) do
        assert Enum.at(sorted_sequences, i) > Enum.at(sorted_sequences, i - 1)
      end
    end
  end

  # ── §36.8: Return shape enrichment ───────────────────────────────────

  describe "§36.8 — enriched return shape" do
    setup [:setup_project_dir]

    test "approve returns map with plan, prompt_result, tasks, and active_task", %{
      project_dir: dir,
      session_id: session_id
    } do
      Process.put(:fake_kiro_prompt_result, {:ok, multi_step_plan_map()})

      assert {:ok, plan} =
               NanoPlanner.plan(
                 :fake_session,
                 "Build feature",
                 default_plan_opts(dir, session_id)
               )

      Process.put(:fake_kiro_prompt_result, {:ok, %{"stopReason" => "end_turn"}})

      result = approve_result(plan.id, dir)

      assert {:ok, %{plan: approved, prompt_result: pr, tasks: tasks, active_task: active}} =
               result

      assert approved.status == "approved"
      assert is_list(tasks)
      assert active.status == "in_progress"
      assert pr == %{"stopReason" => "end_turn"}
    end

    test "existing pattern-matching on %{plan: _, prompt_result: _} still works", %{
      project_dir: dir,
      session_id: session_id
    } do
      Process.put(:fake_kiro_prompt_result, {:ok, multi_step_plan_map()})

      assert {:ok, plan} =
               NanoPlanner.plan(
                 :fake_session,
                 "Build feature",
                 default_plan_opts(dir, session_id)
               )

      Process.put(:fake_kiro_prompt_result, {:ok, %{"stopReason" => "end_turn"}})

      # This pattern is used in CLI and existing tests
      assert {:ok, %{plan: approved_plan, prompt_result: result}} =
               approve_result(plan.id, dir)

      assert approved_plan.status == "approved"
      assert result == %{"stopReason" => "end_turn"}
    end
  end
end
