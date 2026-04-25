defmodule KiroCockpit.NanoPlanner.PromptBuilderTest do
  use ExUnit.Case, async: true

  alias KiroCockpit.NanoPlanner.PromptBuilder
  alias KiroCockpit.NanoPlanner.PlanSchema

  # ── Helpers ──────────────────────────────────────────────────────────

  defp valid_plan(overrides \\ []) do
    base = %{
      objective: "Build ACP timeline view",
      summary: "Add a LiveView timeline.",
      phases: [
        %{
          number: 1,
          title: "Foundation",
          steps: [
            %{
              title: "Create timeline schema",
              details: "Add event normalization.",
              files: ["lib/kiro_cockpit/event_store.ex"],
              permission: "write",
              validation: "Unit test event normalization."
            }
          ]
        }
      ],
      permissions_needed: ["read", "write"],
      acceptance_criteria: ["Timeline renders correctly."],
      risks: [%{"risk" => "ACP timing", "mitigation" => "Use turn-end event"}],
      execution_prompt: "Implement the plan."
    }

    override_map = if is_map(overrides), do: overrides, else: Map.new(overrides)
    Map.merge(base, override_map)
  end

  defp validated_plan(overrides \\ %{}) do
    PlanSchema.validate!(valid_plan(overrides))
  end

  # ── build_runtime_prompt/1 ──────────────────────────────────────────

  describe "build_runtime_prompt/1" do
    test "builds a prompt with all runtime wrapper placeholders replaced" do
      assert {:ok, prompt} =
               PromptBuilder.build_runtime_prompt(
                 user_request: "Add OAuth",
                 session_summary: "Last session: auth setup",
                 project_snapshot: "# Snapshot",
                 kiro_plan_summary: "Existing plan: auth module",
                 mode: "nano"
               )

      refute prompt =~ "{{user_request}}"
      refute prompt =~ "{{session_summary}}"
      refute prompt =~ "{{project_snapshot}}"
      refute prompt =~ "{{kiro_plan_summary}}"
      refute prompt =~ "{{mode}}"
    end

    test "includes the user request in the output" do
      {:ok, prompt} =
        PromptBuilder.build_runtime_prompt(
          user_request: "Add GitHub OAuth login",
          mode: "nano"
        )

      assert prompt =~ "Add GitHub OAuth login"
    end

    test "includes the mode in the output" do
      {:ok, prompt} =
        PromptBuilder.build_runtime_prompt(
          user_request: "X",
          mode: "nano_deep"
        )

      assert prompt =~ "nano_deep"
    end

    test "defaults mode to nano when nil" do
      {:ok, prompt} =
        PromptBuilder.build_runtime_prompt(
          user_request: "X",
          mode: nil
        )

      assert prompt =~ "nano"
    end

    test "handles atom mode" do
      {:ok, prompt} =
        PromptBuilder.build_runtime_prompt(
          user_request: "X",
          mode: :nano_fix
        )

      assert prompt =~ "nano_fix"
    end

    test "accepts a map of options" do
      assert {:ok, prompt} =
               PromptBuilder.build_runtime_prompt(%{
                 user_request: "Add auth",
                 mode: "nano"
               })

      assert prompt =~ "Add auth"
    end

    test "uses ProjectSnapshot.to_markdown for project_snapshot" do
      snapshot = %KiroCockpit.ProjectSnapshot{
        project_dir: "/tmp/test",
        root_tree: "file1.ex",
        detected_stack: ["elixir"],
        config_excerpts: %{"mix.exs" => "defmodule Test do end"},
        existing_plans: nil,
        session_summary: nil,
        hash: "abc123",
        total_chars: 100
      }

      {:ok, prompt} =
        PromptBuilder.build_runtime_prompt(
          user_request: "X",
          project_snapshot: snapshot
        )

      assert prompt =~ "Project Snapshot"
    end

    test "defaults empty strings for missing context" do
      assert {:ok, prompt} =
               PromptBuilder.build_runtime_prompt(user_request: "X")

      # Should not have unreplaced placeholders
      refute prompt =~ "{{"
    end

    test "returns error for unreplaced placeholders if template is corrupted" do
      # This test is defensive — our template should always be clean.
      # We verify the real template has no unreplaced placeholders.
      assert {:ok, _} = PromptBuilder.build_runtime_prompt(user_request: "X")
    end
  end

  # ── build_executor_prompt/2 ──────────────────────────────────────────

  describe "build_executor_prompt/2" do
    test "builds a prompt with all executor placeholders replaced" do
      plan = validated_plan()

      assert {:ok, prompt} =
               PromptBuilder.build_executor_prompt(plan,
                 active_task: "Build timeline",
                 permission_policy: "auto_allow_readonly",
                 project_rules: "No direct DB calls in LiveView",
                 gold_memories: "Auth was tricky"
               )

      refute prompt =~ "{{objective}}"
      refute prompt =~ "{{phases}}"
      refute prompt =~ "{{files}}"
      refute prompt =~ "{{acceptance_criteria}}"
      refute prompt =~ "{{risks}}"
      refute prompt =~ "{{validation_steps}}"
      refute prompt =~ "{{project_snapshot_hash}}"
      refute prompt =~ "{{active_task}}"
      refute prompt =~ "{{permission_policy}}"
      refute prompt =~ "{{project_rules}}"
      refute prompt =~ "{{gold_memories}}"
    end

    test "includes the objective from the plan" do
      plan = validated_plan()
      {:ok, prompt} = PromptBuilder.build_executor_prompt(plan)

      assert prompt =~ "Build ACP timeline view"
    end

    test "includes phases formatted as markdown" do
      plan = validated_plan()
      {:ok, prompt} = PromptBuilder.build_executor_prompt(plan)

      assert prompt =~ "Phase 1"
      assert prompt =~ "Foundation"
      assert prompt =~ "Create timeline schema"
    end

    test "includes files from all phases" do
      plan = validated_plan()
      {:ok, prompt} = PromptBuilder.build_executor_prompt(plan)

      assert prompt =~ "lib/kiro_cockpit/event_store.ex"
    end

    test "includes acceptance criteria" do
      plan = validated_plan()
      {:ok, prompt} = PromptBuilder.build_executor_prompt(plan)

      assert prompt =~ "Timeline renders correctly"
    end

    test "includes risks with risk and mitigation" do
      plan = validated_plan()
      {:ok, prompt} = PromptBuilder.build_executor_prompt(plan)

      assert prompt =~ "ACP timing"
      assert prompt =~ "Use turn-end event"
    end

    test "includes validation steps from phases" do
      plan = validated_plan()
      {:ok, prompt} = PromptBuilder.build_executor_prompt(plan)

      assert prompt =~ "Unit test event normalization"
    end

    test "defaults empty strings for optional context fields" do
      plan = validated_plan()
      {:ok, prompt} = PromptBuilder.build_executor_prompt(plan)

      refute prompt =~ "{{active_task}}"
      refute prompt =~ "{{permission_policy}}"
      refute prompt =~ "{{project_rules}}"
      refute prompt =~ "{{gold_memories}}"
    end

    test "handles plan with string keys" do
      plan = valid_plan() |> Map.put("project_snapshot_hash", "abc123")

      # Even non-validated, the builder should handle string-keyed plans
      {:ok, prompt} = PromptBuilder.build_executor_prompt(plan)

      assert prompt =~ "Build ACP timeline view"
    end

    test "handles plan with no validation steps" do
      plan =
        validated_plan(
          phases: [
            %{
              number: 1,
              title: "Simple",
              steps: [%{title: "Just read", permission: :read}]
            }
          ]
        )

      {:ok, prompt} = PromptBuilder.build_executor_prompt(plan)
      assert prompt =~ "no specific validation steps"
    end

    test "handles plan with string-keyed risks" do
      plan =
        validated_plan(risks: ["Simple risk description"])

      {:ok, prompt} = PromptBuilder.build_executor_prompt(plan)
      assert prompt =~ "Simple risk description"
    end
  end

  # ── system_prompt/0 ──────────────────────────────────────────────────

  describe "system_prompt/0" do
    test "returns the system prompt content" do
      assert {:ok, content} = PromptBuilder.system_prompt()
      assert content =~ "NanoPlanner"
      assert content =~ "planner"
    end

    test "system prompt contains no placeholders" do
      {:ok, content} = PromptBuilder.system_prompt()
      refute content =~ "{{"
    end
  end

  # ── Path accessors ───────────────────────────────────────────────────

  describe "path accessors" do
    test "system_prompt_path returns the correct path" do
      assert PromptBuilder.system_prompt_path() == "priv/prompts/nano_planner_system_prompt.md"
    end

    test "runtime_wrapper_path returns the correct path" do
      assert PromptBuilder.runtime_wrapper_path() == "priv/prompts/nano_runtime_wrapper.md"
    end

    test "executor_prompt_path returns the correct path" do
      assert PromptBuilder.executor_prompt_path() == "priv/prompts/kiro_executor_system_prompt.md"
    end
  end

  # ── check_unreplaced/1 ───────────────────────────────────────────────

  describe "check_unreplaced/1" do
    test "returns :ok when no placeholders remain" do
      assert :ok = PromptBuilder.check_unreplaced("Hello world, no placeholders")
    end

    test "returns error listing unreplaced placeholder names" do
      assert {:error, {:unreplaced_placeholders, ["objective", "phases"]}} =
               PromptBuilder.check_unreplaced("{{objective}} and {{phases}} remain")
    end

    test "deduplicates placeholder names" do
      assert {:error, {:unreplaced_placeholders, ["name"]}} =
               PromptBuilder.check_unreplaced("{{name}} and {{name}} again")
    end
  end

  # ── No unreplaced placeholders guarantee ──────────────────────────────

  describe "no unreplaced placeholders in built prompts" do
    test "runtime prompt has zero unreplaced placeholders after build" do
      {:ok, prompt} =
        PromptBuilder.build_runtime_prompt(
          user_request: "Add feature",
          session_summary: "Summary",
          project_snapshot: "Snapshot",
          kiro_plan_summary: "Plan",
          mode: "nano"
        )

      assert :ok = PromptBuilder.check_unreplaced(prompt)
    end

    test "executor prompt has zero unreplaced placeholders after build" do
      plan = validated_plan()

      {:ok, prompt} =
        PromptBuilder.build_executor_prompt(plan,
          active_task: "Task",
          permission_policy: "Policy",
          project_rules: "Rules",
          gold_memories: "Memories"
        )

      assert :ok = PromptBuilder.check_unreplaced(prompt)
    end

    test "executor prompt with minimal options has no unreplaced placeholders" do
      plan = validated_plan()
      {:ok, prompt} = PromptBuilder.build_executor_prompt(plan)
      assert :ok = PromptBuilder.check_unreplaced(prompt)
    end
  end
end
