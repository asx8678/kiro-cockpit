defmodule KiroCockpit.Test.KiroEgnMockBoundary do
  @moduledoc """
  Mock ActionBoundary for kiro-egn KiroSession tests.

  Allows prompt actions (so the agent can run and send callback requests)
  but returns `{:error, {:swarm_boundary_disabled, action}}` for all
  callback actions. This exercises the defensive handling in
  `KiroSession.run_callback_with_boundary/5` — verifying the GenServer
  does not crash on an unhandled clause when the boundary returns disabled.
  """

  alias KiroCockpit.Swarm.ActionBoundary

  @exempt_actions ActionBoundary.exempt_actions()

  @doc """
  Mock `run/3` that allows prompts but returns disabled for callback actions.

  - `:kiro_session_prompt` → executes the fun (simulates boundary allowing)
  - exempt actions → executes the fun (lifecycle actions bypass boundary)
  - all other actions → `{:error, {:swarm_boundary_disabled, action}}`
  """
  def run(:kiro_session_prompt, _opts, fun) do
    {:ok, fun.()}
  end

  def run(action, _opts, fun) when action in @exempt_actions do
    {:ok, fun.()}
  end

  def run(action, _opts, _fun) do
    {:error, {:swarm_boundary_disabled, action}}
  end
end
