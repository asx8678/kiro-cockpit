defmodule KiroCockpit.PuppyBrain.ToolComposer do
  @moduledoc "Two-pass, conflict-safe tool composition for local and external tools." 

  def compose(local_tools, external_tools) do
    local_names = MapSet.new(Enum.map(local_tools, &tool_name/1))
    {conflicts, retained} = Enum.split_with(external_tools, &(tool_name(&1) in local_names))

    %{
      tools: local_tools ++ retained,
      local_tools: local_tools,
      external_tools: retained,
      filtered_conflicts: conflicts,
      debug_snapshot: %{
        local_names: Enum.map(local_tools, &tool_name/1),
        retained_external_names: Enum.map(retained, &tool_name/1),
        filtered_conflict_names: Enum.map(conflicts, &tool_name/1)
      }
    }
  end

  def with_runtime_tools(toolset, temporary_tools, fun) when is_function(fun, 1) do
    original = toolset
    runtime = %{toolset | tools: toolset.tools ++ temporary_tools}

    try do
      fun.(runtime)
    after
      Process.put({__MODULE__, :last_restored_toolset}, original)
    end
  end

  def last_restored_toolset, do: Process.get({__MODULE__, :last_restored_toolset})

  defp tool_name(%{name: name}), do: to_string(name)
  defp tool_name(%{"name" => name}), do: to_string(name)
end
