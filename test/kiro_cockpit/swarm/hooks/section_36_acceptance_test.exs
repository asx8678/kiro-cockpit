defmodule KiroCockpit.Swarm.Hooks.Section36AcceptanceTest do
  @moduledoc """
  Focused acceptance tests for plan2.md §36.2 (Task enforcement) and
  §36.3 (Steering). These complement the broader hooks_test.exs by
  providing explicit regression/acceptance coverage for each §36 bullet.
  """

  use KiroCockpit.DataCase, async: true

  alias KiroCockpit.Swarm.{Event, HookManager, HookResult, PlanMode}

  alias KiroCockpit.Swarm.Hooks.{TaskEnforcementHook, SteeringPreActionHook}

  alias KiroCockpit.Swarm.Tasks.{Task, TaskManager}
  alias KiroCockpit.Repo

  setup do
    Repo.delete_all(Task)
    :ok
  end

  defp activate_task(session_id, category), do: activate_task(session_id, category, %{})

  defp activate_task(session_id, category, attrs) do
    attrs =
      Map.merge(
        %{
          session_id: session_id,
          owner_id: "a1",
          content: "§36 acceptance task",
          category: category
        },
        attrs
      )

    {:ok, task} = TaskManager.create(attrs)
    {:ok, active_task} = TaskManager.activate(task.id)
    active_task
  end

  # ═══════════════════════════════════════════════════════════════════════
  # §36.2  Task enforcement tests
  # ═══════════════════════════════════════════════════════════════════════

  describe "§36.2 — action without active task is blocked" do
    test "write without active task is blocked" do
      event = Event.new(:write, session_id: "s36_no_task", agent_id: "a1")

      assert %HookResult{decision: :block, reason: "No active task"} =
               TaskEnforcementHook.on_event(event, %{plan_mode: PlanMode.new()})
    end

    test "shell_write without active task is blocked" do
      event = Event.new(:shell_write, session_id: "s36_no_task", agent_id: "a1")

      assert %HookResult{decision: :block, reason: "No active task"} =
               TaskEnforcementHook.on_event(event, %{plan_mode: PlanMode.new()})
    end
  end

  describe "§36.2 — plan mode read-only allowed without task" do
    test "direct read in planning mode passes without active task" do
      event = Event.new(:read, session_id: "s36_plan_read", agent_id: "a1")
      {:ok, plan_mode} = PlanMode.enter_plan_mode(PlanMode.new())

      assert %HookResult{decision: :continue} =
               TaskEnforcementHook.on_event(event, %{plan_mode: plan_mode})
    end

    test "wrapper read in planning mode passes without active task" do
      event =
        Event.new(:kiro_session_prompt,
          session_id: "s36_plan_wrap",
          agent_id: "a1",
          permission_level: :read
        )

      {:ok, plan_mode} = PlanMode.enter_plan_mode(PlanMode.new())

      assert %HookResult{decision: :continue} =
               TaskEnforcementHook.on_event(event, %{plan_mode: plan_mode})
    end
  end

  describe "§36.2 — plan mode write blocked" do
    test "write in planning mode is blocked even with active task" do
      {:ok, task} =
        TaskManager.create(%{
          session_id: "s36_plan_write",
          owner_id: "a1",
          content: "Plan write task",
          category: "researching"
        })

      {:ok, _} = TaskManager.activate(task.id)
      {:ok, plan_mode} = PlanMode.enter_plan_mode(PlanMode.new())

      event = Event.new(:write, session_id: "s36_plan_write", agent_id: "a1")

      assert %HookResult{decision: :block, reason: "Action blocked during planning"} =
               TaskEnforcementHook.on_event(event, %{plan_mode: plan_mode})
    end
  end

  describe "§36.2 — planning category blocks shell/write" do
    test "planning category blocks write" do
      {:ok, task} =
        TaskManager.create(%{
          session_id: "s36_planning_cat",
          owner_id: "a1",
          content: "Planning task",
          category: "planning"
        })

      {:ok, _} = TaskManager.activate(task.id)

      event = Event.new(:write, session_id: "s36_planning_cat", agent_id: "a1")

      assert %HookResult{decision: :block, reason: "Category permission denied"} =
               TaskEnforcementHook.on_event(event, %{plan_mode: PlanMode.new()})
    end

    test "planning category blocks shell_write" do
      {:ok, task} =
        TaskManager.create(%{
          session_id: "s36_planning_shell",
          owner_id: "a1",
          content: "Planning task",
          category: "planning"
        })

      {:ok, _} = TaskManager.activate(task.id)

      event = Event.new(:shell_write, session_id: "s36_planning_shell", agent_id: "a1")

      assert %HookResult{decision: :block} =
               TaskEnforcementHook.on_event(event, %{plan_mode: PlanMode.new()})
    end

    test "planning category blocks shell_read" do
      {:ok, task} =
        TaskManager.create(%{
          session_id: "s36_planning_shell_r",
          owner_id: "a1",
          content: "Planning task",
          category: "planning"
        })

      {:ok, _} = TaskManager.activate(task.id)

      event = Event.new(:shell_read, session_id: "s36_planning_shell_r", agent_id: "a1")

      assert %HookResult{decision: :block} =
               TaskEnforcementHook.on_event(event, %{plan_mode: PlanMode.new()})
    end

    test "planning category allows read" do
      {:ok, task} =
        TaskManager.create(%{
          session_id: "s36_planning_read",
          owner_id: "a1",
          content: "Planning task",
          category: "planning"
        })

      {:ok, _} = TaskManager.activate(task.id)

      event = Event.new(:read, session_id: "s36_planning_read", agent_id: "a1")

      assert %HookResult{decision: :continue} =
               TaskEnforcementHook.on_event(event, %{plan_mode: PlanMode.new()})
    end
  end

  describe "§36.2 — debugging allows grep/git diff/log diagnostics" do
    test "debugging allows shell_read (grep, git diff, log)" do
      {:ok, task} =
        TaskManager.create(%{
          session_id: "s36_debug_diag",
          owner_id: "a1",
          content: "Debug task",
          category: "debugging"
        })

      {:ok, _} = TaskManager.activate(task.id)

      # shell_read_requested maps to :shell_read permission
      event =
        Event.new(:shell_read_requested,
          session_id: "s36_debug_diag",
          agent_id: "a1",
          permission_level: :shell_read
        )

      assert %HookResult{decision: :continue} =
               TaskEnforcementHook.on_event(event, %{plan_mode: PlanMode.new()})
    end

    test "debugging allows read for log/diagnostic files" do
      {:ok, task} =
        TaskManager.create(%{
          session_id: "s36_debug_read",
          owner_id: "a1",
          content: "Debug task",
          category: "debugging"
        })

      {:ok, _} = TaskManager.activate(task.id)

      event = Event.new(:read, session_id: "s36_debug_read", agent_id: "a1")

      assert %HookResult{decision: :continue} =
               TaskEnforcementHook.on_event(event, %{plan_mode: PlanMode.new()})
    end

    test "debugging blocks implementation write" do
      {:ok, task} =
        TaskManager.create(%{
          session_id: "s36_debug_impl",
          owner_id: "a1",
          content: "Debug task",
          category: "debugging"
        })

      {:ok, _} = TaskManager.activate(task.id)

      event = Event.new(:write, session_id: "s36_debug_impl", agent_id: "a1")

      assert %HookResult{decision: :block, reason: "Category permission denied"} =
               TaskEnforcementHook.on_event(event, %{plan_mode: PlanMode.new()})
    end
  end

  describe "§36.2 — acting category enforces permission scope" do
    test "acting task with write scope allows write when approved" do
      {:ok, task} =
        TaskManager.create(%{
          session_id: "s36_acting_scope",
          owner_id: "a1",
          content: "Acting task",
          category: "acting",
          permission_scope: ["write"]
        })

      {:ok, _} = TaskManager.activate(task.id)

      event = Event.new(:write, session_id: "s36_acting_scope", agent_id: "a1")

      assert %HookResult{decision: :continue} =
               TaskEnforcementHook.on_event(event, %{
                 plan_mode: PlanMode.new(),
                 approved: true,
                 policy_allows_write: true
               })
    end

    test "acting task without approval blocks write" do
      {:ok, task} =
        TaskManager.create(%{
          session_id: "s36_acting_no_app",
          owner_id: "a1",
          content: "Acting task",
          category: "acting",
          permission_scope: ["write"]
        })

      {:ok, _} = TaskManager.activate(task.id)

      event = Event.new(:write, session_id: "s36_acting_no_app", agent_id: "a1")

      assert %HookResult{decision: :block, reason: "Permission requires approval"} =
               TaskEnforcementHook.on_event(event, %{plan_mode: PlanMode.new()})
    end

    test "acting task with read-only scope denies write at scope level" do
      {:ok, task} =
        TaskManager.create(%{
          session_id: "s36_acting_ro",
          owner_id: "a1",
          content: "Acting read-only task",
          category: "acting",
          permission_scope: ["read"]
        })

      {:ok, _} = TaskManager.activate(task.id)

      event = Event.new(:write, session_id: "s36_acting_ro", agent_id: "a1")

      # Acting + write needs approval, but scope only has read → scope_denied
      assert %HookResult{decision: :block} =
               TaskEnforcementHook.on_event(event, %{plan_mode: PlanMode.new()})
    end

    test "acting task allows read without approval" do
      {:ok, task} =
        TaskManager.create(%{
          session_id: "s36_acting_read",
          owner_id: "a1",
          content: "Acting task",
          category: "acting"
        })

      {:ok, _} = TaskManager.activate(task.id)

      event = Event.new(:read, session_id: "s36_acting_read", agent_id: "a1")

      assert %HookResult{decision: :continue} =
               TaskEnforcementHook.on_event(event, %{plan_mode: PlanMode.new()})
    end
  end

  describe "§36.2 — stale plan blocks mutating action by default" do
    test "stale_plan? in ctx blocks write action after active-task gate" do
      activate_task("s36_stale_write", "acting", %{permission_scope: ["write"]})

      event = Event.new(:write, session_id: "s36_stale_write", agent_id: "a1")

      assert %HookResult{decision: :block, reason: "Stale plan blocks mutating action"} =
               TaskEnforcementHook.on_event(event, %{plan_mode: PlanMode.new(), stale_plan?: true})
    end

    test "stale_plan in ctx blocks write action (alternate key)" do
      activate_task("s36_stale_alt", "acting", %{permission_scope: ["write"]})

      event = Event.new(:write, session_id: "s36_stale_alt", agent_id: "a1")

      assert %HookResult{decision: :block, reason: "Stale plan blocks mutating action"} =
               TaskEnforcementHook.on_event(event, %{plan_mode: PlanMode.new(), stale_plan: true})
    end

    test "stale plan still preserves no-active-task invariant before stale check" do
      event = Event.new(:write, session_id: "s36_stale_no_task", agent_id: "a1")

      assert %HookResult{decision: :block, reason: "No active task"} =
               TaskEnforcementHook.on_event(event, %{plan_mode: PlanMode.new(), stale_plan?: true})
    end

    test "explicit trusted override allows stale mutating action to reach normal gates" do
      activate_task("s36_stale_override", "acting", %{permission_scope: ["write"]})

      event = Event.new(:write, session_id: "s36_stale_override", agent_id: "a1")

      assert %HookResult{decision: :continue} =
               TaskEnforcementHook.on_event(event, %{
                 plan_mode: PlanMode.new(),
                 stale_plan?: true,
                 stale_plan_override?: true,
                 approved: true,
                 policy_allows_write: true
               })
    end

    test "stale plan does NOT block read action" do
      activate_task("s36_stale_read", "acting")

      event = Event.new(:read, session_id: "s36_stale_read", agent_id: "a1")

      assert %HookResult{decision: :continue} =
               TaskEnforcementHook.on_event(event, %{plan_mode: PlanMode.new(), stale_plan?: true})
    end

    test "stale plan does NOT block shell_read (diagnostic) action" do
      activate_task("s36_stale_diag", "debugging")

      event =
        Event.new(:shell_read,
          session_id: "s36_stale_diag",
          agent_id: "a1",
          permission_level: :shell_read
        )

      assert %HookResult{decision: :continue} =
               TaskEnforcementHook.on_event(event, %{plan_mode: PlanMode.new(), stale_plan?: true})
    end

    test "stale plan blocks shell_write action" do
      activate_task("s36_stale_sw", "acting", %{permission_scope: ["shell_write"]})

      event = Event.new(:shell_write, session_id: "s36_stale_sw", agent_id: "a1")

      assert %HookResult{decision: :block, reason: "Stale plan blocks mutating action"} =
               TaskEnforcementHook.on_event(event, %{plan_mode: PlanMode.new(), stale_plan?: true})
    end

    test "stale plan blocks terminal action" do
      activate_task("s36_stale_term", "acting", %{permission_scope: ["terminal"]})

      event = Event.new(:terminal, session_id: "s36_stale_term", agent_id: "a1")

      assert %HookResult{decision: :block, reason: "Stale plan blocks mutating action"} =
               TaskEnforcementHook.on_event(event, %{plan_mode: PlanMode.new(), stale_plan?: true})
    end

    test "stale plan gate is trusted — event metadata cannot bypass it" do
      activate_task("s36_stale_untrusted", "acting", %{permission_scope: ["write"]})

      # Event metadata/payload must NOT be able to clear stale_plan
      event =
        Event.new(:write,
          session_id: "s36_stale_untrusted",
          agent_id: "a1",
          metadata: %{stale_plan?: false, stale_plan: false, stale_plan_override?: true},
          payload: %{stale_plan?: false, stale_plan: false, stale_plan_override?: true}
        )

      # ctx says stale → still blocked (ctx is trusted, metadata/payload are not)
      assert %HookResult{decision: :block, reason: "Stale plan blocks mutating action"} =
               TaskEnforcementHook.on_event(event, %{plan_mode: PlanMode.new(), stale_plan?: true})
    end

    test "no stale plan flag in ctx allows action normally" do
      event = Event.new(:write, session_id: "s36_no_stale", agent_id: "a1")

      # Without stale_plan? flag, action proceeds to next gate
      # (will be blocked by "No active task" since no task is active)
      assert %HookResult{decision: :block, reason: "No active task"} =
               TaskEnforcementHook.on_event(event, %{plan_mode: PlanMode.new()})
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # §36.3  Steering tests
  # ═══════════════════════════════════════════════════════════════════════

  describe "§36.3 — continue decision allows action" do
    test "LLM continue decision produces :continue hook result" do
      llm_continue = fn _prompt, _opts ->
        {:ok,
         ~s({"decision": "continue", "reason": "Action aligned with task", "risk_level": "low"})}
      end

      event = Event.new(:write, session_id: "s36_continue", agent_id: "a1")
      ctx = %{steering_opts: [steering_model: llm_continue]}

      result = SteeringPreActionHook.on_event(event, ctx)

      assert %HookResult{decision: :continue} = result
      assert result.hook_metadata[:steering_decision] == :continue
      assert result.hook_metadata[:steering_source] == :llm
    end
  end

  describe "§36.3 — focus decision allows action and injects reminder" do
    test "LLM focus decision produces :modify with drift reminder" do
      llm_focus = fn _prompt, _opts ->
        {:ok,
         ~s({"decision": "focus", "reason": "Drifting toward unrelated config", "suggested_next_action": "Return to auth module", "risk_level": "medium"})}
      end

      event = Event.new(:write, session_id: "s36_focus", agent_id: "a1")
      ctx = %{steering_opts: [steering_model: llm_focus]}

      result = SteeringPreActionHook.on_event(event, ctx)

      assert %HookResult{decision: :modify} = result
      assert result.hook_metadata[:steering_decision] == :focus
      # Reminder message includes the drift reason and suggested next action
      assert Enum.any?(result.messages, &String.contains?(&1, "Drifting"))
      assert Enum.any?(result.messages, &String.contains?(&1, "Return to auth module"))
    end

    test "deterministic drift signal produces focus with reminder" do
      event = Event.new(:write, session_id: "s36_det_focus", agent_id: "a1")

      ctx = %{steering_signal: %{drift: true, drift_message: "Slight drift detected"}}

      result = SteeringPreActionHook.on_event(event, ctx)

      assert %HookResult{decision: :modify} = result
      assert result.hook_metadata[:steering_decision] == :focus
      assert Enum.any?(result.messages, &String.contains?(&1, "drift"))
    end
  end

  describe "§36.3 — guide decision includes memory reference" do
    test "LLM guide decision produces :modify with memory references" do
      llm_guide = fn _prompt, _opts ->
        {:ok,
         ~s({"decision": "guide", "reason": "Related config pattern found", "suggested_next_action": "Review config hot-reload", "memory_refs": ["mem_config_42", "mem_auth_7"], "risk_level": "medium"})}
      end

      event = Event.new(:write, session_id: "s36_guide", agent_id: "a1")
      ctx = %{steering_opts: [steering_model: llm_guide]}

      result = SteeringPreActionHook.on_event(event, ctx)

      assert %HookResult{decision: :modify} = result
      assert result.hook_metadata[:steering_decision] == :guide
      # Memory references included in guidance message
      assert Enum.any?(result.messages, &String.contains?(&1, "mem_config_42"))
      assert Enum.any?(result.messages, &String.contains?(&1, "mem_auth_7"))
    end

    test "deterministic guide signal produces guidance with message" do
      event = Event.new(:write, session_id: "s36_det_guide", agent_id: "a1")

      ctx = %{steering_signal: %{guide: true, guide_message: "Consider memory on auth tokens"}}

      result = SteeringPreActionHook.on_event(event, ctx)

      assert %HookResult{decision: :modify} = result
      assert result.hook_metadata[:steering_decision] == :guide
      assert Enum.any?(result.messages, &String.contains?(&1, "auth tokens"))
    end
  end

  describe "§36.3 — block decision prevents action" do
    test "LLM block decision produces :block hook result" do
      llm_block = fn _prompt, _opts ->
        {:ok,
         ~s({"decision": "block", "reason": "Off-topic: unrelated to active task", "suggested_next_action": "Focus on auth module", "risk_level": "high"})}
      end

      event = Event.new(:write, session_id: "s36_block", agent_id: "a1")
      ctx = %{steering_opts: [steering_model: llm_block]}

      result = SteeringPreActionHook.on_event(event, ctx)

      assert %HookResult{decision: :block} = result
      assert result.reason == "Off-topic: unrelated to active task"
      assert Enum.any?(result.messages, &String.contains?(&1, "Focus on auth module"))
    end

    test "deterministic block signal prevents action" do
      event = Event.new(:write, session_id: "s36_det_block", agent_id: "a1")

      ctx = %{
        steering_signal: %{off_topic: true, off_topic_guidance: "Unrelated to current task"}
      }

      result = SteeringPreActionHook.on_event(event, ctx)

      assert %HookResult{decision: :block, reason: "Action is off-topic"} = result
    end
  end

  describe "§36.3 — deterministic category block bypasses LLM steering" do
    test "category hard-block for researching+write wins over LLM continue" do
      llm_continue = fn _prompt, _opts ->
        {:ok, ~s({"decision": "continue", "reason": "Looks fine", "risk_level": "low"})}
      end

      {:ok, task} =
        TaskManager.create(%{
          session_id: "s36_cat_block",
          owner_id: "a1",
          content: "Research task",
          category: "researching"
        })

      {:ok, _} = TaskManager.activate(task.id)

      event = Event.new(:write, session_id: "s36_cat_block", agent_id: "a1")
      hooks = [TaskEnforcementHook, SteeringPreActionHook]
      ctx = %{plan_mode: PlanMode.new(), steering_opts: [steering_model: llm_continue]}

      # TaskEnforcementHook (priority 95) blocks researching+write
      # SteeringPreActionHook (priority 94) never gets to run
      assert {:blocked, _event, "Category permission denied", _messages} =
               HookManager.run(event, hooks, ctx, :pre)
    end

    test "deterministic off-topic overrides LLM continue" do
      llm_continue = fn _prompt, _opts ->
        {:ok, ~s({"decision": "continue", "reason": "Ok by model", "risk_level": "low"})}
      end

      event = Event.new(:write, session_id: "s36_det_override", agent_id: "a1")

      ctx = %{
        steering_signal: %{off_topic: true, off_topic_guidance: "Off-topic detected"},
        steering_opts: [steering_model: llm_continue]
      }

      result = SteeringPreActionHook.on_event(event, ctx)

      # Trusted deterministic signal wins over LLM
      assert %HookResult{decision: :block, reason: "Action is off-topic"} = result
    end
  end

  describe "§36.3 — steering fallback conservative when model unavailable" do
    test "fallback is continue (not block) when model returns error" do
      failing_model = fn _prompt, _opts -> {:error, "service unavailable"} end

      event = Event.new(:write, session_id: "s36_fallback_err", agent_id: "a1")
      ctx = %{steering_opts: [steering_model: failing_model]}

      result = SteeringPreActionHook.on_event(event, ctx)

      # Fallback: continue, not block — deterministic gates already ran
      assert %HookResult{decision: :continue} = result
    end

    test "fallback is continue (not block) when no model configured" do
      event = Event.new(:write, session_id: "s36_fallback_none", agent_id: "a1")
      ctx = %{}

      result = SteeringPreActionHook.on_event(event, ctx)

      assert %HookResult{decision: :continue} = result
    end

    test "fallback is continue (not block) when model returns invalid JSON" do
      bad_model = fn _prompt, _opts -> {:ok, "not json at all"} end

      event = Event.new(:write, session_id: "s36_fallback_bad", agent_id: "a1")
      ctx = %{steering_opts: [steering_model: bad_model]}

      result = SteeringPreActionHook.on_event(event, ctx)

      assert %HookResult{decision: :continue} = result
    end

    test "model outage does NOT introduce LLM-only block — deterministic gates already ran" do
      # This is the key safety invariant: since deterministic gates
      # (TaskEnforcementHook, PlanMode) run at higher priority, the LLM
      # steering hook at priority 94 must never introduce a *new* block
      # that the deterministic gates didn't already catch. When the model
      # is down, fallback is :continue, so no new blocks appear.
      failing_model = fn _prompt, _opts -> {:error, "timeout"} end

      # Read action with no deterministic issues → should still pass
      event = Event.new(:read, session_id: "s36_fallback_read", agent_id: "a1")
      ctx = %{steering_opts: [steering_model: failing_model]}

      result = SteeringPreActionHook.on_event(event, ctx)

      assert %HookResult{decision: :continue} = result

      # Write action with failing model → fallback continue, not block
      write_event = Event.new(:write, session_id: "s36_fallback_write", agent_id: "a1")
      write_result = SteeringPreActionHook.on_event(write_event, ctx)

      assert %HookResult{decision: :continue} = write_result
      # The write would still be blocked by TaskEnforcementHook at
      # priority 95, but that's the deterministic gate, not LLM steering.
    end
  end
end
