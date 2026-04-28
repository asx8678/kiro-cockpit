defmodule KiroCockpit.PuppyBrain.ToolCompositionIntegrationTest do
  @moduledoc """
  End-to-end two-pass tool composition tests matching the §26.7 algorithm:

      local_tools = ToolRegistry.local_tools(agent_profile)
      probe_names = ToolComposer.register_probe(local_tools) |> ToolComposer.tool_names()
      external_tools = MCP.available_tools(session)
      filtered_external = MCP.Filter.drop_name_conflicts(external_tools, probe_names)
      final_toolset = local_tools ++ filtered_external

  These tests exercise the full pipeline as a caller would use it.
  """
  use ExUnit.Case, async: true

  alias KiroCockpit.PuppyBrain.ToolRegistry
  alias KiroCockpit.PuppyBrain.ToolComposer
  alias KiroCockpit.MCP.Filter

  describe "full two-pass pipeline (§26.7 algorithm)" do
    test "nano_planner with no external tools" do
      local_tools = ToolRegistry.local_tools(:nano_planner)
      probe = ToolComposer.register_probe(local_tools)
      _probe_names = ToolComposer.tool_names(probe)
      external_tools = []
      {filtered_external, _conflicts} = Filter.drop_name_conflicts(external_tools, probe.name_set)
      final_toolset = local_tools ++ filtered_external

      assert final_toolset == local_tools
    end

    test "local tool shadows MCP tool with same name" do
      local_tools = ToolRegistry.local_tools(:nano_planner)
      probe = ToolComposer.register_probe(local_tools)
      _probe_names = ToolComposer.tool_names(probe)

      # Simulate an MCP server that offers "read_file" and "web_search"
      mcp_read_file = %KiroCockpit.PuppyBrain.ToolRegistry.Tool{
        name: "read_file",
        description: "MCP file reader",
        source: {:mcp, "file-server"},
        permission: :external
      }

      mcp_web_search = %KiroCockpit.PuppyBrain.ToolRegistry.Tool{
        name: "web_search",
        description: "Search the web",
        source: {:mcp, "web"},
        permission: :external
      }

      external_tools = [mcp_read_file, mcp_web_search]
      {filtered_external, conflicts} = Filter.drop_name_conflicts(external_tools, probe.name_set)
      final_toolset = local_tools ++ filtered_external

      # The local read_file wins; the MCP one is filtered
      final_names = Enum.map(final_toolset, & &1.name)
      assert "read_file" in final_names
      assert "web_search" in final_names

      # The local read_file has :local source
      read_file_tool = Enum.find(final_toolset, &(&1.name == "read_file"))
      assert read_file_tool.source == :local

      # The conflict is recorded
      conflict_names = Enum.map(conflicts, & &1.name)
      assert "read_file" in conflict_names
    end

    test "using compose/2 matches manual pipeline" do
      local_tools = ToolRegistry.local_tools(:kiro_executor)

      mcp_tools = [
        %KiroCockpit.PuppyBrain.ToolRegistry.Tool{
          name: "shell",
          description: "MCP shell",
          source: {:mcp, "shell-server"},
          permission: :external
        },
        %KiroCockpit.PuppyBrain.ToolRegistry.Tool{
          name: "deploy_app",
          description: "Deploy to production",
          source: {:mcp, "deploy"},
          permission: :external
        }
      ]

      # Manual pipeline
      probe = ToolComposer.register_probe(local_tools)
      {manual_filtered, _} = Filter.drop_name_conflicts(mcp_tools, probe.name_set)
      manual_final = local_tools ++ manual_filtered

      # Compose pipeline
      {compose_final, _snapshot} = ToolComposer.compose(local_tools, mcp_tools)

      assert Enum.map(compose_final, & &1.name) == Enum.map(manual_final, & &1.name)

      # MCP "shell" is filtered (local wins); "deploy_app" is kept
      assert Enum.any?(compose_final, &(&1.name == "shell" and &1.source == :local))
      assert Enum.any?(compose_final, &(&1.name == "deploy_app" and match?({:mcp, _}, &1.source)))
    end
  end

  describe "all profiles compose cleanly with mock external tools" do
    test "every agent profile produces a valid toolset when given conflicting external tools" do
      # A universal "shadow" MCP tool that collides with every profile's first tool
      for profile <- ToolRegistry.agent_profiles() do
        local_tools = ToolRegistry.local_tools(profile)
        first_local_name = hd(local_tools).name

        shadow_mcp = %KiroCockpit.PuppyBrain.ToolRegistry.Tool{
          name: first_local_name,
          description: "MCP shadow of #{first_local_name}",
          source: {:mcp, "shadow"},
          permission: :external
        }

        unique_mcp = %KiroCockpit.PuppyBrain.ToolRegistry.Tool{
          name: "unique_external_#{profile}",
          description: "Unique external tool",
          source: {:mcp, "unique"},
          permission: :external
        }

        {final_toolset, snapshot} = ToolComposer.compose(local_tools, [shadow_mcp, unique_mcp])

        # The shadow tool is filtered, not in final set
        refute Enum.any?(
                 final_toolset,
                 &(&1.name == first_local_name and match?({:mcp, _}, &1.source))
               )

        # The unique tool is kept
        assert Enum.any?(final_toolset, &(&1.name == "unique_external_#{profile}"))

        # Conflicts are recorded
        assert length(snapshot.filtered_conflicts) == 1
        assert hd(snapshot.filtered_conflicts).name == first_local_name
      end
    end
  end
end
