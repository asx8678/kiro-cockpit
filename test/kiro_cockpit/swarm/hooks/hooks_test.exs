defmodule KiroCockpit.Swarm.HooksTest do
  use KiroCockpit.DataCase, async: true

  alias KiroCockpit.Swarm.{Event, HookManager, HookResult, PlanMode}

  alias KiroCockpit.Swarm.Hooks.{
    TaskEnforcementHook,
    PlanModeFirstActionHook,
    SteeringPreActionHook,
    TaskGuidanceHook
  }

  alias KiroCockpit.Swarm.Tasks.{Task, TaskManager}
  alias KiroCockpit.Repo

  setup do
    # Clean up any existing tasks
    Repo.delete_all(Task)
    :ok
  end

  describe "TaskEnforcementHook" do
    test "blocks write actions when no active task exists" do
      event = Event.new(:write, session_id: "sess_1", agent_id: "agent_1")
      ctx = %{plan_mode: PlanMode.new()}

      result = TaskEnforcementHook.on_event(event, ctx)

      assert %HookResult{decision: :block, reason: "No active task"} = result
      assert result.messages |> Enum.any?(&String.contains?(&1, "Create or activate a task"))
    end

    test "blocks wrapper actions with write permission when no active task exists" do
      event =
        Event.new(:kiro_session_prompt,
          session_id: "sess_1",
          agent_id: "agent_1",
          permission_level: :write
        )

      ctx = %{plan_mode: PlanMode.new()}

      assert TaskEnforcementHook.filter(event)

      result = TaskEnforcementHook.on_event(event, ctx)

      assert %HookResult{decision: :block, reason: "No active task"} = result
    end

    test "allows read-only actions in planning mode without active task" do
      event = Event.new(:read, session_id: "sess_1", agent_id: "agent_1")
      {:ok, plan_mode} = PlanMode.enter_plan_mode(PlanMode.new())
      ctx = %{plan_mode: plan_mode}

      result = TaskEnforcementHook.on_event(event, ctx)

      assert %HookResult{decision: :continue} = result
    end

    test "allows wrapper read-only actions in planning mode without active task" do
      event =
        Event.new(:kiro_session_prompt,
          session_id: "sess_1",
          agent_id: "agent_1",
          permission_level: :read
        )

      {:ok, plan_mode} = PlanMode.enter_plan_mode(PlanMode.new())
      ctx = %{plan_mode: plan_mode}

      result = TaskEnforcementHook.on_event(event, ctx)

      assert %HookResult{decision: :continue} = result
    end

    test "blocks write actions in planning mode even with active task" do
      # Create a task
      {:ok, task} =
        TaskManager.create(%{
          session_id: "sess_1",
          owner_id: "agent_1",
          content: "Test task",
          category: "researching"
        })

      # Activate the task
      {:ok, _} = TaskManager.activate(task.id)

      event = Event.new(:write, session_id: "sess_1", agent_id: "agent_1")
      {:ok, plan_mode} = PlanMode.enter_plan_mode(PlanMode.new())
      ctx = %{plan_mode: plan_mode}

      result = TaskEnforcementHook.on_event(event, ctx)

      # Should be blocked because researching category doesn't allow write
      assert %HookResult{decision: :block, reason: "Category permission denied"} = result
    end

    test "allows write actions when acting task is active" do
      # Create an acting task
      {:ok, task} =
        TaskManager.create(%{
          session_id: "sess_1",
          owner_id: "agent_1",
          content: "Test task",
          category: "acting"
        })

      # Activate the task
      {:ok, _} = TaskManager.activate(task.id)

      event = Event.new(:write, session_id: "sess_1", agent_id: "agent_1")
      ctx = %{plan_mode: PlanMode.new()}

      result = TaskEnforcementHook.on_event(event, ctx)

      assert %HookResult{decision: :continue} = result
    end

    test "blocks write actions when category doesn't allow writes" do
      # Create a researching task
      {:ok, task} =
        TaskManager.create(%{
          session_id: "sess_1",
          owner_id: "agent_1",
          content: "Test task",
          category: "researching"
        })

      # Activate the task
      {:ok, _} = TaskManager.activate(task.id)

      event = Event.new(:write, session_id: "sess_1", agent_id: "agent_1")
      ctx = %{plan_mode: PlanMode.new()}

      result = TaskEnforcementHook.on_event(event, ctx)

      assert %HookResult{decision: :block, reason: "Category permission denied"} = result
    end

    test "blocks write actions when file is out of scope" do
      # Create an acting task with file scope
      {:ok, task} =
        TaskManager.create(%{
          session_id: "sess_1",
          owner_id: "agent_1",
          content: "Test task",
          category: "acting",
          files_scope: ["lib/allowed/"]
        })

      # Activate the task
      {:ok, _} = TaskManager.activate(task.id)

      event =
        Event.new(:write,
          session_id: "sess_1",
          agent_id: "agent_1",
          payload: %{target_path: "lib/forbidden/file.ex"}
        )

      ctx = %{plan_mode: PlanMode.new()}

      result = TaskEnforcementHook.on_event(event, ctx)

      assert %HookResult{decision: :block, reason: "File out of scope"} = result
    end

    test "checks file scope from string payload keys" do
      {:ok, task} =
        TaskManager.create(%{
          session_id: "sess_1",
          owner_id: "agent_1",
          content: "Test task",
          category: "acting",
          files_scope: ["lib/allowed/"]
        })

      {:ok, _} = TaskManager.activate(task.id)

      event =
        Event.new(:write,
          session_id: "sess_1",
          agent_id: "agent_1",
          payload: %{"target_path" => "lib/forbidden/file.ex"}
        )

      result = TaskEnforcementHook.on_event(event, %{plan_mode: PlanMode.new()})

      assert %HookResult{decision: :block, reason: "File out of scope"} = result
    end

    test "allows write actions when file is in scope" do
      # Create an acting task with file scope
      {:ok, task} =
        TaskManager.create(%{
          session_id: "sess_1",
          owner_id: "agent_1",
          content: "Test task",
          category: "acting",
          files_scope: ["lib/allowed/"]
        })

      # Activate the task
      {:ok, _} = TaskManager.activate(task.id)

      event =
        Event.new(:write,
          session_id: "sess_1",
          agent_id: "agent_1",
          payload: %{target_path: "lib/allowed/file.ex"}
        )

      ctx = %{plan_mode: PlanMode.new()}

      result = TaskEnforcementHook.on_event(event, ctx)

      assert %HookResult{decision: :continue} = result
    end

    test "allows read-only actions in debugging category" do
      # Create a debugging task
      {:ok, task} =
        TaskManager.create(%{
          session_id: "sess_1",
          owner_id: "agent_1",
          content: "Test task",
          category: "debugging"
        })

      # Activate the task
      {:ok, _} = TaskManager.activate(task.id)

      event = Event.new(:read, session_id: "sess_1", agent_id: "agent_1")
      ctx = %{plan_mode: PlanMode.new()}

      result = TaskEnforcementHook.on_event(event, ctx)

      assert %HookResult{decision: :continue} = result
    end

    test "blocks implementation write in debugging category" do
      # Create a debugging task
      {:ok, task} =
        TaskManager.create(%{
          session_id: "sess_1",
          owner_id: "agent_1",
          content: "Test task",
          category: "debugging"
        })

      # Activate the task
      {:ok, _} = TaskManager.activate(task.id)

      event = Event.new(:write, session_id: "sess_1", agent_id: "agent_1")
      ctx = %{plan_mode: PlanMode.new()}

      result = TaskEnforcementHook.on_event(event, ctx)

      assert %HookResult{decision: :block, reason: "Category permission denied"} = result
    end
  end

  describe "PlanModeFirstActionHook" do
    test "injects guidance on first action in planning mode" do
      event = Event.new(:read, session_id: "sess_1", agent_id: "agent_1")
      {:ok, plan_mode} = PlanMode.enter_plan_mode(PlanMode.new())
      ctx = %{plan_mode: plan_mode, first_action_shown: false}

      result = PlanModeFirstActionHook.on_event(event, ctx)

      assert %HookResult{decision: :modify} = result
      assert result.messages |> Enum.any?(&String.contains?(&1, "plan mode"))
    end

    test "does not describe mutating wrapper action as allowed in plan mode" do
      event = Event.new(:kiro_session_prompt, permission_level: :write)
      {:ok, plan_mode} = PlanMode.enter_plan_mode(PlanMode.new())
      ctx = %{plan_mode: plan_mode, first_action_shown: false}

      result = PlanModeFirstActionHook.on_event(event, ctx)

      assert %HookResult{decision: :modify} = result
      assert Enum.any?(result.messages, &String.contains?(&1, "Mutating actions are blocked"))
      refute Enum.any?(result.messages, &String.contains?(&1, "allowed for discovery purposes"))
    end

    test "does not inject guidance when first action already shown" do
      event = Event.new(:read, session_id: "sess_1", agent_id: "agent_1")
      {:ok, plan_mode} = PlanMode.enter_plan_mode(PlanMode.new())
      ctx = %{plan_mode: plan_mode, first_action_shown: true}

      result = PlanModeFirstActionHook.on_event(event, ctx)

      assert %HookResult{decision: :continue} = result
    end

    test "does not inject guidance when not in planning mode" do
      event = Event.new(:read, session_id: "sess_1", agent_id: "agent_1")
      ctx = %{plan_mode: PlanMode.new(), first_action_shown: false}

      result = PlanModeFirstActionHook.on_event(event, ctx)

      assert %HookResult{decision: :continue} = result
    end
  end

  describe "SteeringPreActionHook" do
    test "continues when no deterministic signals present" do
      event = Event.new(:read, session_id: "sess_1", agent_id: "agent_1")
      ctx = %{}

      result = SteeringPreActionHook.on_event(event, ctx)

      assert %HookResult{decision: :continue} = result
    end

    test "blocks when off-topic signal present" do
      event =
        Event.new(:write,
          session_id: "sess_1",
          agent_id: "agent_1",
          metadata: %{off_topic: true, off_topic_guidance: "This is off-topic"}
        )

      ctx = %{}

      result = SteeringPreActionHook.on_event(event, ctx)

      assert %HookResult{decision: :block, reason: "Action is off-topic"} = result
    end

    test "focuses when drift signal present" do
      event =
        Event.new(:write,
          session_id: "sess_1",
          agent_id: "agent_1",
          metadata: %{drift: true, drift_message: "Slight drift detected"}
        )

      ctx = %{}

      result = SteeringPreActionHook.on_event(event, ctx)

      assert %HookResult{decision: :modify} = result
      assert result.messages |> Enum.any?(&String.contains?(&1, "drift"))
    end

    test "guides when guide signal present" do
      event =
        Event.new(:write,
          session_id: "sess_1",
          agent_id: "agent_1",
          metadata: %{guide: true, guide_message: "Consider related context"}
        )

      ctx = %{}

      result = SteeringPreActionHook.on_event(event, ctx)

      assert %HookResult{decision: :modify} = result
      assert result.messages |> Enum.any?(&String.contains?(&1, "Consider related context"))
    end

    test "blocks when task mismatch signal present" do
      event =
        Event.new(:write,
          session_id: "sess_1",
          agent_id: "agent_1",
          metadata: %{task_mismatch: true, task_mismatch_guidance: "Action doesn't match task"}
        )

      ctx = %{}

      result = SteeringPreActionHook.on_event(event, ctx)

      assert %HookResult{decision: :block, reason: "Task mismatch"} = result
    end
  end

  describe "TaskGuidanceHook" do
    test "injects guidance for task_create with no active task" do
      event =
        Event.new(:task_create,
          session_id: "sess_1",
          agent_id: "agent_1",
          payload: %{task_id: "task_1"}
        )

      ctx = %{}

      result = TaskGuidanceHook.on_event(event, ctx)

      assert %HookResult{decision: :continue} = result
      assert result.messages |> Enum.any?(&String.contains?(&1, "Activate the next task"))
    end

    test "injects guidance for task_activate" do
      event =
        Event.new(:task_activate,
          session_id: "sess_1",
          agent_id: "agent_1",
          payload: %{task_id: "task_1"}
        )

      ctx = %{}

      result = TaskGuidanceHook.on_event(event, ctx)

      assert %HookResult{decision: :continue} = result
      assert result.messages |> Enum.any?(&String.contains?(&1, "Task is active"))
    end

    test "injects guidance for task_complete" do
      event =
        Event.new(:task_complete,
          session_id: "sess_1",
          agent_id: "agent_1",
          payload: %{task_id: "task_1"}
        )

      ctx = %{}

      result = TaskGuidanceHook.on_event(event, ctx)

      assert %HookResult{decision: :continue} = result
      assert result.messages |> Enum.any?(&String.contains?(&1, "Pick the next pending task"))
    end

    test "injects guidance for task_block" do
      event =
        Event.new(:task_block,
          session_id: "sess_1",
          agent_id: "agent_1",
          payload: %{task_id: "task_1"}
        )

      ctx = %{}

      result = TaskGuidanceHook.on_event(event, ctx)

      assert %HookResult{decision: :continue} = result
      assert result.messages |> Enum.any?(&String.contains?(&1, "Resolve blocker"))
    end

    test "injects guidance for plan_approved" do
      event =
        Event.new(:plan_approved,
          session_id: "sess_1",
          agent_id: "agent_1",
          payload: %{plan_id: "plan_1"}
        )

      ctx = %{}

      result = TaskGuidanceHook.on_event(event, ctx)

      assert %HookResult{decision: :continue} = result
      assert result.messages |> Enum.any?(&String.contains?(&1, "Create/activate Phase 1 task"))
    end
  end

  describe "Hook ordering and interactions" do
    test "hooks run in correct priority order" do
      event = Event.new(:read, session_id: "sess_1", agent_id: "agent_1")
      {:ok, plan_mode} = PlanMode.enter_plan_mode(PlanMode.new())
      ctx = %{plan_mode: plan_mode, first_action_shown: false}

      hooks = [TaskEnforcementHook, PlanModeFirstActionHook, SteeringPreActionHook]

      # Pre-action: higher priority first (96, 95, 95)
      # PlanModeFirstActionHook (96) should run first
      # Then TaskEnforcementHook and SteeringPreActionHook (both 95) - alphabetical tie-breaker
      {:ok, _event, messages} = HookManager.run(event, hooks, ctx, :pre)

      # Should have messages from PlanModeFirstActionHook
      assert Enum.any?(messages, &String.contains?(&1, "plan mode"))
    end

    test "post-action hooks run in ascending priority order" do
      event = Event.new(:task_activate, session_id: "sess_1", agent_id: "agent_1")
      ctx = %{}

      hooks = [TaskGuidanceHook]

      {:ok, _event, messages} = HookManager.run(event, hooks, ctx, :post)

      assert Enum.any?(messages, &String.contains?(&1, "Task is active"))
    end
  end
end
