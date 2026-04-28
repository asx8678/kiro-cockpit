defmodule KiroCockpit.PuppyBrain.ToolRegistryTest do
  use ExUnit.Case, async: true

  alias KiroCockpit.PuppyBrain.ToolRegistry
  alias KiroCockpit.PuppyBrain.ToolRegistry.Tool

  describe "agent_profiles/0" do
    test "returns the closed list of recognized profiles" do
      profiles = ToolRegistry.agent_profiles()

      assert :nano_planner in profiles
      assert :kiro_executor in profiles
      assert :qa_reviewer in profiles
      assert :security_reviewer in profiles
      assert :architecture_reviewer in profiles
      assert :docs_writer in profiles
    end
  end

  describe "local_tools/1" do
    test "returns tools with source :local for nano_planner" do
      tools = ToolRegistry.local_tools(:nano_planner)

      assert length(tools) > 0
      assert Enum.all?(tools, &(&1.source == :local))
      names = Enum.map(tools, & &1.name)
      assert "read_file" in names
      assert "grep" in names
      assert "ask_user_question" in names
    end

    test "returns tools with source :local for kiro_executor" do
      tools = ToolRegistry.local_tools(:kiro_executor)

      assert length(tools) > 0
      assert Enum.all?(tools, &(&1.source == :local))
      names = Enum.map(tools, & &1.name)
      assert "write_file" in names
      assert "shell" in names
    end

    test "security_reviewer has only read tools" do
      tools = ToolRegistry.local_tools(:security_reviewer)
      perms = Enum.map(tools, & &1.permission) |> Enum.uniq()

      assert perms == [:read]
    end

    test "raises on unknown profile" do
      assert_raise ArgumentError, ~r/unknown agent profile/, fn ->
        ToolRegistry.local_tools(:nonexistent_agent)
      end
    end

    test "every tool has required fields" do
      for profile <- ToolRegistry.agent_profiles() do
        tools = ToolRegistry.local_tools(profile)

        for tool <- tools do
          assert %Tool{} = tool
          assert is_binary(tool.name)
          assert tool.name != ""
          assert is_binary(tool.description)
          assert tool.description != ""
          assert tool.source == :local
          assert tool.permission in KiroCockpit.Permissions.permissions()
        end
      end
    end
  end

  describe "local_tool_names/1" do
    test "returns just the name strings" do
      names = ToolRegistry.local_tool_names(:nano_planner)

      assert is_list(names)
      assert Enum.all?(names, &is_binary/1)
    end
  end

  describe "display_name/1" do
    test "returns human-readable name for known profile" do
      assert ToolRegistry.display_name(:nano_planner) == "NanoPlanner"
    end

    test "raises on unknown profile" do
      assert_raise ArgumentError, ~r/unknown agent profile/, fn ->
        ToolRegistry.display_name(:bogus)
      end
    end
  end

  describe "external_tools/2" do
    test "returns empty list with default provider" do
      tools = ToolRegistry.external_tools("session-1")
      assert tools == []
    end

    test "uses injected provider for testing" do
      provider_mod = KiroCockpit.PuppyBrain.ToolRegistry.DefaultProvider

      tools = ToolRegistry.external_tools("session-1", external_provider: provider_mod)
      assert tools == []
    end
  end
end
