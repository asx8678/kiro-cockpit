defmodule KiroCockpit.MCP.Filter do
  @moduledoc """
  Name-conflict filter for MCP/external tools per §26.7.

  The sole responsibility: given a list of external tools and a set of
  local tool names, drop any external tool whose name collides with a
  local name. Local tools **always** win (§26.7 rule 1).

  This module is **pure and deterministic** — no side effects, no DB,
  no process state. Perfect for property-based testing.

  ## Return shape

  `drop_name_conflicts/2` returns `{kept, conflicts}` where:
  - `kept`     — external tools with non-colliding names
  - `conflicts` — external tools whose names matched a local tool

  The caller (ToolComposer) uses `conflicts` for debug UI display
  (§26.7 rule 3) and snapshot persistence (§26.7 rule 4).
  """

  alias KiroCockpit.PuppyBrain.ToolRegistry.Tool

  @type name_set :: MapSet.t(String.t())

  # ── Public API ─────────────────────────────────────────────────────

  @doc """
  Filter external tools that collide with local tool names.

  Returns `{kept, conflicts}` where:
  - `kept` is the list of external tools whose names do **not** appear
    in `local_name_set`
  - `conflicts` is the list of external tools whose names **do** appear
    in `local_name_set` and are therefore dropped

  Both lists preserve the original order from `external_tools`.

  ## Examples

      iex> local = MapSet.new(["read_file", "grep"])
      iex> ext = [%Tool{name: "read_file", ...}, %Tool{name: "search_web", ...}]
      iex> {kept, conflicts} = MCP.Filter.drop_name_conflicts(ext, local)
      iex> Enum.map(kept, & &1.name)
      ["search_web"]
      iex> Enum.map(conflicts, & &1.name)
      ["read_file"]
  """
  @spec drop_name_conflicts([Tool.t()], name_set()) :: {[Tool.t()], [Tool.t()]}
  def drop_name_conflicts(external_tools, local_name_set)
      when is_list(external_tools) and is_struct(local_name_set, MapSet) do
    external_tools
    |> Enum.reduce({[], []}, fn tool, {kept, conflicts} ->
      if MapSet.member?(local_name_set, tool.name) do
        {kept, [tool | conflicts]}
      else
        {[tool | kept], conflicts}
      end
    end)
    |> then(fn {kept, conflicts} ->
      {Enum.reverse(kept), Enum.reverse(conflicts)}
    end)
  end

  @doc """
  Convenience: build a name set from a list of tools.
  """
  @spec name_set_from_tools([Tool.t()]) :: name_set()
  def name_set_from_tools(tools) when is_list(tools) do
    tools
    |> Enum.map(& &1.name)
    |> MapSet.new()
  end

  @doc """
  Convenience: check if a single tool name conflicts with the local set.
  """
  @spec conflicts?(Tool.t(), name_set()) :: boolean()
  def conflicts?(%Tool{name: name}, local_name_set) do
    MapSet.member?(local_name_set, name)
  end
end
