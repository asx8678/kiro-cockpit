defmodule KiroCockpit.Swarm.Tasks.TaskGuidancePostHookTest do
  @moduledoc """
  Phase 3: Task lifecycle guidance post-hook integration tests.

  Proves that task_create, task_activate, task_complete, task_block, and
  plan_approved each produce a Bronze hook_trace containing task_guidance
  result/message when hooks are enabled.

  These tests enable swarm_action_hooks_enabled via Application.put_env
  because the test config disables it by default.
  """

  use KiroCockpit.DataCase, async: true

  alias KiroCockpit.Swarm.Events
  alias KiroCockpit.Swarm.Tasks.TaskManager

  # -----------------------------------------------------------------
  # Setup: enable hooks for these tests
  # -----------------------------------------------------------------

  setup do
    # Enable hooks for the duration of each test
    Application.put_env(:kiro_cockpit, :swarm_action_hooks_enabled, true)

    on_exit(fn ->
      Application.put_env(:kiro_cockpit, :swarm_action_hooks_enabled, false)
    end)

    :ok
  end

  # -----------------------------------------------------------------
  # Helpers
  # -----------------------------------------------------------------

  @task_attrs %{
    session_id: "post_hook_test_session",
    content: "Post-hook test task",
    owner_id: "test-agent"
  }

  defp unique_session_id do
    "post_hook_#{System.unique_integer([:positive])}"
  end

  defp create_task(session_id \\ nil) do
    sid = session_id || unique_session_id()

    {:ok, task} =
      TaskManager.create(%{
        session_id: sid,
        content: "Task in #{sid}",
        owner_id: "test-agent"
      })

    task
  end

  defp find_guidance_trace(session_id) do
    Events.list_by_session(session_id, limit: 50)
    |> Enum.filter(&(&1.event_type == "hook_trace"))
    |> Enum.find(fn event ->
      hook_results = event.hook_results || %{}
      results_list = hook_results["hook_results"] || []

      Enum.any?(results_list, fn hr ->
        hr["hook"] == "task_guidance" && hr["decision"] == "continue"
      end)
    end)
  end

  defp extract_guidance_message(trace) do
    hook_results = trace.hook_results["hook_results"] || []

    guidance_hook =
      Enum.find(hook_results, fn hr ->
        hr["hook"] == "task_guidance"
      end)

    guidance_hook["guidance"]
  end

  # -----------------------------------------------------------------
  # Task create — post-hook Bronze trace
  # -----------------------------------------------------------------

  describe "task_create post-hook guidance trace" do
    test "create/1 produces a hook_trace with task_guidance when no active task" do
      sid = unique_session_id()
      {:ok, task} = TaskManager.create(%{@task_attrs | session_id: sid})

      trace = find_guidance_trace(sid)
      assert trace, "Expected a hook_trace with task_guidance for :task_create"

      assert trace.hook_results["action"] == "task_create"
      assert trace.hook_results["phase"] == "post"
      assert trace.session_id == sid
      assert trace.task_id == task.id
      assert trace.agent_id == "test-agent"

      guidance_msg = extract_guidance_message(trace)
      assert guidance_msg =~ "Activate the next task"
    end

    test "create/1 produces hook_trace with empty guidance when active task exists in lane" do
      sid = unique_session_id()

      # Create and activate first task
      task1 = create_task(sid)
      {:ok, _} = TaskManager.activate(task1.id)

      # Create second task in same lane
      {:ok, task2} = TaskManager.create(%{@task_attrs | session_id: sid})

      # Find the trace for the SECOND task (not the first)
      traces =
        Events.list_by_session(sid, limit: 50)
        |> Enum.filter(fn e ->
          e.event_type == "hook_trace" &&
            e.task_id == task2.id &&
            e.hook_results["action"] == "task_create"
        end)

      assert length(traces) >= 1, "Expected a task_create hook_trace for task2"
      trace = List.first(traces)

      guidance_msg = extract_guidance_message(trace)
      # With an active task, guidance is nil (no messages)
      assert guidance_msg == nil
    end
  end

  # -----------------------------------------------------------------
  # Task create_all — post-hook per task
  # -----------------------------------------------------------------

  describe "create_all/1 post-hook guidance trace" do
    test "fires one hook_trace per task in the batch" do
      sid = unique_session_id()

      attrs_list = [
        Map.merge(@task_attrs, %{session_id: sid, content: "Batch 1", sequence: 1}),
        Map.merge(@task_attrs, %{session_id: sid, content: "Batch 2", sequence: 2}),
        Map.merge(@task_attrs, %{session_id: sid, content: "Batch 3", sequence: 3})
      ]

      {:ok, tasks} = TaskManager.create_all(attrs_list)
      assert length(tasks) == 3

      # Each task should have a corresponding hook_trace
      traces =
        Events.list_by_session(sid, limit: 50)
        |> Enum.filter(&(&1.event_type == "hook_trace"))
        |> Enum.filter(fn event ->
          hook_results = event.hook_results || %{}
          results_list = hook_results["hook_results"] || []

          Enum.any?(results_list, fn hr ->
            hr["hook"] == "task_guidance" && hr["decision"] == "continue"
          end)
        end)

      # At least 3 task_create traces (one per task)
      task_create_traces =
        Enum.filter(traces, fn t ->
          t.hook_results["action"] == "task_create"
        end)

      assert length(task_create_traces) >= 3,
             "Expected at least 3 task_create hook_traces, got #{length(task_create_traces)}"
    end
  end

  # -----------------------------------------------------------------
  # Task activate — post-hook Bronze trace
  # -----------------------------------------------------------------

  describe "task_activate post-hook guidance trace" do
    test "activate/1 produces a hook_trace with activation guidance" do
      sid = unique_session_id()
      task = create_task(sid)

      {:ok, activated} = TaskManager.activate(task.id)

      # Look for the task_activate trace (there may also be a task_create trace)
      traces =
        Events.list_by_session(sid, limit: 50)
        |> Enum.filter(&(&1.event_type == "hook_trace"))
        |> Enum.filter(fn event ->
          event.hook_results["action"] == "task_activate"
        end)

      assert length(traces) >= 1, "Expected a task_activate hook_trace"

      activate_trace = List.first(traces)
      assert activate_trace.task_id == activated.id
      assert activate_trace.agent_id == "test-agent"
      assert activate_trace.hook_results["phase"] == "post"

      guidance_msg = extract_guidance_message(activate_trace)
      assert guidance_msg =~ "Task is active"
      assert guidance_msg =~ "Proceed within its category"
    end

    test "idempotent activate still produces hook_trace" do
      sid = unique_session_id()
      task = create_task(sid)

      {:ok, _} = TaskManager.activate(task.id)
      {:ok, _} = TaskManager.activate(task.id)

      traces =
        Events.list_by_session(sid, limit: 50)
        |> Enum.filter(fn e ->
          e.event_type == "hook_trace" && e.hook_results["action"] == "task_activate"
        end)

      # At least 2 activate traces (idempotent)
      assert length(traces) >= 2
    end
  end

  # -----------------------------------------------------------------
  # Task complete — post-hook Bronze trace
  # -----------------------------------------------------------------

  describe "task_complete post-hook guidance trace" do
    test "complete/1 produces a hook_trace with completion guidance" do
      sid = unique_session_id()
      task = create_task(sid)
      {:ok, _} = TaskManager.activate(task.id)

      {:ok, completed} = TaskManager.complete(task.id)

      traces =
        Events.list_by_session(sid, limit: 50)
        |> Enum.filter(fn e ->
          e.event_type == "hook_trace" && e.hook_results["action"] == "task_complete"
        end)

      assert length(traces) >= 1, "Expected a task_complete hook_trace"

      complete_trace = List.first(traces)
      assert complete_trace.task_id == completed.id
      assert complete_trace.hook_results["phase"] == "post"

      guidance_msg = extract_guidance_message(complete_trace)
      assert guidance_msg =~ "Pick the next pending task"
    end
  end

  # -----------------------------------------------------------------
  # Task block — post-hook Bronze trace
  # -----------------------------------------------------------------

  describe "task_block post-hook guidance trace" do
    test "block/1 produces a hook_trace with block guidance" do
      sid = unique_session_id()
      task = create_task(sid)
      {:ok, _} = TaskManager.activate(task.id)

      {:ok, blocked} = TaskManager.block(task.id)

      traces =
        Events.list_by_session(sid, limit: 50)
        |> Enum.filter(fn e ->
          e.event_type == "hook_trace" && e.hook_results["action"] == "task_block"
        end)

      assert length(traces) >= 1, "Expected a task_block hook_trace"

      block_trace = List.first(traces)
      assert block_trace.task_id == blocked.id
      assert block_trace.hook_results["phase"] == "post"

      guidance_msg = extract_guidance_message(block_trace)
      assert guidance_msg =~ "Resolve blocker"
    end
  end

  # -----------------------------------------------------------------
  # Plan approved — post-hook Bronze trace
  # -----------------------------------------------------------------

  describe "plan_approved post-hook guidance trace" do
    test "approve_plan/1 produces a hook_trace with plan_approved guidance" do
      sid = unique_session_id()

      {:ok, plan} =
        KiroCockpit.Plans.create_plan(
          sid,
          "test plan for guidance",
          :nano,
          [],
          plan_markdown: "# Plan",
          execution_prompt: "do the thing",
          project_snapshot_hash: "abc123"
        )

      {:ok, _approved} = KiroCockpit.Plans.approve_plan(plan.id)

      traces =
        Events.list_by_session(sid, limit: 50)
        |> Enum.filter(fn e ->
          e.event_type == "hook_trace" && e.hook_results["action"] == "plan_approved"
        end)

      assert length(traces) >= 1, "Expected a plan_approved hook_trace"

      approved_trace = List.first(traces)
      assert approved_trace.plan_id == plan.id
      assert approved_trace.agent_id == "nano-planner"
      assert approved_trace.hook_results["phase"] == "post"

      guidance_msg = extract_guidance_message(approved_trace)
      assert guidance_msg =~ "Create/activate Phase 1 task"
    end

    test "approve_plan/2 accepts custom agent_id" do
      sid = unique_session_id()

      {:ok, plan} =
        KiroCockpit.Plans.create_plan(
          sid,
          "test plan custom agent",
          :nano,
          [],
          plan_markdown: "# Plan",
          execution_prompt: "do the thing",
          project_snapshot_hash: "abc123"
        )

      {:ok, _approved} = KiroCockpit.Plans.approve_plan(plan.id, agent_id: "custom-agent")

      traces =
        Events.list_by_session(sid, limit: 50)
        |> Enum.filter(fn e ->
          e.event_type == "hook_trace" && e.hook_results["action"] == "plan_approved"
        end)

      assert length(traces) >= 1

      approved_trace = List.first(traces)
      assert approved_trace.agent_id == "custom-agent"
    end
  end

  # -----------------------------------------------------------------
  # Return shape preservation
  # -----------------------------------------------------------------

  describe "return shape preservation" do
    test "create/1 still returns {:ok, Task} with virtual guidance" do
      sid = unique_session_id()
      {:ok, task} = TaskManager.create(%{@task_attrs | session_id: sid})

      assert is_binary(task.id)
      assert task.guidance == ["Activate the next task with status=in_progress before execution."]
    end

    test "activate/1 still returns {:ok, Task} with virtual guidance" do
      task = create_task()
      {:ok, activated} = TaskManager.activate(task.id)

      assert activated.status == "in_progress"

      assert activated.guidance == [
               "Task is active. Proceed within its category and permission scope."
             ]
    end

    test "complete/1 still returns {:ok, Task} with virtual guidance" do
      task = create_task()
      {:ok, _} = TaskManager.activate(task.id)
      {:ok, completed} = TaskManager.complete(task.id)

      assert completed.status == "completed"
      assert completed.guidance == ["Pick the next pending task or run final verification."]
    end

    test "block/1 still returns {:ok, Task} with virtual guidance" do
      task = create_task()
      {:ok, _} = TaskManager.activate(task.id)
      {:ok, blocked} = TaskManager.block(task.id)

      assert blocked.status == "blocked"
      assert blocked.guidance == ["Resolve blocker, revise plan, or ask user."]
    end
  end

  # -----------------------------------------------------------------
  # Hooks disabled — no Bronze trace, no crash
  # -----------------------------------------------------------------

  describe "hooks disabled — graceful degradation" do
    setup do
      Application.put_env(:kiro_cockpit, :swarm_action_hooks_enabled, false)
      :ok
    end

    test "create/1 succeeds without Bronze trace when hooks disabled" do
      sid = unique_session_id()
      {:ok, task} = TaskManager.create(%{@task_attrs | session_id: sid})

      # Virtual guidance still works
      assert task.guidance == ["Activate the next task with status=in_progress before execution."]

      # No Bronze trace
      traces =
        Events.list_by_session(sid, limit: 10)
        |> Enum.filter(&(&1.event_type == "hook_trace"))

      assert traces == []
    end

    test "lifecycle operations don't crash when hooks disabled" do
      task = create_task()
      {:ok, activated} = TaskManager.activate(task.id)
      assert activated.status == "in_progress"

      {:ok, completed} = TaskManager.complete(task.id)
      assert completed.status == "completed"
    end
  end

  # -----------------------------------------------------------------
  # Full lifecycle — multiple transitions, multiple traces
  # -----------------------------------------------------------------

  describe "full lifecycle produces traces for each transition" do
    test "create → activate → block → activate → complete produces 5 hook_traces" do
      sid = unique_session_id()

      # 1. Create
      {:ok, task} = TaskManager.create(%{@task_attrs | session_id: sid})

      # 2. Activate
      {:ok, _} = TaskManager.activate(task.id)

      # 3. Block
      {:ok, _} = TaskManager.block(task.id)

      # 4. Re-activate
      {:ok, _} = TaskManager.activate(task.id)

      # 5. Complete
      {:ok, _} = TaskManager.complete(task.id)

      # All traces with task_guidance
      guidance_traces =
        Events.list_by_session(sid, limit: 100)
        |> Enum.filter(fn e ->
          e.event_type == "hook_trace" &&
            e.hook_results["action"] in [
              "task_create",
              "task_activate",
              "task_complete",
              "task_block"
            ]
        end)

      # 1 create + 3 activates (initial + block→reactivate + ... idempotent) + 1 block + 1 complete
      # Minimum: create(1) + activate(1) + block(1) + activate(1) + complete(1) = 5
      assert length(guidance_traces) >= 5,
             "Expected at least 5 lifecycle hook_traces, got #{length(guidance_traces)}"

      # Verify action names are present
      action_names = Enum.map(guidance_traces, & &1.hook_results["action"]) |> Enum.uniq()
      assert "task_create" in action_names
      assert "task_activate" in action_names
      assert "task_block" in action_names
      assert "task_complete" in action_names
    end
  end
end
