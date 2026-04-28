defmodule KiroCockpit.PuppyBrain.ToolComposerTest do
  use ExUnit.Case, async: true

  alias KiroCockpit.PuppyBrain.ToolRegistry.Tool
  alias KiroCockpit.PuppyBrain.ToolComposer
  alias KiroCockpit.PuppyBrain.ToolComposer.Probe
  alias KiroCockpit.PuppyBrain.ToolComposer.Snapshot

  # ── Helpers ─────────────────────────────────────────────────────────

  defp local_tool(name, perm \\ :read) do
    %Tool{name: name, description: "Local #{name}", source: :local, permission: perm}
  end

  defp mcp_tool(name, server \\ "default") do
    %Tool{name: name, description: "MCP #{name}", source: {:mcp, server}, permission: :external}
  end

  # ── register_probe / tool_names ─────────────────────────────────────

  describe "register_probe/1" do
    test "creates a probe with local tools and name set" do
      tools = [local_tool("read_file"), local_tool("grep")]
      probe = ToolComposer.register_probe(tools)

      assert %Probe{} = probe
      assert probe.tools == tools
      assert probe.names == ["read_file", "grep"]
      assert MapSet.member?(probe.name_set, "read_file")
      assert MapSet.member?(probe.name_set, "grep")
    end

    test "handles empty tool list" do
      probe = ToolComposer.register_probe([])

      assert probe.names == []
      assert MapSet.size(probe.name_set) == 0
    end
  end

  describe "tool_names/1" do
    test "extracts names from probe" do
      probe = ToolComposer.register_probe([local_tool("a"), local_tool("b")])
      assert ToolComposer.tool_names(probe) == ["a", "b"]
    end
  end

  # ── compose/2 ───────────────────────────────────────────────────────

  describe "compose/2" do
    test "local tool wins on MCP name conflict (§36.5)" do
      local = [local_tool("read_file")]
      external = [mcp_tool("read_file")]

      {final_toolset, _snapshot} = ToolComposer.compose(local, external)

      # Only the local tool remains — the MCP duplicate is dropped
      assert length(final_toolset) == 1
      assert hd(final_toolset).source == :local
      assert hd(final_toolset).name == "read_file"
    end

    test "conflicting external tool is filtered (§36.5)" do
      local = [local_tool("read_file"), local_tool("grep")]
      external = [mcp_tool("read_file"), mcp_tool("web_search")]

      {_final, snapshot} = ToolComposer.compose(local, external)

      conflict_names = Enum.map(snapshot.filtered_conflicts, & &1.name)
      assert "read_file" in conflict_names
      assert "web_search" not in conflict_names
    end

    test "non-conflicting external tool is retained (§36.5)" do
      local = [local_tool("read_file")]
      external = [mcp_tool("web_search"), mcp_tool("database_query")]

      {final_toolset, _snapshot} = ToolComposer.compose(local, external)

      final_names = Enum.map(final_toolset, & &1.name)
      assert "web_search" in final_names
      assert "database_query" in final_names
    end

    test "filtered conflicts are visible in debug snapshot (§36.5)" do
      local = [local_tool("read_file"), local_tool("shell")]
      external = [mcp_tool("read_file"), mcp_tool("shell"), mcp_tool("web_search")]

      {_final, snapshot} = ToolComposer.compose(local, external)

      assert %Snapshot{} = snapshot
      assert length(snapshot.filtered_conflicts) == 2
      assert length(snapshot.local_tools) == 2
      # Only the non-conflicting one is in external_tools
      assert length(snapshot.external_tools) == 1

      conflict_names = Enum.map(snapshot.filtered_conflicts, & &1.name) |> Enum.sort()
      assert conflict_names == ["read_file", "shell"]
    end

    test "snapshot includes a stable hash" do
      local = [local_tool("a")]
      external = [mcp_tool("b")]

      {_final, snapshot} = ToolComposer.compose(local, external)

      assert is_binary(snapshot.toolset_hash)
      assert byte_size(snapshot.toolset_hash) == 64
    end

    test "snapshot includes composed_at timestamp" do
      {_, snapshot} = ToolComposer.compose([local_tool("x")], [])

      assert %DateTime{} = snapshot.composed_at
    end

    test "compose with no external tools returns just local tools" do
      local = [local_tool("a"), local_tool("b")]
      {final, snapshot} = ToolComposer.compose(local, [])

      assert final == local
      assert snapshot.filtered_conflicts == []
      assert snapshot.external_tools == []
    end

    test "compose with no local tools passes through all external tools" do
      external = [mcp_tool("a"), mcp_tool("b")]
      {final, snapshot} = ToolComposer.compose([], external)

      assert final == external
      assert snapshot.filtered_conflicts == []
      assert snapshot.local_tools == []
    end

    test "hash is stable for same toolset regardless of order" do
      local_a = [local_tool("a"), local_tool("b")]
      local_b = [local_tool("b"), local_tool("a")]
      ext = [mcp_tool("c")]

      {_, snap_a} = ToolComposer.compose(local_a, ext)
      {_, snap_b} = ToolComposer.compose(local_b, ext)

      # Same tool names → same hash (names are sorted before hashing)
      assert snap_a.toolset_hash == snap_b.toolset_hash
    end

    test "hash differs when toolset differs" do
      {_, snap_a} = ToolComposer.compose([local_tool("a")], [mcp_tool("c")])
      {_, snap_b} = ToolComposer.compose([local_tool("a")], [mcp_tool("d")])

      refute snap_a.toolset_hash == snap_b.toolset_hash
    end
  end

  describe "build_snapshot/3" do
    test "creates snapshot with all fields" do
      local = [local_tool("a")]
      ext = [mcp_tool("b")]
      conflicts = [mcp_tool("c")]

      snap = ToolComposer.build_snapshot(local, ext, conflicts)

      assert snap.local_tools == local
      assert snap.external_tools == ext
      assert snap.filtered_conflicts == conflicts
      assert is_binary(snap.toolset_hash)
      assert %DateTime{} = snap.composed_at
    end
  end
end
