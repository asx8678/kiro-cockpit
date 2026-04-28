defmodule KiroCockpit.PuppyBrain.ToolRegistry.DefaultProvider do
  @moduledoc """
  Default external tool provider — returns an empty list.

  In production, MCP tool discovery is session-scoped and requires an active
  MCP server connection. This default returns no external tools so the
  composition pipeline works even without MCP configured.

  Replace via `config :kiro_cockpit, :external_tool_provider, MyProvider`
  or pass `external_provider:` opt to `ToolRegistry.external_tools/2`.
  """

  @behaviour KiroCockpit.PuppyBrain.ToolRegistry

  @impl true
  def available_external_tools(_session_id), do: []
end
