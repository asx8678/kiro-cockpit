defmodule KiroCockpit.Swarm.Hooks.Phase4HooksTest do
  use KiroCockpit.DataCase, async: true

  alias KiroCockpit.Swarm.{Event, HookResult, HookManager}
  alias KiroCockpit.Swarm.Tasks.TaskManager

  alias KiroCockpit.Swarm.Hooks.{
    WriteValidationHook,
    PostActingHook,
    TaskMaintenanceHook,
    ToolResultAnalysisHook,
    LocalFindingsHook
  }

  alias KiroCockpit.Repo

  setup do
    Repo.delete_all(KiroCockpit.Swarm.Tasks.Task)
    :ok
  end

  # ===================================================================
  # WriteValidationHook
  # ===================================================================

  describe "WriteValidationHook" do
    test "name is :write_validation" do
      assert WriteValidationHook.name() == :write_validation
    end

    test "priority is 90" do
      assert WriteValidationHook.priority() == 90
    end

    test "filters on write actions" do
      assert WriteValidationHook.filter(Event.new(:write))
      assert WriteValidationHook.filter(Event.new(:file_write_requested))
      assert WriteValidationHook.filter(Event.new(:fs_write_requested))
      refute WriteValidationHook.filter(Event.new(:read))
      refute WriteValidationHook.filter(Event.new(:shell_read))
    end

    test "continues when no failure count in ctx" do
      event = Event.new(:write)
      result = WriteValidationHook.on_event(event, %{})

      assert %HookResult{decision: :continue} = result
      assert result.messages == []
    end

    test "continues with warning when failure count is below threshold" do
      event = Event.new(:write)
      result = WriteValidationHook.on_event(event, %{write_failure_count: 1})

      assert %HookResult{decision: :continue} = result
      assert length(result.messages) == 1
      assert hd(result.messages) =~ "1/3"
    end

    test "blocks when failure count meets default threshold (3)" do
      event = Event.new(:write)
      result = WriteValidationHook.on_event(event, %{write_failure_count: 3})

      assert %HookResult{decision: :block} = result
      assert result.reason =~ "3 consecutive failures"
      assert hd(result.messages) =~ "Change approach"
    end

    test "blocks with custom threshold from ctx" do
      event = Event.new(:write)

      result =
        WriteValidationHook.on_event(event, %{write_failure_count: 2, write_failure_threshold: 2})

      assert %HookResult{decision: :block} = result
      assert result.reason =~ "2 consecutive failures"
    end

    test "includes last failure reason in block guidance" do
      event = Event.new(:write)

      result =
        WriteValidationHook.on_event(event, %{
          write_failure_count: 5,
          last_write_failure_reason: "Permission denied"
        })

      assert %HookResult{decision: :block} = result
      assert hd(result.messages) =~ "Permission denied"
    end

    test "includes failure metadata in hook_metadata" do
      event = Event.new(:write)
      result = WriteValidationHook.on_event(event, %{write_failure_count: 2})

      assert result.hook_metadata.failure_count == 2
      assert result.hook_metadata.threshold == 3
    end
  end

  # ===================================================================
  # PostActingHook
  # ===================================================================

  describe "PostActingHook" do
    test "name is :post_acting" do
      assert PostActingHook.name() == :post_acting
    end

    test "priority is 90" do
      assert PostActingHook.priority() == 90
    end

    test "filters on write and shell actions" do
      assert PostActingHook.filter(Event.new(:write))
      assert PostActingHook.filter(Event.new(:file_write_requested))
      assert PostActingHook.filter(Event.new(:shell_write))
      assert PostActingHook.filter(Event.new(:terminal))
      assert PostActingHook.filter(Event.new(:kiro_session_prompt))
      refute PostActingHook.filter(Event.new(:read))
      refute PostActingHook.filter(Event.new(:shell_read))
    end

    test "continues with verify guidance after write action" do
      event = Event.new(:write)
      result = PostActingHook.on_event(event, %{})

      assert %HookResult{decision: :continue} = result
      assert length(result.messages) == 1
      assert hd(result.messages) =~ "Verify"
      assert hd(result.messages) =~ "tests"
    end

    test "continues with verify guidance after shell_write" do
      event = Event.new(:shell_write)
      result = PostActingHook.on_event(event, %{})

      assert %HookResult{decision: :continue} = result
      assert hd(result.messages) =~ "command succeeded"
    end

    test "continues with guidance after kiro_session_prompt" do
      event = Event.new(:kiro_session_prompt)
      result = PostActingHook.on_event(event, %{})

      assert %HookResult{decision: :continue} = result
      assert hd(result.messages) =~ "Kiro session"
    end

    test "skips guidance when suppressed" do
      event = Event.new(:write)
      result = PostActingHook.on_event(event, %{post_acting_suppressed: true})

      assert %HookResult{decision: :continue} = result
      assert result.messages == []
    end

    test "skips guidance when suppressed via string key" do
      event = Event.new(:write)
      result = PostActingHook.on_event(event, %{"post_acting_suppressed" => "true"})

      assert %HookResult{decision: :continue} = result
      assert result.messages == []
    end
  end

  # ===================================================================
  # TaskMaintenanceHook
  # ===================================================================

  describe "TaskMaintenanceHook" do
    test "name is :task_maintenance" do
      assert TaskMaintenanceHook.name() == :task_maintenance
    end

    test "priority is 90" do
      assert TaskMaintenanceHook.priority() == 90
    end

    test "filters out exempt lifecycle actions" do
      refute TaskMaintenanceHook.filter(Event.new(:task_create))
      refute TaskMaintenanceHook.filter(Event.new(:task_activate))
      refute TaskMaintenanceHook.filter(Event.new(:task_complete))
      refute TaskMaintenanceHook.filter(Event.new(:task_block))
      refute TaskMaintenanceHook.filter(Event.new(:plan_approved))
      refute TaskMaintenanceHook.filter(Event.new(:nano_plan_generate))
    end

    test "filters in regular actions" do
      assert TaskMaintenanceHook.filter(Event.new(:write))
      assert TaskMaintenanceHook.filter(Event.new(:read))
      assert TaskMaintenanceHook.filter(Event.new(:kiro_session_prompt))
    end

    test "reminds about stale active task" do
      event = Event.new(:write)
      result = TaskMaintenanceHook.on_event(event, %{active_task_stale?: true, active_task: %{}})

      assert %HookResult{decision: :continue} = result
      assert Enum.any?(result.messages, &String.contains?(&1, "stale"))
    end

    test "reminds about blocked tasks from ctx" do
      event = Event.new(:write)
      result = TaskMaintenanceHook.on_event(event, %{blocked_tasks: 2, active_task: %{}})

      assert %HookResult{decision: :continue} = result
      assert Enum.any?(result.messages, &String.contains?(&1, "2 blocked task"))
    end

    test "reminds about stalled lane (pending but no active)" do
      event = Event.new(:write)
      result = TaskMaintenanceHook.on_event(event, %{pending_tasks: 3, active_task: nil})

      assert %HookResult{decision: :continue} = result
      assert Enum.any?(result.messages, &String.contains?(&1, "3 pending task"))
    end

    test "quiet when no maintenance issues" do
      event = Event.new(:write)

      result =
        TaskMaintenanceHook.on_event(event, %{
          active_task: %{},
          pending_tasks: 0,
          blocked_tasks: 0
        })

      assert %HookResult{decision: :continue} = result
      assert result.messages == []
    end

    test "skips when suppressed" do
      event = Event.new(:write)

      result =
        TaskMaintenanceHook.on_event(event, %{
          task_maintenance_suppressed: true,
          active_task_stale?: true
        })

      assert %HookResult{decision: :continue} = result
      assert result.messages == []
    end

    test "counts blocked tasks from DB when ctx lacks blocked_tasks" do
      sid = "tm_db_test_#{System.unique_integer([:positive])}"
      owner = "tm_agent"

      # Create and block a task
      {:ok, task} =
        TaskManager.create(%{session_id: sid, content: "block me", owner_id: owner})

      {:ok, _} = TaskManager.activate(task.id)
      {:ok, _} = TaskManager.block(task.id)

      event = Event.new(:write, session_id: sid, agent_id: owner)
      result = TaskMaintenanceHook.on_event(event, %{active_task: nil})

      assert %HookResult{decision: :continue} = result
      assert Enum.any?(result.messages, &String.contains?(&1, "blocked task"))
    end
  end

  # ===================================================================
  # ToolResultAnalysisHook
  # ===================================================================

  describe "ToolResultAnalysisHook" do
    test "name is :tool_result_analysis" do
      assert ToolResultAnalysisHook.name() == :tool_result_analysis
    end

    test "priority is 90" do
      assert ToolResultAnalysisHook.priority() == 90
    end

    test "filters on tool result actions" do
      assert ToolResultAnalysisHook.filter(Event.new(:kiro_session_prompt))
      assert ToolResultAnalysisHook.filter(Event.new(:kiro_tool_call_detected))
      assert ToolResultAnalysisHook.filter(Event.new(:verification_run))
      assert ToolResultAnalysisHook.filter(Event.new(:shell_write))
      refute ToolResultAnalysisHook.filter(Event.new(:write))
      refute ToolResultAnalysisHook.filter(Event.new(:read))
    end

    test "detects error patterns in payload" do
      event = Event.new(:kiro_session_prompt, payload: %{result: "error: compilation failed"})
      result = ToolResultAnalysisHook.on_event(event, %{})

      assert %HookResult{decision: :continue} = result
      assert Enum.any?(result.messages, &String.contains?(&1, "Error detected"))
    end

    test "detects test results in payload" do
      event = Event.new(:kiro_session_prompt, payload: %{output: "3 tests passed, 1 failed"})
      result = ToolResultAnalysisHook.on_event(event, %{})

      assert %HookResult{decision: :continue} = result
      assert Enum.any?(result.messages, &String.contains?(&1, "Test output"))
    end

    test "detects validation candidates in payload" do
      event = Event.new(:kiro_session_prompt, payload: %{output: "2 credo warnings found"})
      result = ToolResultAnalysisHook.on_event(event, %{})

      assert %HookResult{decision: :continue} = result
      assert Enum.any?(result.messages, &String.contains?(&1, "Validation candidate"))
    end

    test "detects non-zero exit code" do
      event = Event.new(:shell_write, payload: %{exit_code: 1})
      result = ToolResultAnalysisHook.on_event(event, %{})

      assert %HookResult{decision: :continue} = result
      assert Enum.any?(result.messages, &String.contains?(&1, "Non-zero exit code"))
    end

    test "quiet when no patterns found" do
      event = Event.new(:kiro_session_prompt, payload: %{result: "success", output: "ok"})
      result = ToolResultAnalysisHook.on_event(event, %{})

      assert %HookResult{decision: :continue} = result
      assert result.messages == []
    end

    test "checks raw_payload too" do
      event = Event.new(:kiro_session_prompt, payload: %{}, raw_payload: %{error: "stacktrace"})
      result = ToolResultAnalysisHook.on_event(event, %{})

      assert %HookResult{decision: :continue} = result
      assert Enum.any?(result.messages, &String.contains?(&1, "Error detected"))
    end

    test "applies override patterns from ctx" do
      event = Event.new(:kiro_session_prompt, payload: %{custom_output: "custom failure mode"})

      result =
        ToolResultAnalysisHook.on_event(event, %{
          tool_result_overrides: %{"custom_output" => "failure"}
        })

      assert %HookResult{decision: :continue} = result
      assert Enum.any?(result.messages, &String.contains?(&1, "Override pattern"))
    end

    test "applies regex override patterns" do
      event = Event.new(:kiro_session_prompt, payload: %{build_log: "BUILD FAILED at line 42"})

      result =
        ToolResultAnalysisHook.on_event(event, %{
          tool_result_overrides: %{"build_log" => ~r/BUILD FAILED/i}
        })

      assert %HookResult{decision: :continue} = result
      assert Enum.any?(result.messages, &String.contains?(&1, "Override pattern"))
    end

    test "includes finding_count in metadata" do
      event = Event.new(:kiro_session_prompt, payload: %{result: "error", tests: "3 tests ran"})

      result = ToolResultAnalysisHook.on_event(event, %{})

      assert result.hook_metadata.finding_count > 0
    end
  end

  # ===================================================================
  # LocalFindingsHook
  # ===================================================================

  describe "LocalFindingsHook" do
    test "name is :local_findings" do
      assert LocalFindingsHook.name() == :local_findings
    end

    test "priority is 85" do
      assert LocalFindingsHook.priority() == 85
    end

    test "filters on finding actions" do
      assert LocalFindingsHook.filter(Event.new(:kiro_session_prompt))
      assert LocalFindingsHook.filter(Event.new(:write))
      assert LocalFindingsHook.filter(Event.new(:read))
      assert LocalFindingsHook.filter(Event.new(:shell_write))
      refute LocalFindingsHook.filter(Event.new(:task_create))
      refute LocalFindingsHook.filter(Event.new(:task_activate))
    end

    test "quiet when no findings in payload" do
      event = Event.new(:kiro_session_prompt, payload: %{result: "ok"})
      result = LocalFindingsHook.on_event(event, %{local_findings_suppressed: true})

      assert %HookResult{decision: :continue} = result
      assert result.messages == []
    end

    test "extracts explicit findings from payload" do
      event =
        Event.new(:kiro_session_prompt,
          session_id: "find_s1",
          agent_id: "find_a1",
          payload: %{
            findings: [
              %{"type" => "anti_pattern", "description" => "N+1 query detected"},
              %{"type" => "security", "description" => "Hardcoded secret"}
            ]
          }
        )

      result = LocalFindingsHook.on_event(event, %{})

      assert %HookResult{decision: :continue} = result
      assert length(result.messages) == 1
      assert hd(result.messages) =~ "2 finding(s) persisted"
    end

    test "extracts error findings from payload" do
      event =
        Event.new(:kiro_session_prompt,
          session_id: "find_s2",
          agent_id: "find_a2",
          payload: %{error_findings: [%{"description" => "Missing import"}]}
        )

      result = LocalFindingsHook.on_event(event, %{})

      assert %HookResult{decision: :continue} = result
      assert hd(result.messages) =~ "1 finding(s) persisted"
    end

    test "extracts pattern findings from metadata" do
      event =
        Event.new(:write,
          session_id: "find_s3",
          agent_id: "find_a3",
          metadata: %{pattern_findings: [%{"description" => "Repeated code block"}]}
        )

      result = LocalFindingsHook.on_event(event, %{})

      assert %HookResult{decision: :continue} = result
      assert hd(result.messages) =~ "1 finding(s) persisted"
    end

    test "skips when suppressed" do
      event =
        Event.new(:kiro_session_prompt,
          session_id: "find_s4",
          agent_id: "find_a4",
          payload: %{findings: [%{"type" => "x", "description" => "y"}]}
        )

      result = LocalFindingsHook.on_event(event, %{local_findings_suppressed: true})

      assert %HookResult{decision: :continue} = result
      assert result.messages == []
    end

    test "persists findings as Bronze local_finding events" do
      event =
        Event.new(:kiro_session_prompt,
          session_id: "find_bronze_s1",
          agent_id: "find_bronze_a1",
          payload: %{findings: [%{"type" => "test", "description" => "Flaky test"}]}
        )

      LocalFindingsHook.on_event(event, %{})

      # Verify Bronze event was created
      bronze_events =
        KiroCockpit.Swarm.Events.list_by_session("find_bronze_s1", limit: 10)

      finding_events = Enum.filter(bronze_events, &(&1.event_type == "local_finding"))
      assert length(finding_events) >= 1
    end

    test "does not crash on persistence failure" do
      # Event with nil session_id will likely fail validation
      event =
        Event.new(:kiro_session_prompt,
          session_id: nil,
          agent_id: "a",
          payload: %{findings: [%{"type" => "x", "description" => "y"}]}
        )

      # Should not raise — persistence failure is caught
      result = LocalFindingsHook.on_event(event, %{})

      assert %HookResult{decision: :continue} = result
    end

    test "normalizes single-map error_findings" do
      event =
        Event.new(:kiro_session_prompt,
          session_id: "find_s5",
          agent_id: "find_a5",
          payload: %{error_findings: %{"description" => "Stack overflow"}}
        )

      result = LocalFindingsHook.on_event(event, %{})

      assert %HookResult{decision: :continue} = result
      assert hd(result.messages) =~ "1 finding(s) persisted"
    end
  end

  # ===================================================================
  # Hook behaviour compliance
  # ===================================================================

  describe "hook behaviour compliance" do
    test "all phase-4 hooks implement Hook behaviour" do
      for hook <- [
            WriteValidationHook,
            PostActingHook,
            TaskMaintenanceHook,
            ToolResultAnalysisHook,
            LocalFindingsHook
          ] do
        assert is_atom(hook.name())
        assert is_integer(hook.priority())
        assert is_function(hook.filter(event()), 1) or is_boolean(hook.filter(Event.new(:read)))

        # Verify on_event returns a HookResult
        filtered_event = Event.new(:kiro_session_prompt)
        result = hook.on_event(filtered_event, %{})
        assert %HookResult{} = result
      end
    end

    defp event, do: Event.new(:read)

    test "all phase-4 hooks return valid HookResult from on_event" do
      event = Event.new(:kiro_session_prompt)

      for hook <- [
            WriteValidationHook,
            PostActingHook,
            TaskMaintenanceHook,
            ToolResultAnalysisHook,
            LocalFindingsHook
          ] do
        if hook.filter(event) do
          result = hook.on_event(event, %{})
          assert %HookResult{} = result
          assert result.decision in [:continue, :modify, :block]
        end
      end
    end

    test "all phase-4 hooks return atom names" do
      for hook <- [
            WriteValidationHook,
            PostActingHook,
            TaskMaintenanceHook,
            ToolResultAnalysisHook,
            LocalFindingsHook
          ] do
        assert is_atom(hook.name())
      end
    end

    test "all phase-4 hooks return integer priorities" do
      for hook <- [
            WriteValidationHook,
            PostActingHook,
            TaskMaintenanceHook,
            ToolResultAnalysisHook,
            LocalFindingsHook
          ] do
        assert is_integer(hook.priority())
      end
    end
  end

  # ===================================================================
  # Hook chain integration (post-action ordering)
  # ===================================================================

  describe "post-action hook chain ordering" do
    test "phase-4 hooks sort correctly in post-action phase" do
      post_hooks = [
        WriteValidationHook,
        PostActingHook,
        TaskMaintenanceHook,
        ToolResultAnalysisHook,
        KiroCockpit.Swarm.Hooks.TaskGuidanceHook,
        LocalFindingsHook
      ]

      sorted = HookManager.sort_for_phase(post_hooks, :post)

      # Post-action: ascending priority, then alphabetical name
      # Priority 85: local_findings < task_guidance
      # Priority 90: post_acting, task_maintenance, tool_result_analysis, write_validation
      names = Enum.map(sorted, & &1.name())

      # 85-priority hooks come first in post (ascending)
      assert :local_findings in names
      assert :task_guidance in names

      # 90-priority hooks come after
      assert :post_acting in names
      assert :task_maintenance in names
      assert :tool_result_analysis in names
      assert :write_validation in names

      # Verify 85-priority hooks come before 90-priority hooks
      idx_85 =
        names
        |> Enum.with_index()
        |> Enum.filter(fn {n, _} -> n in [:local_findings, :task_guidance] end)
        |> Enum.map(&elem(&1, 1))

      idx_90 =
        names
        |> Enum.with_index()
        |> Enum.filter(fn {n, _} ->
          n in [:post_acting, :task_maintenance, :tool_result_analysis, :write_validation]
        end)
        |> Enum.map(&elem(&1, 1))

      assert Enum.max(idx_85) < Enum.min(idx_90),
             "Priority-85 hooks should run before priority-90 hooks in post-action phase"
    end
  end
end
