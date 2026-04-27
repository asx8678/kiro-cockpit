defmodule KiroCockpit.PuppyBrain.AgentProfileTest do
  use ExUnit.Case, async: true

  alias KiroCockpit.PuppyBrain.AgentProfile

  describe "new/1" do
    test "creates a profile with required fields" do
      profile =
        AgentProfile.new(
          name: :test_agent,
          description: "A test agent",
          allowed_tools: [:read, :grep],
          allowed_categories: ["researching"],
          purpose: :planning
        )

      assert profile.name == :test_agent
      assert profile.description == "A test agent"
      assert profile.allowed_tools == [:read, :grep]
      assert profile.allowed_categories == ["researching"]
      assert profile.purpose == :planning
    end

    test "computes can_mutate as false for read-only tools" do
      profile =
        AgentProfile.new(
          name: :reader,
          description: "Read-only",
          allowed_tools: [:read, :grep],
          allowed_categories: ["researching"],
          purpose: :planning
        )

      refute AgentProfile.can_mutate?(profile)
    end

    test "computes can_mutate as true when write tool is present" do
      profile =
        AgentProfile.new(
          name: :writer,
          description: "Can write",
          allowed_tools: [:read, :write],
          allowed_categories: ["acting"],
          purpose: :execution
        )

      assert AgentProfile.can_mutate?(profile)
    end

    test "computes can_mutate as true for shell_write" do
      profile =
        AgentProfile.new(
          name: :sheller,
          description: "Shell writer",
          allowed_tools: [:read, :shell_write],
          allowed_categories: ["acting"],
          purpose: :execution
        )

      assert AgentProfile.can_mutate?(profile)
    end

    test "computes can_mutate as true for terminal" do
      profile =
        AgentProfile.new(
          name: :terminal_agent,
          description: "Terminal",
          allowed_tools: [:read, :terminal],
          allowed_categories: ["acting"],
          purpose: :execution
        )

      assert AgentProfile.can_mutate?(profile)
    end

    test "computes can_mutate as true for destructive" do
      profile =
        AgentProfile.new(
          name: :destructive_agent,
          description: "Destructive",
          allowed_tools: [:read, :destructive],
          allowed_categories: ["acting"],
          purpose: :execution
        )

      assert AgentProfile.can_mutate?(profile)
    end

    test "computes can_mutate as true for memory_write" do
      profile =
        AgentProfile.new(
          name: :memory_agent,
          description: "Memory writer",
          allowed_tools: [:read, :memory_write],
          allowed_categories: ["acting"],
          purpose: :execution
        )

      assert AgentProfile.can_mutate?(profile)
    end

    test "defaults model_preferences to empty map" do
      profile =
        AgentProfile.new(
          name: :test,
          description: "Test",
          allowed_tools: [:read],
          allowed_categories: ["researching"],
          purpose: :planning
        )

      assert profile.model_preferences == %{}
    end

    test "accepts optional system_prompt_path" do
      profile =
        AgentProfile.new(
          name: :test,
          description: "Test",
          allowed_tools: [:read],
          allowed_categories: ["researching"],
          purpose: :planning,
          system_prompt_path: "priv/prompts/test.md"
        )

      assert profile.system_prompt_path == "priv/prompts/test.md"
    end
  end

  describe "has_tool?/2" do
    test "returns true for allowed tool" do
      profile =
        AgentProfile.new(
          name: :test,
          description: "Test",
          allowed_tools: [:read, :grep],
          allowed_categories: ["researching"],
          purpose: :planning
        )

      assert AgentProfile.has_tool?(profile, :read)
      assert AgentProfile.has_tool?(profile, :grep)
    end

    test "returns false for absent tool" do
      profile =
        AgentProfile.new(
          name: :test,
          description: "Test",
          allowed_tools: [:read],
          allowed_categories: ["researching"],
          purpose: :planning
        )

      refute AgentProfile.has_tool?(profile, :write)
    end
  end

  describe "allows_category?/2" do
    test "returns true for allowed category" do
      profile =
        AgentProfile.new(
          name: :test,
          description: "Test",
          allowed_tools: [:read],
          allowed_categories: ["researching", "planning"],
          purpose: :planning
        )

      assert AgentProfile.allows_category?(profile, "researching")
      assert AgentProfile.allows_category?(profile, "planning")
    end

    test "returns false for absent category" do
      profile =
        AgentProfile.new(
          name: :test,
          description: "Test",
          allowed_tools: [:read],
          allowed_categories: ["researching"],
          purpose: :planning
        )

      refute AgentProfile.allows_category?(profile, "acting")
    end
  end

  describe "to_metadata/1" do
    test "produces a debug-safe map" do
      profile =
        AgentProfile.new(
          name: :test,
          description: "A test agent",
          allowed_tools: [:read],
          allowed_categories: ["researching"],
          purpose: :planning
        )

      meta = AgentProfile.to_metadata(profile)

      assert meta.name == :test
      assert meta.description == "A test agent"
      assert meta.allowed_tools == [:read]
      assert meta.purpose == :planning
      assert meta.can_mutate == false
      # No raw content or secrets
      refute Map.has_key?(meta, :system_prompt_path)
    end
  end
end
