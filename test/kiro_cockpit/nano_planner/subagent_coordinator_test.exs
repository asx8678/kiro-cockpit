defmodule KiroCockpit.NanoPlanner.SubagentCoordinatorTest do
  use KiroCockpit.DataCase

  alias KiroCockpit.NanoPlanner.SubagentCoordinator

  @agents_dir ".kiro/agents"

  # ── Fake injectable session module ──────────────────────────────────

  defmodule FakeKiroSession do
    @moduledoc false
    def prompt(_session, prompt_text, opts) do
      calls = Process.get(:fake_reviewer_prompt_calls, [])
      Process.put(:fake_reviewer_prompt_calls, calls ++ [{prompt_text, opts}])
      Process.get(:fake_reviewer_prompt_result, {:ok, %{"findings" => ["sample finding"]}})
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp setup_test_agents_dir(_) do
    dir =
      System.tmp_dir!()
      |> Path.join("subagent_coordinator_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)

    on_exit(fn -> File.rm_rf!(dir) end)

    %{test_agents_dir: dir}
  end

  defp write_agent_file(dir, name, agent_map) do
    path = Path.join(dir, "#{name}.json")
    File.write!(path, Jason.encode!(agent_map))
    path
  end

  defp write_qa_reviewer(dir) do
    write_agent_file(dir, "kiro-cockpit-qa-reviewer", %{
      "name" => "kiro-cockpit-qa-reviewer",
      "description" => "Read-only QA reviewer",
      "tools" => ["read", "grep"],
      "allowedTools" => ["read", "grep"],
      "includeMcpJson" => false,
      "model" => "claude-sonnet-4"
    })
  end

  defp write_security_reviewer(dir) do
    write_agent_file(dir, "kiro-cockpit-security-reviewer", %{
      "name" => "kiro-cockpit-security-reviewer",
      "description" => "Read-only security reviewer",
      "tools" => ["read", "grep"],
      "allowedTools" => ["read", "grep"],
      "includeMcpJson" => false,
      "model" => "claude-sonnet-4"
    })
  end

  defp write_executor(dir) do
    write_agent_file(dir, "kiro-cockpit-executor", %{
      "name" => "kiro-cockpit-executor",
      "description" => "Execution agent",
      "tools" => ["read", "write", "shell"],
      "allowedTools" => ["read"],
      "includeMcpJson" => true,
      "model" => "claude-sonnet-4"
    })
  end

  defp write_invalid_json(dir) do
    path = Path.join(dir, "broken.json")
    File.write!(path, "{invalid json}")
    path
  end

  defp write_missing_keys(dir) do
    write_agent_file(dir, "missing-keys", %{
      "name" => "incomplete"
      # missing description, tools, allowedTools
    })
  end

  defp default_correlation(plan_id) do
    %{
      parent_session_id: "test-session",
      plan_id: plan_id,
      task_id: nil,
      agent_id: "nano-planner"
    }
  end

  defp create_test_plan do
    alias KiroCockpit.Plans

    {:ok, plan} =
      Plans.create_plan(
        "test-session",
        "Test plan for subagent coordinator",
        "nano",
        [
          %{
            phase_number: 1,
            step_number: 1,
            title: "Test step",
            details: "Details",
            files: %{},
            permission_level: "read",
            validation: "Check",
            status: "planned"
          }
        ],
        plan_markdown: "# Test Plan",
        execution_prompt: "Do the thing",
        project_snapshot_hash: "abc123"
      )

    plan
  end

  # ── Tests: Agent loading ────────────────────────────────────────────

  describe "list_agents/1" do
    setup [:setup_test_agents_dir]

    test "returns empty list when no agents exist", %{test_agents_dir: dir} do
      assert {:ok, []} = SubagentCoordinator.list_agents(agents_dir: dir)
    end

    test "loads all valid agent definitions", %{test_agents_dir: dir} do
      write_qa_reviewer(dir)
      write_security_reviewer(dir)

      assert {:ok, agents} = SubagentCoordinator.list_agents(agents_dir: dir)
      assert length(agents) == 2
      names = Enum.map(agents, & &1.name) |> Enum.sort()
      assert names == ["kiro-cockpit-qa-reviewer", "kiro-cockpit-security-reviewer"]
    end

    test "skips files with invalid JSON", %{test_agents_dir: dir} do
      write_qa_reviewer(dir)
      write_invalid_json(dir)

      assert {:ok, agents} = SubagentCoordinator.list_agents(agents_dir: dir)
      assert length(agents) == 1
    end

    test "skips files with missing required keys", %{test_agents_dir: dir} do
      write_qa_reviewer(dir)
      write_missing_keys(dir)

      assert {:ok, agents} = SubagentCoordinator.list_agents(agents_dir: dir)
      assert length(agents) == 1
    end

    test "returns error when agents dir does not exist" do
      assert {:error, {:agents_dir_not_found, _}} =
               SubagentCoordinator.list_agents(agents_dir: "/nonexistent/path")
    end
  end

  describe "agent classification" do
    setup [:setup_test_agents_dir]

    test "classifies read-only agents correctly", %{test_agents_dir: dir} do
      write_qa_reviewer(dir)

      assert {:ok, [agent]} = SubagentCoordinator.list_agents(agents_dir: dir)
      assert agent.read_only? == true
      assert agent.write_capable? == false
      assert SubagentCoordinator.classify_agent(agent) == :read_only
    end

    test "classifies write-capable agents correctly", %{test_agents_dir: dir} do
      write_executor(dir)

      assert {:ok, [agent]} = SubagentCoordinator.list_agents(agents_dir: dir)
      assert agent.read_only? == false
      assert agent.write_capable? == true
      assert SubagentCoordinator.classify_agent(agent) == :write_capable
    end

    test "agent with shell_write tool is write-capable", %{test_agents_dir: dir} do
      write_agent_file(dir, "shell-agent", %{
        "name" => "shell-agent",
        "description" => "Has shell_write",
        "tools" => ["read", "shell_write"],
        "allowedTools" => ["read"],
        "includeMcpJson" => false,
        "model" => "claude-sonnet-4"
      })

      assert {:ok, [agent]} = SubagentCoordinator.list_agents(agents_dir: dir)
      assert agent.write_capable? == true
      assert agent.read_only? == false
    end

    test "agent with terminal tool is write-capable", %{test_agents_dir: dir} do
      write_agent_file(dir, "terminal-agent", %{
        "name" => "terminal-agent",
        "description" => "Has terminal",
        "tools" => ["read", "terminal"],
        "allowedTools" => ["read"],
        "includeMcpJson" => false,
        "model" => "claude-sonnet-4"
      })

      assert {:ok, [agent]} = SubagentCoordinator.list_agents(agents_dir: dir)
      assert agent.write_capable? == true
    end

    test "agent with destructive tool is write-capable", %{test_agents_dir: dir} do
      write_agent_file(dir, "destructive-agent", %{
        "name" => "destructive-agent",
        "description" => "Has destructive",
        "tools" => ["read", "destructive"],
        "allowedTools" => ["read"],
        "includeMcpJson" => false,
        "model" => "claude-sonnet-4"
      })

      assert {:ok, [agent]} = SubagentCoordinator.list_agents(agents_dir: dir)
      assert agent.write_capable? == true
    end
  end

  describe "list_read_only_reviewers/1" do
    setup [:setup_test_agents_dir]

    test "returns only read-only agents", %{test_agents_dir: dir} do
      write_qa_reviewer(dir)
      write_security_reviewer(dir)
      write_executor(dir)

      assert {:ok, reviewers} = SubagentCoordinator.list_read_only_reviewers(agents_dir: dir)
      assert length(reviewers) == 2
      assert Enum.all?(reviewers, & &1.read_only?)
    end

    test "excludes write-capable agents from reviewers", %{test_agents_dir: dir} do
      write_executor(dir)

      assert {:ok, reviewers} = SubagentCoordinator.list_read_only_reviewers(agents_dir: dir)
      assert reviewers == []
    end
  end

  describe "find_agent/2" do
    setup [:setup_test_agents_dir]

    test "finds agent by name", %{test_agents_dir: dir} do
      write_qa_reviewer(dir)

      assert {:ok, agent} =
               SubagentCoordinator.find_agent("kiro-cockpit-qa-reviewer", agents_dir: dir)

      assert agent.name == "kiro-cockpit-qa-reviewer"
    end

    test "returns not_found for unknown agent", %{test_agents_dir: dir} do
      write_qa_reviewer(dir)

      assert {:error, :not_found} =
               SubagentCoordinator.find_agent("nonexistent-agent", agents_dir: dir)
    end
  end

  # ── Tests: Invocation gating ────────────────────────────────────────

  describe "check_invocation_allowed/2" do
    test "allows read-only reviewer before approval" do
      agent = %{read_only?: true, write_capable?: false}
      assert :ok = SubagentCoordinator.check_invocation_allowed(agent, false)
    end

    test "allows read-only reviewer after approval" do
      agent = %{read_only?: true, write_capable?: false}
      assert :ok = SubagentCoordinator.check_invocation_allowed(agent, true)
    end

    test "blocks implementation subagent before approval (§25.3 R3)" do
      agent = %{read_only?: false, write_capable?: true}

      assert {:error, {:subagent_blocked, reason, guidance}} =
               SubagentCoordinator.check_invocation_allowed(agent, false)

      assert reason =~ "implementation subagent blocked before approval"
      assert guidance =~ "§25.3 R3"
    end

    test "allows implementation subagent after approval" do
      agent = %{read_only?: false, write_capable?: true}
      assert :ok = SubagentCoordinator.check_invocation_allowed(agent, true)
    end
  end

  # ── Tests: Reviewer invocation ───────────────────────────────────────

  describe "invoke_reviewer/5" do
    setup [:setup_test_agents_dir]

    setup %{test_agents_dir: dir} do
      plan = create_test_plan()
      correlation = default_correlation(plan.id)

      Process.put(:fake_reviewer_prompt_calls, [])
      Process.put(:fake_reviewer_prompt_result, {:ok, %{"findings" => ["test finding"]}})

      on_exit(fn ->
        Process.delete(:fake_reviewer_prompt_calls)
        Process.delete(:fake_reviewer_prompt_result)
      end)

      %{plan: plan, correlation: correlation, test_agents_dir: dir}
    end

    test "invokes read-only reviewer and persists output", %{
      correlation: correlation,
      test_agents_dir: dir
    } do
      write_qa_reviewer(dir)

      assert {:ok, result} =
               SubagentCoordinator.invoke_reviewer(
                 :fake_session,
                 "kiro-cockpit-qa-reviewer",
                 "Review this plan for testability",
                 correlation,
                 kiro_session_module: FakeKiroSession,
                 agents_dir: dir
               )

      assert result.agent.name == "kiro-cockpit-qa-reviewer"
      assert result.correlation.plan_id == correlation.plan_id
      assert result.persisted_event != nil
    end

    test "binds correlation context into prompt opts", %{
      correlation: correlation,
      test_agents_dir: dir
    } do
      write_security_reviewer(dir)

      assert {:ok, _result} =
               SubagentCoordinator.invoke_reviewer(
                 :fake_session,
                 "kiro-cockpit-security-reviewer",
                 "Review for security issues",
                 correlation,
                 kiro_session_module: FakeKiroSession,
                 agents_dir: dir
               )

      [{_prompt, opts}] = Process.get(:fake_reviewer_prompt_calls, [])
      assert Keyword.get(opts, :agent_id) == correlation.agent_id
      assert Keyword.get(opts, :parent_session_id) == correlation.parent_session_id
      assert Keyword.get(opts, :plan_id) == correlation.plan_id
      assert Keyword.get(opts, :subagent_name) == "kiro-cockpit-security-reviewer"
    end

    test "rejects write-capable agent via invoke_reviewer", %{
      correlation: correlation,
      test_agents_dir: dir
    } do
      write_executor(dir)

      assert {:error, {:reviewer_not_read_only, msg}} =
               SubagentCoordinator.invoke_reviewer(
                 :fake_session,
                 "kiro-cockpit-executor",
                 "Execute this",
                 correlation,
                 kiro_session_module: FakeKiroSession,
                 agents_dir: dir
               )

      assert msg =~ "write-capable tools"
    end

    test "returns error for unknown agent", %{
      correlation: correlation,
      test_agents_dir: dir
    } do
      write_qa_reviewer(dir)

      assert {:error, :not_found} =
               SubagentCoordinator.invoke_reviewer(
                 :fake_session,
                 "nonexistent-reviewer",
                 "Review",
                 correlation,
                 kiro_session_module: FakeKiroSession,
                 agents_dir: dir
               )
    end

    test "persists reviewer output as plan event", %{
      correlation: correlation,
      test_agents_dir: dir
    } do
      write_qa_reviewer(dir)

      assert {:ok, result} =
               SubagentCoordinator.invoke_reviewer(
                 :fake_session,
                 "kiro-cockpit-qa-reviewer",
                 "Review",
                 correlation,
                 kiro_session_module: FakeKiroSession,
                 agents_dir: dir
               )

      assert result.persisted_event.event_type == "reviewer_output"
      assert result.persisted_event.plan_id == correlation.plan_id
      assert result.persisted_event.payload["agent_name"] == "kiro-cockpit-qa-reviewer"
      assert result.persisted_event.payload["agent_read_only"] == true
    end
  end

  # ── Tests: Subagent invocation (with approval gating) ────────────────

  describe "invoke_subagent/5" do
    setup [:setup_test_agents_dir]

    setup %{test_agents_dir: dir} do
      plan = create_test_plan()
      correlation = default_correlation(plan.id)

      Process.put(:fake_reviewer_prompt_calls, [])
      Process.put(:fake_reviewer_prompt_result, {:ok, %{"result" => "done"}})

      on_exit(fn ->
        Process.delete(:fake_reviewer_prompt_calls)
        Process.delete(:fake_reviewer_prompt_result)
      end)

      %{plan: plan, correlation: correlation, test_agents_dir: dir}
    end

    test "allows read-only subagent before approval", %{
      correlation: correlation,
      test_agents_dir: dir
    } do
      write_qa_reviewer(dir)

      assert {:ok, result} =
               SubagentCoordinator.invoke_subagent(
                 :fake_session,
                 "kiro-cockpit-qa-reviewer",
                 "Review",
                 correlation,
                 kiro_session_module: FakeKiroSession,
                 agents_dir: dir,
                 plan_approved?: false
               )

      assert result.agent.name == "kiro-cockpit-qa-reviewer"
    end

    test "blocks implementation subagent before approval", %{
      correlation: correlation,
      test_agents_dir: dir
    } do
      write_executor(dir)

      assert {:error, {:subagent_blocked, _reason, _guidance}} =
               SubagentCoordinator.invoke_subagent(
                 :fake_session,
                 "kiro-cockpit-executor",
                 "Execute",
                 correlation,
                 kiro_session_module: FakeKiroSession,
                 agents_dir: dir,
                 plan_approved?: false
               )
    end

    test "allows implementation subagent after approval", %{
      correlation: correlation,
      test_agents_dir: dir
    } do
      write_executor(dir)

      assert {:ok, result} =
               SubagentCoordinator.invoke_subagent(
                 :fake_session,
                 "kiro-cockpit-executor",
                 "Execute the approved plan",
                 correlation,
                 kiro_session_module: FakeKiroSession,
                 agents_dir: dir,
                 plan_approved?: true
               )

      assert result.agent.name == "kiro-cockpit-executor"
    end
  end

  # ── Tests: Persistence ──────────────────────────────────────────────

  describe "persist_reviewer_output/4" do
    setup do
      plan = create_test_plan()
      %{plan: plan}
    end

    test "persists event atomically via Ecto.Multi", %{plan: plan} do
      agent = %{
        name: "kiro-cockpit-qa-reviewer",
        read_only?: true,
        write_capable?: false
      }

      correlation = default_correlation(plan.id)

      output = %{"findings" => ["Missing test coverage"], "severity" => "medium"}

      assert {:ok, event} =
               SubagentCoordinator.persist_reviewer_output(correlation, agent, output, [])

      assert event.event_type == "reviewer_output"
      assert event.plan_id == plan.id
      assert event.payload["agent_name"] == "kiro-cockpit-qa-reviewer"
      assert event.payload["agent_read_only"] == true
      assert event.payload["output"]["findings"] == ["Missing test coverage"]
    end

    test "redacts sensitive fields in output", %{plan: plan} do
      agent = %{
        name: "kiro-cockpit-security-reviewer",
        read_only?: true,
        write_capable?: false
      }

      correlation = default_correlation(plan.id)

      output = %{
        "findings" => ["SQL injection risk"],
        "api_key" => "sk-secret-123",
        "password" => "hunter2",
        "auth_token" => "tok-abc",
        "safe_field" => "this is fine"
      }

      assert {:ok, event} =
               SubagentCoordinator.persist_reviewer_output(correlation, agent, output, [])

      assert event.payload["output"]["api_key"] == "[REDACTED]"
      assert event.payload["output"]["password"] == "[REDACTED]"
      assert event.payload["output"]["auth_token"] == "[REDACTED]"
      assert event.payload["output"]["safe_field"] == "this is fine"
      assert event.payload["output"]["findings"] == ["SQL injection risk"]
    end

    test "handles binary output by wrapping in map", %{plan: plan} do
      agent = %{
        name: "kiro-cockpit-qa-reviewer",
        read_only?: true,
        write_capable?: false
      }

      correlation = default_correlation(plan.id)

      assert {:ok, event} =
               SubagentCoordinator.persist_reviewer_output(
                 correlation,
                 agent,
                 "Simple text review output",
                 []
               )

      assert event.payload["output"]["raw_text"] =~ "Simple text review output"
    end
  end

  describe "list_reviewer_outputs/1" do
    setup do
      plan = create_test_plan()
      %{plan: plan}
    end

    test "returns reviewer output events for a plan", %{plan: plan} do
      agent = %{
        name: "kiro-cockpit-qa-reviewer",
        read_only?: true,
        write_capable?: false
      }

      correlation = default_correlation(plan.id)

      {:ok, _event} =
        SubagentCoordinator.persist_reviewer_output(
          correlation,
          agent,
          %{"findings" => ["test"]},
          []
        )

      outputs = SubagentCoordinator.list_reviewer_outputs(plan.id)
      assert length(outputs) == 1
      assert hd(outputs).event_type == "reviewer_output"
    end

    test "returns empty list for plan with no reviewer outputs", %{plan: plan} do
      outputs = SubagentCoordinator.list_reviewer_outputs(plan.id)
      assert outputs == []
    end
  end

  # ── Tests: Real agent file loading ──────────────────────────────────

  describe "loading real .kiro/agents files" do
    test "loads actual project agent definitions" do
      # This test validates the real .kiro/agents/*.json files
      assert {:ok, agents} = SubagentCoordinator.list_agents(agents_dir: @agents_dir)

      names = Enum.map(agents, & &1.name) |> Enum.sort()

      # At minimum, we should have the original two + two new reviewers
      assert "kiro-cockpit-nano-planner" in names
      assert "kiro-cockpit-executor" in names
      assert "kiro-cockpit-qa-reviewer" in names
      assert "kiro-cockpit-security-reviewer" in names
    end

    test "new reviewers are classified as read-only" do
      assert {:ok, agents} = SubagentCoordinator.list_agents(agents_dir: @agents_dir)

      qa = Enum.find(agents, &(&1.name == "kiro-cockpit-qa-reviewer"))
      sec = Enum.find(agents, &(&1.name == "kiro-cockpit-security-reviewer"))

      assert qa.read_only? == true
      assert qa.write_capable? == false
      assert sec.read_only? == true
      assert sec.write_capable? == false
    end

    test "executor is classified as write-capable" do
      assert {:ok, agents} = SubagentCoordinator.list_agents(agents_dir: @agents_dir)

      executor = Enum.find(agents, &(&1.name == "kiro-cockpit-executor"))

      assert executor.read_only? == false
      assert executor.write_capable? == true
    end
  end

  # ── Parametrized gating tests ────────────────────────────────────────

  describe "invocation gating across approval states" do
    test "read-only agents are always allowed regardless of approval status" do
      agent = %{read_only?: true, write_capable?: false}
      assert :ok = SubagentCoordinator.check_invocation_allowed(agent, false)
      assert :ok = SubagentCoordinator.check_invocation_allowed(agent, true)
    end

    test "write-capable agents are blocked when plan is not approved" do
      agent = %{read_only?: false, write_capable?: true}

      assert {:error, {:subagent_blocked, _, _}} =
               SubagentCoordinator.check_invocation_allowed(agent, false)
    end

    test "write-capable agents are allowed when plan is approved" do
      agent = %{read_only?: false, write_capable?: true}
      assert :ok = SubagentCoordinator.check_invocation_allowed(agent, true)
    end
  end
end
