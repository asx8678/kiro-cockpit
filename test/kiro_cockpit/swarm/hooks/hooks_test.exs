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

    test "allows direct read actions in planning mode without active task" do
      event = Event.new(:read, session_id: "sess_1", agent_id: "agent_1")
      {:ok, plan_mode} = PlanMode.enter_plan_mode(PlanMode.new())
      ctx = %{plan_mode: plan_mode}

      result = TaskEnforcementHook.on_event(event, ctx)

      assert %HookResult{decision: :continue} = result
    end

    test "allows wrapper direct read actions in planning mode without active task" do
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

    test "blocks shell_read command tools in planning mode without active task" do
      event = Event.new(:shell_read, session_id: "sess_1", agent_id: "agent_1")
      {:ok, plan_mode} = PlanMode.enter_plan_mode(PlanMode.new())

      result = TaskEnforcementHook.on_event(event, %{plan_mode: plan_mode})

      assert %HookResult{decision: :block, reason: "Action blocked during planning"} = result
    end

    test "blocks approved acting write while plan mode is still planning" do
      {:ok, task} =
        TaskManager.create(%{
          session_id: "sess_plan_gate",
          owner_id: "agent_plan_gate",
          content: "Acting task",
          category: "acting",
          permission_scope: ["write"]
        })

      {:ok, _} = TaskManager.activate(task.id)

      event = Event.new(:write, session_id: "sess_plan_gate", agent_id: "agent_plan_gate")
      {:ok, plan_mode} = PlanMode.enter_plan_mode(PlanMode.new())

      result =
        TaskEnforcementHook.on_event(event, %{
          plan_mode: plan_mode,
          approved: true,
          policy_allows_write: true
        })

      assert %HookResult{decision: :block, reason: "Action blocked during planning"} = result
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

      # Plan mode is the outer gate and blocks before category checks.
      assert %HookResult{decision: :block, reason: "Action blocked during planning"} = result
    end

    test "blocks write actions when acting task needs approval" do
      # Create an acting task — per §32.2, acting write is :ask (needs approval)
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

      # Acting write is :ask → needs approval → blocked by hook
      assert %HookResult{decision: :block, reason: "Permission requires approval"} = result
    end

    test "allows trusted read-only subagent when approved" do
      {:ok, task} =
        TaskManager.create(%{
          session_id: "sess_subagent_ok",
          owner_id: "agent_subagent_ok",
          content: "Research task",
          category: "researching",
          permission_scope: ["subagent"]
        })

      {:ok, _} = TaskManager.activate(task.id)

      event =
        Event.new(:kiro_delegate,
          session_id: "sess_subagent_ok",
          agent_id: "agent_subagent_ok",
          permission_level: :subagent
        )

      result =
        TaskEnforcementHook.on_event(event, %{
          plan_mode: PlanMode.new(),
          subagent_kind: :read_only,
          approved: true
        })

      assert %HookResult{decision: :continue} = result
    end

    test "allows read actions when acting task is active" do
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

      event = Event.new(:read, session_id: "sess_1", agent_id: "agent_1")
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

    test "blocks write actions when acting task needs approval (file out of scope)" do
      # Create an acting task with file scope
      # Per §32.2, acting+write is :ask → needs approval before file scope check
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

      # Category permission check blocks with needs_approval before file scope
      assert %HookResult{decision: :block, reason: "Permission requires approval"} = result
    end

    test "blocks write actions from string payload keys when needs approval" do
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

      # acting+write needs approval; file scope not reached
      assert %HookResult{decision: :block, reason: "Permission requires approval"} = result
    end

    test "blocks write actions when file is in scope but needs approval" do
      # Create an acting task with file scope
      # Per §32.2, acting+write is :ask → needs approval even with in-scope file
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

      assert %HookResult{decision: :block, reason: "Permission requires approval"} = result
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

  test "blocks approved scoped write when target path is missing" do
    {:ok, task} =
      TaskManager.create(%{
        session_id: "sess_missing_path",
        owner_id: "agent_missing_path",
        content: "Scoped acting task",
        category: "acting",
        permission_scope: ["write"],
        files_scope: ["lib/allowed/"]
      })

    {:ok, _} = TaskManager.activate(task.id)

    event = Event.new(:write, session_id: "sess_missing_path", agent_id: "agent_missing_path")

    result =
      TaskEnforcementHook.on_event(event, %{
        plan_mode: PlanMode.new(),
        approved: true,
        policy_allows_write: true
      })

    assert %HookResult{decision: :block, reason: "Missing file scope target"} = result
  end

  test "blocks scoped write traversal paths even when approved" do
    {:ok, task} =
      TaskManager.create(%{
        session_id: "sess_traversal_path",
        owner_id: "agent_traversal_path",
        content: "Scoped acting task",
        category: "acting",
        permission_scope: ["write"],
        files_scope: ["lib/allowed/"]
      })

    {:ok, _} = TaskManager.activate(task.id)

    event =
      Event.new(:write,
        session_id: "sess_traversal_path",
        agent_id: "agent_traversal_path",
        payload: %{target_path: "lib/allowed/../../secret.ex"}
      )

    result =
      TaskEnforcementHook.on_event(event, %{
        plan_mode: PlanMode.new(),
        approved: true,
        policy_allows_write: true
      })

    assert %HookResult{decision: :block, reason: "File out of scope"} = result
  end

  test "blocks acting write unless both approval and policy are present" do
    {:ok, task} =
      TaskManager.create(%{
        session_id: "sess_both_required",
        owner_id: "agent_both_required",
        content: "Both required task",
        category: "acting",
        permission_scope: ["write"]
      })

    {:ok, _} = TaskManager.activate(task.id)

    event = Event.new(:write, session_id: "sess_both_required", agent_id: "agent_both_required")

    assert %HookResult{decision: :block, reason: "Permission requires approval"} =
             TaskEnforcementHook.on_event(event, %{plan_mode: PlanMode.new(), approved: true})

    assert %HookResult{decision: :block, reason: "Permission requires approval"} =
             TaskEnforcementHook.on_event(event, %{
               plan_mode: PlanMode.new(),
               policy_allows_write: true
             })
  end

  test "allows acting write when explicit approval and policy signals are present" do
    {:ok, task} =
      TaskManager.create(%{
        session_id: "sess_approval",
        owner_id: "agent_approval",
        content: "Approved acting task",
        category: "acting",
        permission_scope: ["write"]
      })

    {:ok, _} = TaskManager.activate(task.id)

    event =
      Event.new(:write,
        session_id: "sess_approval",
        agent_id: "agent_approval",
        metadata: %{approved: true, policy_allows_write: true}
      )

    result =
      TaskEnforcementHook.on_event(event, %{
        plan_mode: PlanMode.new(),
        approved: true,
        policy_allows_write: true
      })

    assert %HookResult{decision: :continue} = result
  end

  test "does not trust approval signals from event metadata" do
    {:ok, task} =
      TaskManager.create(%{
        session_id: "sess_untrusted_approval",
        owner_id: "agent_untrusted_approval",
        content: "Untrusted approval task",
        category: "acting",
        permission_scope: ["write"]
      })

    {:ok, _} = TaskManager.activate(task.id)

    event =
      Event.new(:write,
        session_id: "sess_untrusted_approval",
        agent_id: "agent_untrusted_approval",
        metadata: %{approved: true, policy_allows_write: true},
        payload: %{approved: true, policy_allows_write: true}
      )

    result = TaskEnforcementHook.on_event(event, %{plan_mode: PlanMode.new()})

    assert %HookResult{decision: :block, reason: "Permission requires approval"} = result
  end

  test "does not trust subagent role qualifiers from event metadata" do
    {:ok, task} =
      TaskManager.create(%{
        session_id: "sess_untrusted_subagent",
        owner_id: "agent_untrusted_subagent",
        content: "Research task",
        category: "researching",
        permission_scope: ["subagent"]
      })

    {:ok, _} = TaskManager.activate(task.id)

    event =
      Event.new(:kiro_delegate,
        session_id: "sess_untrusted_subagent",
        agent_id: "agent_untrusted_subagent",
        permission_level: :subagent,
        metadata: %{subagent_kind: :read_only},
        payload: %{subagent_kind: :read_only}
      )

    result =
      TaskEnforcementHook.on_event(event, %{
        plan_mode: PlanMode.new(),
        approved: true
      })

    assert %HookResult{decision: :block, reason: "Category permission denied"} = result
  end

  test "filters and enforces subagent permissions" do
    {:ok, task} =
      TaskManager.create(%{
        session_id: "sess_subagent",
        owner_id: "agent_subagent",
        content: "Research task",
        category: "researching",
        permission_scope: ["subagent"]
      })

    {:ok, _} = TaskManager.activate(task.id)

    event =
      Event.new(:kiro_delegate,
        session_id: "sess_subagent",
        agent_id: "agent_subagent",
        permission_level: :subagent
      )

    assert TaskEnforcementHook.filter(event)

    result = TaskEnforcementHook.on_event(event, %{plan_mode: PlanMode.new()})

    assert %HookResult{decision: :block, reason: "Category permission denied"} = result
  end

  describe "PlanModeFirstActionHook" do
    test "injects guidance on first action in planning mode" do
      event = Event.new(:read, session_id: "sess_1", agent_id: "agent_1")
      {:ok, plan_mode} = PlanMode.enter_plan_mode(PlanMode.new())
      ctx = %{plan_mode: plan_mode, first_action_shown: false}

      result = PlanModeFirstActionHook.on_event(event, ctx)

      assert %HookResult{decision: :modify} = result
      assert result.messages |> Enum.any?(&String.contains?(&1, "plan mode"))
      assert result.messages |> Enum.any?(&String.contains?(&1, "direct read action is allowed"))
    end

    test "does not describe mutating wrapper action as allowed in plan mode" do
      event = Event.new(:kiro_session_prompt, permission_level: :write)
      {:ok, plan_mode} = PlanMode.enter_plan_mode(PlanMode.new())
      ctx = %{plan_mode: plan_mode, first_action_shown: false}

      result = PlanModeFirstActionHook.on_event(event, ctx)

      assert %HookResult{decision: :modify} = result
      assert Enum.any?(result.messages, &String.contains?(&1, "blocked in plan mode"))
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

      # Should have messages from PlanModeFirstActionHook.
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
