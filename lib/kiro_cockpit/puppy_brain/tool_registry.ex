defmodule KiroCockpit.PuppyBrain.ToolRegistry do
  @moduledoc "Local wrapper tool catalog." 

  alias KiroCockpit.PuppyBrain.AgentRegistry

  @tool_defs %{
    read: %{name: "read", permission: :read, local?: true},
    grep: %{name: "grep", permission: :read, local?: true},
    list_files: %{name: "list_files", permission: :read, local?: true},
    write: %{name: "write", permission: :write, local?: true},
    shell: %{name: "shell", permission: :shell, local?: true}
  }

  def local_tools(agent_id) when is_atom(agent_id) do
    agent_id |> AgentRegistry.fetch!() |> Map.fetch!(:default_tools) |> Enum.map(&Map.fetch!(@tool_defs, &1))
  end
end
