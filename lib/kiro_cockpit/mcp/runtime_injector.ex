defmodule KiroCockpit.MCP.RuntimeInjector do
  @moduledoc """
  Temporary runtime tool injection with guaranteed restore per §26.8.

  Durable run state must not permanently mutate the global agent/tool
  registry. External MCP tools are attached per-run and restored afterward
  — whether the run succeeds, fails, or is cancelled.

  ## Design

  The injector wraps a function call in a snapshot→inject→run→restore
  pattern:

    1. `snapshot/1` — capture current toolset for the agent
    2. `inject/3` — add temporary external tools for this run
    3. Execute the caller's function
    4. `restore/2` — restore the original toolset (guaranteed via `try/finally`)

  ## Concurrency model

  The injector operates on a **per-agent process dictionary** key
  (`{__MODULE__, agent_id}`). This is process-local, not global, so
  concurrent agents don't interfere. The process dictionary is chosen
  deliberately because:

  - Agent execution is single-process (one Kiro session = one process)
  - No ETS/Genserver overhead for what is effectively a stack variable
  - `try/finally` restore is process-local and cannot be missed

  If the project later needs cross-process coordination, this should be
  replaced with a per-agent Agent or ETS table — but not today.
  """

  alias KiroCockpit.PuppyBrain.ToolRegistry.Tool

  @type agent_id :: String.t()
  @type toolset :: [Tool.t()]
  @type snapshot_ref :: {agent_id(), toolset()}

  @pdict_key {__MODULE__, :toolset}

  # ── Public API ─────────────────────────────────────────────────────

  @doc """
  Execute `fun` with temporary external tools injected for `agent_id`.

  The current toolset is snapshotted, `extra_tools` are appended, `fun`
  runs, and the original toolset is restored — even if `fun` raises.

  Returns `{:ok, result}` on success, `{:error, reason}` on caught error.

  The restore is **guaranteed** via `try/finally`. If the process crashes
  (exit/kill), the process dictionary is destroyed with the process, so
  there's no stale state to clean up.
  """
  @spec with_runtime_tools(agent_id(), [Tool.t()], (-> result)) ::
          {:ok, result} | {:error, term()}
        when result: term()
  def with_runtime_tools(agent_id, extra_tools, fun)
      when is_binary(agent_id) and is_function(fun, 0) and is_list(extra_tools) do
    snap = snapshot(agent_id)

    try do
      inject(agent_id, extra_tools)
      result = fun.()
      {:ok, result}
    rescue
      e ->
        {:error, {:exception, e}}
    catch
      kind, reason ->
        {:error, {:caught, kind, reason}}
    after
      restore(snap)
    end
  end

  @doc """
  Capture the current toolset for `agent_id` as a snapshot reference.

  Returns `{agent_id, current_toolset}`. If no toolset has been set,
  returns an empty list as the current state.
  """
  @spec snapshot(agent_id()) :: snapshot_ref()
  def snapshot(agent_id) when is_binary(agent_id) do
    current = Process.get({@pdict_key, agent_id}) || []
    {agent_id, current}
  end

  @doc """
  Inject (append) `extra_tools` to the current toolset for `agent_id`.

  This is additive — existing tools are preserved, new tools are appended.
  Duplicate names are NOT checked at this level — the ToolComposer handles
  name conflict filtering before injection.
  """
  @spec inject(agent_id(), [Tool.t()]) :: toolset()
  def inject(agent_id, extra_tools)
      when is_binary(agent_id) and is_list(extra_tools) do
    current = Process.get({@pdict_key, agent_id}) || []
    updated = current ++ extra_tools
    Process.put({@pdict_key, agent_id}, updated)
    updated
  end

  @doc """
  Restore a previously captured snapshot.

  Resets the toolset for the snapshot's agent_id to the exact state
  captured by `snapshot/1`. This is the "finally" step that guarantees
  no permanent mutation (§26.8).
  """
  @spec restore(snapshot_ref()) :: :ok
  def restore({agent_id, saved_toolset}) when is_binary(agent_id) do
    Process.put({@pdict_key, agent_id}, saved_toolset)
    :ok
  end

  @doc """
  Read the current toolset for `agent_id` without modifying it.
  """
  @spec current_toolset(agent_id()) :: toolset()
  def current_toolset(agent_id) when is_binary(agent_id) do
    Process.get({@pdict_key, agent_id}) || []
  end

  @doc """
  Clear the toolset for `agent_id` (e.g., on process teardown).
  """
  @spec clear(agent_id()) :: :ok
  def clear(agent_id) when is_binary(agent_id) do
    Process.delete({@pdict_key, agent_id})
    :ok
  end
end
