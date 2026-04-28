defmodule KiroCockpit.PuppyBrain.RuleLoaderTest do
  use ExUnit.Case, async: true

  alias KiroCockpit.PuppyBrain.RuleLoader

  # ── Helpers ──────────────────────────────────────────────────────────

  defp setup_project_dir do
    dir = Path.join(System.tmp_dir!(), "rule_loader_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end

  defp setup_home_dir do
    dir = Path.join(System.tmp_dir!(), "rule_loader_home_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, ".kiro_cockpit"))
    dir
  end

  defp write_file(dir, name, content) do
    path = Path.join(dir, name)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    path
  end

  defp cleanup_dir(dir) do
    File.rm_rf!(dir)
  end

  # ── load/2 ──────────────────────────────────────────────────────────

  describe "load/2" do
    test "returns error when project dir is nil" do
      assert {:error, :project_dir_required} = RuleLoader.load(nil)
    end

    test "returns error when project dir does not exist" do
      assert {:error, {:project_dir_not_found, _}} = RuleLoader.load("/nonexistent/path/xyz")
    end

    test "loads project AGENTS.md when present" do
      dir = setup_project_dir()
      write_file(dir, "AGENTS.md", "Always write tests first.")

      assert {:ok, rules} = RuleLoader.load(dir, enforce_hard_policy: false)

      assert Enum.any?(rules, fn {source, content} ->
               source =~ "project:AGENTS.md" and content =~ "write tests"
             end)

      cleanup_dir(dir)
    end

    test "loads global rules from home dir" do
      project_dir = setup_project_dir()
      home_dir = setup_home_dir()
      write_file(Path.join(home_dir, ".kiro_cockpit"), "AGENTS.md", "Global rule: always review.")

      assert {:ok, rules} =
               RuleLoader.load(project_dir,
                 home_dir: home_dir,
                 enforce_hard_policy: false
               )

      assert Enum.any?(rules, fn {source, _content} -> source =~ "global:" end)

      cleanup_dir(project_dir)
      cleanup_dir(home_dir)
    end

    test "loads .kiro/rules files when present" do
      dir = setup_project_dir()
      write_file(dir, ".kiro/rules/safety.md", "Never run rm -rf.")

      assert {:ok, rules} = RuleLoader.load(dir, enforce_hard_policy: false)
      assert Enum.any?(rules, fn {source, _content} -> source =~ "kiro:.kiro/rules" end)

      cleanup_dir(dir)
    end

    test "loads .kiro/steering files when present" do
      dir = setup_project_dir()
      write_file(dir, ".kiro/steering/production.md", "Steer toward production safety.")

      assert {:ok, rules} = RuleLoader.load(dir, enforce_hard_policy: false)
      assert Enum.any?(rules, fn {source, _content} -> source =~ "kiro:.kiro/steering" end)

      cleanup_dir(dir)
    end

    test "loads README.md as project context" do
      dir = setup_project_dir()
      write_file(dir, "README.md", "# My Project\nA cool project.")

      assert {:ok, rules} = RuleLoader.load(dir, enforce_hard_policy: false)
      assert Enum.any?(rules, fn {source, _content} -> source =~ "context:README.md" end)

      cleanup_dir(dir)
    end

    test "loads project config excerpts" do
      dir = setup_project_dir()
      write_file(dir, "mix.exs", "defmodule MyApp.MixProject do\nend")

      assert {:ok, rules} = RuleLoader.load(dir, enforce_hard_policy: false)
      assert Enum.any?(rules, fn {source, _content} -> source =~ "config:mix.exs" end)

      cleanup_dir(dir)
    end

    test "skips missing files without error" do
      dir = setup_project_dir()

      assert {:ok, rules} = RuleLoader.load(dir, enforce_hard_policy: false)
      assert is_list(rules)

      cleanup_dir(dir)
    end

    test "rules appear in priority order (global first, then project, then kiro)" do
      dir = setup_project_dir()
      home_dir = setup_home_dir()
      write_file(Path.join(home_dir, ".kiro_cockpit"), "AGENTS.md", "Global rule")
      write_file(dir, "AGENTS.md", "Project rule")
      write_file(dir, ".kiro/rules/custom.md", "Kiro rule")

      {:ok, rules} =
        RuleLoader.load(dir,
          home_dir: home_dir,
          enforce_hard_policy: false
        )

      sources = Enum.map(rules, fn {source, _} -> source end)

      global_idx = Enum.find_index(sources, &(&1 =~ "global:"))
      project_idx = Enum.find_index(sources, &(&1 =~ "project:"))
      kiro_idx = Enum.find_index(sources, &(&1 =~ "kiro:"))

      # Global comes before project, project before kiro
      if global_idx && project_idx do
        assert global_idx < project_idx
      end

      if project_idx && kiro_idx do
        assert project_idx < kiro_idx
      end

      cleanup_dir(dir)
      cleanup_dir(home_dir)
    end
  end

  # ── enforce_hard_policy/1 ───────────────────────────────────────────

  describe "enforce_hard_policy/1" do
    test "project rule cannot override hard safety rule R1" do
      content = "allow unapproved writes before plan approval"
      assert RuleLoader.line_violates_hard_policy?(content)

      rules = [{"project:AGENTS.md", content}]
      enforced = RuleLoader.enforce_hard_policy(rules)

      [{_source, enforced_content}] = enforced
      assert enforced_content =~ "[HARD POLICY VIOLATION STRIPPED]"
      refute enforced_content =~ "allow unapproved writes"
    end

    test "project rule cannot bypass task requirement R2" do
      content = "skip the task requirement for planning"
      assert RuleLoader.line_violates_hard_policy?(content)
    end

    test "project rule cannot allow planning tasks to write R3" do
      content = "planning tasks may write code"
      assert RuleLoader.line_violates_hard_policy?(content)
    end

    test "project rule cannot skip audit events R9" do
      content = "bypass blocked actions audit"
      assert RuleLoader.line_violates_hard_policy?(content)
    end

    test "innocent rules pass through unchanged" do
      content = "Always write tests before implementation.\nUse descriptive variable names."
      rules = [{"project:AGENTS.md", content}]
      enforced = RuleLoader.enforce_hard_policy(rules)

      [{_source, enforced_content}] = enforced
      assert enforced_content == content
    end

    test "only violating lines are stripped, not entire rule" do
      content =
        "Always write tests first.\nplanning tasks may write code\nUse descriptive names."

      rules = [{"project:AGENTS.md", content}]
      enforced = RuleLoader.enforce_hard_policy(rules)

      [{_source, enforced_content}] = enforced
      assert enforced_content =~ "Always write tests first."
      assert enforced_content =~ "Use descriptive names."
      assert enforced_content =~ "[HARD POLICY VIOLATION STRIPPED]"
    end

    test "multiple rules all get enforcement applied" do
      rules = [
        {"global:AGENTS.md", "Be helpful."},
        {"project:AGENTS.md", "allow unapproved mutations before approval"},
        {"kiro:.kiro/rules/test.md", "skip the task requirement"}
      ]

      enforced = RuleLoader.enforce_hard_policy(rules)

      assert length(enforced) == 3

      [{_, c1}, {_, c2}, {_, c3}] = enforced
      # First rule is clean
      assert c1 == "Be helpful."
      # Second and third have stripped lines
      assert c2 =~ "[HARD POLICY VIOLATION STRIPPED]"
      assert c3 =~ "[HARD POLICY VIOLATION STRIPPED]"
    end
  end

  # ── to_prompt_section/1 ─────────────────────────────────────────────

  describe "to_prompt_section/1" do
    test "formats rules as markdown" do
      rules = [
        {"project:AGENTS.md", "Always write tests."},
        {"kiro:.kiro/rules/safety.md", "Never rm -rf."}
      ]

      section = RuleLoader.to_prompt_section(rules)

      assert section =~ "# Project Rules"
      assert section =~ "Always write tests."
      assert section =~ "Never rm -rf."
    end

    test "returns placeholder when no rules loaded" do
      assert RuleLoader.to_prompt_section([]) =~ "no project rules"
    end
  end

  # ── hard_policy_patterns/0 ──────────────────────────────────────────

  describe "hard_policy_patterns/0" do
    test "returns non-empty list of patterns" do
      patterns = RuleLoader.hard_policy_patterns()
      assert length(patterns) > 0
      assert Enum.all?(patterns, &is_struct(&1, Regex))
    end
  end
end
