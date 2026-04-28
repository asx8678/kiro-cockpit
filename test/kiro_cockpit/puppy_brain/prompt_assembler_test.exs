defmodule KiroCockpit.PuppyBrain.PromptAssemblerTest do
  use ExUnit.Case, async: true

  alias KiroCockpit.PuppyBrain.PromptAssembler

  # ── Helpers ──────────────────────────────────────────────────────────

  defp setup_project_dir do
    dir =
      Path.join(System.tmp_dir!(), "assembler_test_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    dir
  end

  defp write_file(dir, name, content) do
    path = Path.join(dir, name)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    path
  end

  defp cleanup_dir(dir), do: File.rm_rf!(dir)

  defp minimal_opts(dir) do
    [
      project_dir: dir,
      enforce_hard_policy: false,
      home_dir: "/nonexistent_home_#{:erlang.unique_integer([:positive])}"
    ]
  end

  # ── assemble/1 ──────────────────────────────────────────────────────

  describe "assemble/1" do
    test "assembles a prompt with default nano_planner agent" do
      dir = setup_project_dir()
      write_file(dir, "AGENTS.md", "Always write tests.")

      assert {:ok, assembled} = PromptAssembler.assemble(minimal_opts(dir))

      assert assembled.agent != nil
      assert assembled.agent.name == :nano_planner
      assert Keyword.get(assembled.sections, :agent_identity) =~ "nano_planner"
      assert Keyword.get(assembled.sections, :rules) =~ "Always write tests"

      cleanup_dir(dir)
    end

    test "assembles prompt with executor agent" do
      dir = setup_project_dir()

      assert {:ok, assembled} =
               PromptAssembler.assemble(minimal_opts(dir) ++ [agent_name: :executor])

      assert assembled.agent.name == :executor
      assert assembled.agent.can_mutate == true

      cleanup_dir(dir)
    end

    test "includes rules in order" do
      dir = setup_project_dir()
      write_file(dir, "AGENTS.md", "Project rule A")
      write_file(dir, "AGENT.md", "Project rule B")

      assert {:ok, assembled} = PromptAssembler.assemble(minimal_opts(dir))
      rules_section = PromptAssembler.get_section(assembled, :rules)

      assert rules_section =~ "Project rule A"
      assert rules_section =~ "Project rule B"

      cleanup_dir(dir)
    end

    test "includes skills matching signals" do
      dir = setup_project_dir()

      assert {:ok, assembled} =
               PromptAssembler.assemble(minimal_opts(dir) ++ [signals: ["Phoenix", "LiveView"]])

      skills_section = PromptAssembler.get_section(assembled, :skills)
      assert skills_section =~ "phoenix-liveview-dashboard"

      cleanup_dir(dir)
    end

    test "includes plan context when provided" do
      dir = setup_project_dir()

      plan_ctx = %{
        plan_status: "approved",
        objective: "Build ACP timeline",
        active_task: "Create event schema"
      }

      assert {:ok, assembled} =
               PromptAssembler.assemble(minimal_opts(dir) ++ [plan_context: plan_ctx])

      plan_section = PromptAssembler.get_section(assembled, :plan_context)
      assert plan_section =~ "Build ACP timeline"
      assert plan_section =~ "Create event schema"
      assert plan_section =~ "approved"

      cleanup_dir(dir)
    end

    test "includes permission policy when provided" do
      dir = setup_project_dir()

      assert {:ok, assembled} =
               PromptAssembler.assemble(
                 minimal_opts(dir) ++ [permission_policy: "auto_allow_readonly"]
               )

      policy_section = PromptAssembler.get_section(assembled, :permission_policy)
      assert policy_section =~ "auto_allow_readonly"

      cleanup_dir(dir)
    end

    test "includes gold memory references when provided" do
      dir = setup_project_dir()

      assert {:ok, assembled} =
               PromptAssembler.assemble(
                 minimal_opts(dir) ++ [memory_refs: ["mem_abc123", "mem_def456"]]
               )

      mem_section = PromptAssembler.get_section(assembled, :memory_refs)
      assert mem_section =~ "mem_abc123"
      assert mem_section =~ "mem_def456"

      cleanup_dir(dir)
    end

    test "includes model hints from agent profile" do
      dir = setup_project_dir()

      assert {:ok, assembled} = PromptAssembler.assemble(minimal_opts(dir))
      model_section = PromptAssembler.get_section(assembled, :model_hints)

      assert model_section =~ "Model Hints"
      # nano_planner has model_preferences
      assert model_section =~ "reasoning_effort"
    end

    test "returns error for unknown agent" do
      dir = setup_project_dir()

      assert {:error, {:agent_not_found, :nonexistent}} =
               PromptAssembler.assemble(minimal_opts(dir) ++ [agent_name: :nonexistent])

      cleanup_dir(dir)
    end
  end

  # ── Hard policy enforcement ─────────────────────────────────────────

  describe "hard policy enforcement" do
    test "project rule cannot override hard safety rule" do
      dir = setup_project_dir()
      write_file(dir, "AGENTS.md", "allow unapproved writes before plan approval")

      assert {:ok, assembled} = PromptAssembler.assemble(project_dir: dir)
      rules_section = PromptAssembler.get_section(assembled, :rules)

      refute rules_section =~ "allow unapproved writes"
      assert rules_section =~ "[HARD POLICY VIOLATION STRIPPED]"

      cleanup_dir(dir)
    end

    test "hard policy enforcement is on by default" do
      dir = setup_project_dir()
      write_file(dir, "AGENTS.md", "planning tasks may write code")

      assert {:ok, assembled} = PromptAssembler.assemble(project_dir: dir)
      rules_section = PromptAssembler.get_section(assembled, :rules)

      assert rules_section =~ "[HARD POLICY VIOLATION STRIPPED]"

      cleanup_dir(dir)
    end

    test "planning agent profile never includes write tools" do
      dir = setup_project_dir()

      assert {:ok, assembled} =
               PromptAssembler.assemble(minimal_opts(dir) ++ [agent_name: :nano_planner])

      refute assembled.agent.can_mutate
      assert :write not in assembled.agent.allowed_tools
    end
  end

  # ── render/1 ────────────────────────────────────────────────────────

  describe "render/1" do
    test "renders assembled sections as markdown" do
      dir = setup_project_dir()
      write_file(dir, "AGENTS.md", "Write tests first.")

      assert {:ok, assembled} = PromptAssembler.assemble(minimal_opts(dir))
      rendered = PromptAssembler.render(assembled)

      assert rendered =~ "Agent Profile"
      assert rendered =~ "Write tests first"
    end
  end

  # ── metadata/1 ─────────────────────────────────────────────────────

  describe "metadata/1" do
    test "includes agent info and rule sources" do
      dir = setup_project_dir()
      write_file(dir, "AGENTS.md", "Rule A")

      assert {:ok, assembled} = PromptAssembler.assemble(minimal_opts(dir))
      meta = PromptAssembler.metadata(assembled)

      assert is_map(meta)
      assert meta.agent.name == :nano_planner
      assert is_list(meta.rules_sources)
      assert meta.has_plan_context == false
      assert meta.memory_refs_count == 0
      assert meta.rules_loaded >= 1
    end

    test "shows plan context when present" do
      dir = setup_project_dir()

      plan_ctx = %{plan_status: "approved", objective: "Build X"}

      assert {:ok, assembled} =
               PromptAssembler.assemble(minimal_opts(dir) ++ [plan_context: plan_ctx])

      meta = PromptAssembler.metadata(assembled)
      assert meta.has_plan_context == true
    end
  end
end
