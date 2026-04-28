defmodule KiroCockpit.MCP.RuntimeInjectorTest do
  use ExUnit.Case, async: true

  alias KiroCockpit.PuppyBrain.ToolRegistry.Tool
  alias KiroCockpit.MCP.RuntimeInjector

  # ── Helpers ─────────────────────────────────────────────────────────

  defp mcp_tool(name) do
    %Tool{name: name, description: "MCP #{name}", source: {:mcp, "server"}, permission: :external}
  end

  defp local_tool(name) do
    %Tool{name: name, description: "Local #{name}", source: :local, permission: :read}
  end

  setup do
    agent_id = "test-agent-#{:erlang.unique_integer([:positive])}"
    on_exit(fn -> RuntimeInjector.clear(agent_id) end)
    {:ok, agent_id: agent_id}
  end

  # ── with_runtime_tools/3 ────────────────────────────────────────────

  describe "with_runtime_tools/3" do
    test "injects tools and returns result", %{agent_id: agent_id} do
      # Start with one local tool
      RuntimeInjector.inject(agent_id, [local_tool("read_file")])

      extra = [mcp_tool("web_search")]

      assert {:ok, :done} =
               RuntimeInjector.with_runtime_tools(agent_id, extra, fn ->
                 # Inside the run, we should see both tools
                 current = RuntimeInjector.current_toolset(agent_id)
                 assert length(current) == 2
                 :done
               end)

      # After the run, original toolset is restored
      current = RuntimeInjector.current_toolset(agent_id)
      assert length(current) == 1
      assert hd(current).name == "read_file"
    end

    test "restores original toolset after error (§36.5)", %{agent_id: agent_id} do
      RuntimeInjector.inject(agent_id, [local_tool("read_file")])

      extra = [mcp_tool("web_search")]

      result =
        RuntimeInjector.with_runtime_tools(agent_id, extra, fn ->
          # Should see injected tools
          assert length(RuntimeInjector.current_toolset(agent_id)) == 2
          raise "boom"
        end)

      assert {:error, {:exception, %RuntimeError{message: "boom"}}} = result

      # After error, original toolset is restored
      current = RuntimeInjector.current_toolset(agent_id)
      assert length(current) == 1
      assert hd(current).name == "read_file"
    end

    test "restores original toolset after throw", %{agent_id: agent_id} do
      RuntimeInjector.inject(agent_id, [local_tool("grep")])

      extra = [mcp_tool("db_query")]

      result =
        RuntimeInjector.with_runtime_tools(agent_id, extra, fn ->
          throw(:test_throw)
        end)

      assert {:error, {:caught, :throw, :test_throw}} = result

      # After throw, original toolset is restored
      current = RuntimeInjector.current_toolset(agent_id)
      assert length(current) == 1
      assert hd(current).name == "grep"
    end

    test "works with empty initial toolset", %{agent_id: agent_id} do
      # No tools initially
      assert RuntimeInjector.current_toolset(agent_id) == []

      extra = [mcp_tool("a"), mcp_tool("b")]

      assert {:ok, :result} =
               RuntimeInjector.with_runtime_tools(agent_id, extra, fn ->
                 assert length(RuntimeInjector.current_toolset(agent_id)) == 2
                 :result
               end)

      # Restored to empty
      assert RuntimeInjector.current_toolset(agent_id) == []
    end
  end

  # ── snapshot/1 ──────────────────────────────────────────────────────

  describe "snapshot/1" do
    test "captures current toolset state", %{agent_id: agent_id} do
      tools = [local_tool("a"), local_tool("b")]
      RuntimeInjector.inject(agent_id, tools)

      {id, saved} = RuntimeInjector.snapshot(agent_id)

      assert id == agent_id
      assert saved == tools
    end

    test "returns empty list for unset agent", %{agent_id: agent_id} do
      {id, saved} = RuntimeInjector.snapshot(agent_id)

      assert id == agent_id
      assert saved == []
    end
  end

  # ── inject/2 ────────────────────────────────────────────────────────

  describe "inject/2" do
    test "appends tools to existing toolset", %{agent_id: agent_id} do
      RuntimeInjector.inject(agent_id, [local_tool("a")])
      RuntimeInjector.inject(agent_id, [mcp_tool("b")])

      current = RuntimeInjector.current_toolset(agent_id)
      assert length(current) == 2
      assert Enum.map(current, & &1.name) == ["a", "b"]
    end

    test "inject returns updated toolset", %{agent_id: agent_id} do
      result = RuntimeInjector.inject(agent_id, [local_tool("x")])

      assert length(result) == 1
      assert hd(result).name == "x"
    end
  end

  # ── restore/1 ────────────────────────────────────────────────────────

  describe "restore/1" do
    test "restores to exact snapshot state", %{agent_id: agent_id} do
      RuntimeInjector.inject(agent_id, [local_tool("a"), local_tool("b")])
      snap = RuntimeInjector.snapshot(agent_id)

      # Mutate the toolset
      RuntimeInjector.inject(agent_id, [mcp_tool("c"), mcp_tool("d")])
      assert length(RuntimeInjector.current_toolset(agent_id)) == 4

      # Restore
      RuntimeInjector.restore(snap)

      current = RuntimeInjector.current_toolset(agent_id)
      assert length(current) == 2
      assert Enum.map(current, & &1.name) == ["a", "b"]
    end

    test "restore to empty snapshot clears toolset", %{agent_id: agent_id} do
      RuntimeInjector.inject(agent_id, [local_tool("a")])
      snap = {agent_id, []}

      RuntimeInjector.restore(snap)

      assert RuntimeInjector.current_toolset(agent_id) == []
    end
  end

  # ── current_toolset/1 ───────────────────────────────────────────────

  describe "current_toolset/1" do
    test "returns empty list for unknown agent", %{agent_id: agent_id} do
      assert RuntimeInjector.current_toolset(agent_id) == []
    end
  end

  # ── clear/1 ─────────────────────────────────────────────────────────

  describe "clear/1" do
    test "removes toolset from process dictionary", %{agent_id: agent_id} do
      RuntimeInjector.inject(agent_id, [local_tool("a")])
      assert length(RuntimeInjector.current_toolset(agent_id)) == 1

      RuntimeInjector.clear(agent_id)
      assert RuntimeInjector.current_toolset(agent_id) == []
    end
  end
end
