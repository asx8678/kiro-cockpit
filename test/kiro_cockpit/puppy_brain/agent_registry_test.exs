defmodule KiroCockpit.PuppyBrain.AgentRegistryTest do
  use ExUnit.Case, async: true

  alias KiroCockpit.PuppyBrain.{AgentProfile, AgentRegistry}

  # ── new/0 ───────────────────────────────────────────────────────────

  describe "new/0" do
    test "creates an empty registry" do
      reg = AgentRegistry.new()
      assert AgentRegistry.list_names(reg) == []
    end
  end

  # ── with_builtins/0 ─────────────────────────────────────────────────

  describe "with_builtins/0" do
    test "includes all six built-in profiles" do
      reg = AgentRegistry.with_builtins()
      names = AgentRegistry.list_names(reg)

      assert :nano_planner in names
      assert :executor in names
      assert :reviewer in names
      assert :qa in names
      assert :security in names
      assert :docs in names
    end

    test "nano_planner is read-only (cannot mutate)" do
      reg = AgentRegistry.with_builtins()
      {:ok, planner} = AgentRegistry.lookup(reg, :nano_planner)

      refute AgentProfile.can_mutate?(planner)
      assert planner.purpose == :planning
      assert :read in planner.allowed_tools
      assert :write not in planner.allowed_tools
    end

    test "executor can mutate" do
      reg = AgentRegistry.with_builtins()
      {:ok, executor} = AgentRegistry.lookup(reg, :executor)

      assert AgentProfile.can_mutate?(executor)
      assert executor.purpose == :execution
      assert :write in executor.allowed_tools
    end

    test "reviewer is read-only" do
      reg = AgentRegistry.with_builtins()
      {:ok, reviewer} = AgentRegistry.lookup(reg, :reviewer)

      refute AgentProfile.can_mutate?(reviewer)
      assert reviewer.purpose == :verification
    end

    test "security is read-only" do
      reg = AgentRegistry.with_builtins()
      {:ok, security} = AgentRegistry.lookup(reg, :security)

      refute AgentProfile.can_mutate?(security)
      assert security.purpose == :verification
    end

    test "docs agent can write" do
      reg = AgentRegistry.with_builtins()
      {:ok, docs} = AgentRegistry.lookup(reg, :docs)

      assert AgentProfile.can_mutate?(docs)
      assert :write in docs.allowed_tools
      assert docs.purpose == :documentation
    end

    test "qa agent has shell_read but not shell_write" do
      reg = AgentRegistry.with_builtins()
      {:ok, qa} = AgentRegistry.lookup(reg, :qa)

      assert :shell_read in qa.allowed_tools
      assert :shell_write not in qa.allowed_tools
      refute AgentProfile.can_mutate?(qa)
    end
  end

  # ── register/2 ──────────────────────────────────────────────────────

  describe "register/2" do
    test "registers a custom agent profile" do
      reg = AgentRegistry.new()

      profile =
        AgentProfile.new(
          name: :custom_agent,
          description: "Custom",
          allowed_tools: [:read],
          allowed_categories: ["researching"],
          purpose: :planning
        )

      assert {:ok, reg2} = AgentRegistry.register(reg, profile)
      assert AgentRegistry.lookup(reg2, :custom_agent) == {:ok, profile}
    end

    test "rejects duplicate agent name" do
      reg = AgentRegistry.new()

      profile =
        AgentProfile.new(
          name: :dup,
          description: "First",
          allowed_tools: [:read],
          allowed_categories: ["researching"],
          purpose: :planning
        )

      {:ok, reg2} = AgentRegistry.register(reg, profile)
      assert {:error, {:already_registered, :dup}} = AgentRegistry.register(reg2, profile)
    end
  end

  # ── lookup/2 ────────────────────────────────────────────────────────

  describe "lookup/2" do
    test "returns not_found for unknown agent" do
      reg = AgentRegistry.new()
      assert {:error, :not_found} = AgentRegistry.lookup(reg, :nonexistent)
    end
  end

  # ── select_for_purpose/2 ────────────────────────────────────────────

  describe "select_for_purpose/2" do
    test "selects agent by purpose" do
      reg = AgentRegistry.with_builtins()
      assert {:ok, agent} = AgentRegistry.select_for_purpose(reg, :planning)
      assert agent.name == :nano_planner
    end

    test "returns not_found for unknown purpose" do
      reg = AgentRegistry.new()
      assert {:error, :not_found} = AgentRegistry.select_for_purpose(reg, :planning)
    end
  end

  # ── for_category/2 ──────────────────────────────────────────────────

  describe "for_category/2" do
    test "returns agents that allow the given category" do
      reg = AgentRegistry.with_builtins()
      verifying = AgentRegistry.for_category(reg, "verifying")

      verifying_names = Enum.map(verifying, & &1.name)
      assert :reviewer in verifying_names
      assert :security in verifying_names
      assert :executor in verifying_names
      assert :qa in verifying_names
    end

    test "returns empty list for nonexistent category" do
      reg = AgentRegistry.with_builtins()
      assert AgentRegistry.for_category(reg, "time_travel") == []
    end
  end

  # ── to_metadata/1 ──────────────────────────────────────────────────

  describe "to_metadata/1" do
    test "produces debug-safe metadata for all profiles" do
      reg = AgentRegistry.with_builtins()
      meta = AgentRegistry.to_metadata(reg)

      assert is_list(meta)
      assert length(meta) == 6
      assert Enum.all?(meta, &is_map/1)
    end
  end
end
