defmodule KiroCockpit.PuppyBrain.SkillRegistryTest do
  use ExUnit.Case, async: true

  alias KiroCockpit.PuppyBrain.SkillRegistry

  # ── new/0 ───────────────────────────────────────────────────────────

  describe "new/0" do
    test "creates an empty registry" do
      reg = SkillRegistry.new()
      assert SkillRegistry.list_names(reg) == []
    end
  end

  # ── with_builtins/0 ─────────────────────────────────────────────────

  describe "with_builtins/0" do
    test "includes built-in skills" do
      reg = SkillRegistry.with_builtins()
      names = SkillRegistry.list_names(reg)

      assert "phoenix-liveview-dashboard" in names
      assert "acp-json-rpc-debugging" in names
      assert "permission-model-hardening" in names
      assert "postgres-migration-review" in names
      assert "security-threat-model" in names
      assert "long-turn-regression-test" in names
    end
  end

  # ── register/2 ─────────────────────────────────────────────────────

  describe "register/2" do
    test "registers a valid skill" do
      reg = SkillRegistry.new()

      skill = %{
        name: "test-skill",
        description: "A test skill",
        applies_when: ["test"],
        recommended_agents: [:reviewer],
        read_first: [],
        steps: ["step 1"],
        risks: [],
        validation: []
      }

      assert {:ok, reg2} = SkillRegistry.register(reg, skill)
      assert SkillRegistry.lookup(reg2, "test-skill") == {:ok, skill}
    end

    test "rejects skill without name" do
      reg = SkillRegistry.new()

      skill = %{
        description: "No name",
        applies_when: [],
        recommended_agents: [],
        read_first: [],
        steps: [],
        risks: [],
        validation: []
      }

      assert {:error, :skill_name_required} = SkillRegistry.register(reg, skill)
    end

    test "rejects duplicate skill name" do
      reg = SkillRegistry.new()

      skill = %{
        name: "dupe",
        description: "First",
        applies_when: [],
        recommended_agents: [],
        read_first: [],
        steps: [],
        risks: [],
        validation: []
      }

      {:ok, reg2} = SkillRegistry.register(reg, skill)
      assert {:error, {:already_registered, "dupe"}} = SkillRegistry.register(reg2, skill)
    end
  end

  # ── lookup/2 ────────────────────────────────────────────────────────

  describe "lookup/2" do
    test "returns not_found for unknown skill" do
      reg = SkillRegistry.new()
      assert {:error, :not_found} = SkillRegistry.lookup(reg, "nonexistent")
    end
  end

  # ── match_signals/2 ─────────────────────────────────────────────────

  describe "match_signals/2" do
    test "matches skills by signal overlap" do
      reg = SkillRegistry.with_builtins()
      matches = SkillRegistry.match_signals(reg, ["Phoenix", "LiveView"])

      assert length(matches) > 0
      {top_skill, top_count} = hd(matches)
      assert top_skill.name == "phoenix-liveview-dashboard"
      assert top_count > 0
    end

    test "matches ACP signals" do
      reg = SkillRegistry.with_builtins()
      matches = SkillRegistry.match_signals(reg, ["ACP", "JSON-RPC", "debug"])

      names = Enum.map(matches, fn {skill, _} -> skill.name end)
      assert "acp-json-rpc-debugging" in names
    end

    test "returns empty list when no signals match" do
      reg = SkillRegistry.with_builtins()
      matches = SkillRegistry.match_signals(reg, ["quantum", "blockchain", "nft"])
      assert matches == []
    end

    test "skills are sorted by match count descending" do
      reg = SkillRegistry.new()

      SkillRegistry.register(reg, %{
        name: "broad",
        description: "Matches many",
        applies_when: ["Phoenix", "LiveView", "dashboard", "test"],
        recommended_agents: [],
        read_first: [],
        steps: [],
        risks: [],
        validation: []
      })

      SkillRegistry.register(reg, %{
        name: "narrow",
        description: "Matches few",
        applies_when: ["Phoenix"],
        recommended_agents: [],
        read_first: [],
        steps: [],
        risks: [],
        validation: []
      })

      # We need to use the returned registries
      {:ok, reg2} =
        SkillRegistry.register(reg, %{
          name: "broad",
          description: "Matches many",
          applies_when: ["Phoenix", "LiveView", "dashboard", "test"],
          recommended_agents: [],
          read_first: [],
          steps: [],
          risks: [],
          validation: []
        })

      {:ok, reg3} =
        SkillRegistry.register(reg2, %{
          name: "narrow",
          description: "Matches few",
          applies_when: ["Phoenix"],
          recommended_agents: [],
          read_first: [],
          steps: [],
          risks: [],
          validation: []
        })

      matches = SkillRegistry.match_signals(reg3, ["Phoenix", "LiveView"])

      {first_skill, first_count} = hd(matches)
      {second_skill, second_count} = Enum.at(matches, 1)

      assert first_count > second_count
      assert first_skill.name == "broad"
      assert second_skill.name == "narrow"
    end

    test "signal matching is case-insensitive" do
      reg = SkillRegistry.with_builtins()
      matches = SkillRegistry.match_signals(reg, ["phoenix", "liveview"])

      assert length(matches) > 0
    end
  end

  # ── to_prompt_section/2 ─────────────────────────────────────────────

  describe "to_prompt_section/2" do
    test "formats matching skills as markdown" do
      reg = SkillRegistry.with_builtins()
      section = SkillRegistry.to_prompt_section(reg, ["Phoenix", "LiveView"])

      assert section =~ "# Matching Skills"
      assert section =~ "phoenix-liveview-dashboard"
    end

    test "returns placeholder when no matches" do
      reg = SkillRegistry.with_builtins()
      section = SkillRegistry.to_prompt_section(reg, ["quantum"])

      assert section =~ "no matching skills"
    end
  end
end
