defmodule KiroCockpit.MCP.FilterTest do
  use ExUnit.Case, async: true

  alias KiroCockpit.PuppyBrain.ToolRegistry.Tool
  alias KiroCockpit.MCP.Filter

  # ── Helpers ─────────────────────────────────────────────────────────

  defp mcp_tool(name, server \\ "default") do
    %Tool{name: name, description: "MCP #{name}", source: {:mcp, server}, permission: :external}
  end

  # ── drop_name_conflicts/2 ───────────────────────────────────────────

  describe "drop_name_conflicts/2" do
    test "returns all external tools when no name conflicts" do
      local_set = MapSet.new(["read_file", "grep"])
      ext = [mcp_tool("web_search"), mcp_tool("database_query")]

      {kept, conflicts} = Filter.drop_name_conflicts(ext, local_set)

      assert kept == ext
      assert conflicts == []
    end

    test "drops external tool that collides with local name" do
      local_set = MapSet.new(["read_file"])
      ext = [mcp_tool("read_file")]

      {kept, conflicts} = Filter.drop_name_conflicts(ext, local_set)

      assert kept == []
      assert conflicts == ext
    end

    test "mixed: some conflict, some don't" do
      local_set = MapSet.new(["read_file", "shell"])
      ext = [mcp_tool("read_file"), mcp_tool("web_search"), mcp_tool("shell"), mcp_tool("db")]

      {kept, conflicts} = Filter.drop_name_conflicts(ext, local_set)

      kept_names = Enum.map(kept, & &1.name)
      conflict_names = Enum.map(conflicts, & &1.name)

      assert "web_search" in kept_names
      assert "db" in kept_names
      assert "read_file" in conflict_names
      assert "shell" in conflict_names
    end

    test "preserves order of both kept and conflicts" do
      local_set = MapSet.new(["b"])
      ext = [mcp_tool("a"), mcp_tool("b"), mcp_tool("c")]

      {kept, conflicts} = Filter.drop_name_conflicts(ext, local_set)

      assert Enum.map(kept, & &1.name) == ["a", "c"]
      assert Enum.map(conflicts, & &1.name) == ["b"]
    end

    test "empty external tools returns empty both lists" do
      local_set = MapSet.new(["read_file"])

      {kept, conflicts} = Filter.drop_name_conflicts([], local_set)

      assert kept == []
      assert conflicts == []
    end

    test "empty local name set keeps all external tools" do
      local_set = MapSet.new([])
      ext = [mcp_tool("a"), mcp_tool("b")]

      {kept, conflicts} = Filter.drop_name_conflicts(ext, local_set)

      assert kept == ext
      assert conflicts == []
    end
  end

  # ── name_set_from_tools/1 ───────────────────────────────────────────

  describe "name_set_from_tools/1" do
    test "builds a MapSet from tool names" do
      tools = [mcp_tool("a"), mcp_tool("b"), mcp_tool("a")]

      set = Filter.name_set_from_tools(tools)

      assert MapSet.size(set) == 2
      assert MapSet.member?(set, "a")
      assert MapSet.member?(set, "b")
    end
  end

  # ── conflicts?/2 ────────────────────────────────────────────────────

  describe "conflicts?/2" do
    test "returns true when tool name is in local set" do
      local_set = MapSet.new(["read_file"])

      assert Filter.conflicts?(mcp_tool("read_file"), local_set) == true
    end

    test "returns false when tool name is not in local set" do
      local_set = MapSet.new(["read_file"])

      assert Filter.conflicts?(mcp_tool("web_search"), local_set) == false
    end
  end

  # ── Property-style invariants (deterministic, no StreamData dep yet) ─

  describe "invariant: partition is complete and disjoint" do
    test "kept ∪ conflicts == original external tools" do
      # For any combination of local names and external tools,
      # every external tool ends up in exactly one of kept or conflicts.
      local_set = MapSet.new(["a", "c", "e"])
      ext = for n <- ["a", "b", "c", "d", "e", "f"], do: mcp_tool(n)

      {kept, conflicts} = Filter.drop_name_conflicts(ext, local_set)

      # Union covers all originals
      all_result = kept ++ conflicts
      assert length(all_result) == length(ext)

      # No tool appears in both lists
      kept_names = MapSet.new(kept, & &1.name)
      conflict_names = MapSet.new(conflicts, & &1.name)
      assert MapSet.disjoint?(kept_names, conflict_names)

      # Kept are exactly those NOT in local_set
      assert MapSet.equal?(kept_names, MapSet.difference(MapSet.new(ext, & &1.name), local_set))
      # Conflicts are exactly those IN local_set
      assert MapSet.equal?(
               conflict_names,
               MapSet.intersection(MapSet.new(ext, & &1.name), local_set)
             )
    end

    test "invariant holds for empty inputs" do
      {kept, conflicts} = Filter.drop_name_conflicts([], MapSet.new())
      assert kept == [] and conflicts == []

      {kept, conflicts} = Filter.drop_name_conflicts([], MapSet.new(["a"]))
      assert kept == [] and conflicts == []

      {kept, conflicts} = Filter.drop_name_conflicts([mcp_tool("x")], MapSet.new())
      assert kept == [mcp_tool("x")] and conflicts == []
    end
  end
end
