defmodule KiroCockpit.PromptValidationTest do
  @moduledoc """
  Validates that required prompt files exist and contain expected placeholders/sections.
  """
  use ExUnit.Case, async: true

  describe "nano_planner_system_prompt.md" do
    @path "priv/prompts/nano_planner_system_prompt.md"

    test "exists" do
      assert File.exists?(@path), "Expected prompt file at #{@path}"
    end

    test "contains planning-only behavior" do
      content = File.read!(@path)
      assert content =~ "You are not the implementer during planning mode"
    end

    test "contains read-only pre-approval boundary" do
      content = File.read!(@path)
      assert content =~ "Strict safety boundary"
      assert content =~ "Before user approval"
    end

    test "contains concrete project-context grounding" do
      content = File.read!(@path)
      assert content =~ "Read-only discovery policy"
    end

    test "contains output contract with plan_markdown + execution_prompt" do
      content = File.read!(@path)
      assert content =~ "Output contract"
      assert content =~ "plan_markdown"
      assert content =~ "execution_prompt"
    end

    test "contains permission, risk, acceptance sections" do
      content = File.read!(@path)
      assert content =~ "PERMISSIONS NEEDED"
      assert content =~ "ACCEPTANCE CRITERIA"
      assert content =~ "RISKS AND MITIGATIONS"
    end

    test "contains no hidden uncertainty instruction" do
      content = File.read!(@path)
      assert content =~ "Do not hide uncertainty"
    end
  end

  describe "nano_runtime_wrapper.md" do
    @path "priv/prompts/nano_runtime_wrapper.md"

    test "exists" do
      assert File.exists?(@path), "Expected prompt file at #{@path}"
    end

    test "contains required template placeholders" do
      content = File.read!(@path)
      assert content =~ "{{user_request}}"
      assert content =~ "{{session_summary}}"
      assert content =~ "{{project_snapshot}}"
      assert content =~ "{{kiro_plan_summary}}"
      assert content =~ "{{mode}}"
    end

    test "requests JSON matching NanoPlanner.PlanSchema" do
      content = File.read!(@path)
      assert content =~ "Return a JSON object matching `NanoPlanner.PlanSchema`"
    end
  end

  describe "kiro_executor_system_prompt.md" do
    @path "priv/prompts/kiro_executor_system_prompt.md"

    test "exists" do
      assert File.exists?(@path), "Expected prompt file at #{@path}"
    end

    test "contains required placeholders" do
      content = File.read!(@path)
      assert content =~ "{{approved_plan}}"
      assert content =~ "{{active_task}}"
      assert content =~ "{{permission_policy}}"
      assert content =~ "{{project_rules}}"
      assert content =~ "{{gold_memories}}"
    end

    test "contains hard rules for execution" do
      content = File.read!(@path)
      assert content =~ "Hard rules:"
      assert content =~ "Follow the approved plan and active task"
      assert content =~ "Read relevant files before modifying them"
    end
  end
end
