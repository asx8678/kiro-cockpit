defmodule KiroCockpit.PuppyBrain.Callbacks do
  @moduledoc """
  Registry and dispatcher for the callback nervous system (§26.13).

  This module provides a lifecycle event bus where callback modules
  implementing `KiroCockpit.PuppyBrain.Callback` register for specific
  phases and are invoked when those phases fire.

  ## Design rules (§26.13)

    * Callbacks may add context, tools, events, or advice.
    * Callbacks **may not** override hard Swarm enforcement unless
      explicitly registered as higher-priority policy hooks.
    * Callbacks are advisory — they cannot block execution.

  ## Registry

  Callbacks are stored in an ETS table (`:puppy_brain_callbacks`)
  owned by this GenServer for fast phase → module lookups. Register
  with `register/1`, unregister with `unregister/1`.

  ## Dispatch

  Call `dispatch/3` to invoke all callbacks registered for a phase.
  The accumulator map is threaded through each callback in registration
  order. A failing callback is logged and skipped; it never prevents
  other callbacks from running.

  ## Canonical phases

  See `KiroCockpit.PuppyBrain.Callback` for the full list of
  lifecycle phases from §26.13.

  ## Telemetry

  Every dispatch emits:
    * `[:kiro_cockpit, :callback, :dispatch, :start|:stop|:exception]`

  Per-callback invocations emit:
    * `[:kiro_cockpit, :callback, :invoke, :start|:stop|:exception]`
  """

  use GenServer

  require Logger

  alias KiroCockpit.PuppyBrain.Callback
  alias KiroCockpit.Telemetry

  @table :puppy_brain_callbacks

  # -- Canonical phases (§26.13) --------------------------------------------

  @canonical_phases [
    :on_startup,
    :on_shutdown,
    :on_load_prompt,
    :on_load_rules,
    :on_prepare_model_prompt,
    :on_register_agents,
    :on_register_tools,
    :on_register_skills,
    :on_pre_action,
    :on_post_action,
    :on_stream_event,
    :on_plan_created,
    :on_plan_approved,
    :on_task_changed,
    :on_finding_promoted,
    :on_history_compaction_start,
    :on_history_compaction_end
  ]

  @doc "Returns the list of all canonical callback phases (§26.13)."
  @spec canonical_phases() :: [Callback.phase()]
  def canonical_phases, do: @canonical_phases

  @doc "Returns `true` if the given atom is a canonical callback phase."
  @spec canonical_phase?(atom()) :: boolean()
  def canonical_phase?(phase) when is_atom(phase) do
    phase in @canonical_phases
  end

  # -- Client API -----------------------------------------------------------

  @doc """
  Start the callback registry GenServer.

  Creates the ETS table for phase → module lookups. Should be added
  as a child of the application supervisor.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Register a callback module with the registry.

  The module must implement `KiroCockpit.PuppyBrain.Callback`. It
  will be invoked for all phases it subscribes to (as returned by
  `c:Callback.phases/0`).

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  @spec register(module()) :: :ok | {:error, term()}
  def register(module) when is_atom(module) do
    GenServer.call(__MODULE__, {:register, module})
  end

  @doc """
  Unregister a callback module from the registry.

  Removes the module from all its subscribed phases.
  """
  @spec unregister(module()) :: :ok
  def unregister(module) when is_atom(module) do
    GenServer.call(__MODULE__, {:unregister, module})
  end

  @doc """
  Dispatch a lifecycle phase, invoking all registered callbacks.

  Calls each callback's `c:Callback.on_callback/3` with `(phase, ctx, acc)`,
  threading the accumulator through in registration order. A failing
  callback is logged and skipped; it never prevents other callbacks from
  running.

  Returns `{:ok, acc}` with the final accumulated result. Partial progress
  is preserved even when some callbacks fail — the accumulator from the
  last successful callback continues.

  This function reads the ETS table directly for fast dispatch without
  going through the GenServer. If the table doesn't exist yet, it returns
  `{:ok, initial_acc}`.
  """
  @spec dispatch(Callback.phase(), Callback.context(), Callback.accumulator()) ::
          {:ok, Callback.accumulator()}
  def dispatch(phase, ctx \\ %{}, initial_acc \\ %{}) when is_atom(phase) do
    if :ets.whereis(@table) == :undefined do
      {:ok, initial_acc}
    else
      dispatch_with_table(phase, ctx, initial_acc)
    end
  end

  defp dispatch_with_table(phase, ctx, initial_acc) do
    modules = modules_for_phase(phase)
    dispatch_meta = dispatch_telemetry_meta(phase, length(modules))

    Telemetry.span(:callback, :dispatch, dispatch_meta, fn ->
      {final_acc, _errors} =
        Enum.reduce(modules, {initial_acc, []}, fn module, {acc, errors} ->
          invoke_callback(module, phase, ctx, acc, errors)
        end)

      {{:ok, final_acc}, %{}}
    end)
  end

  @doc """
  List all modules registered for a specific phase.

  Returns modules in registration order.
  """
  @spec modules_for_phase(Callback.phase()) :: [module()]
  def modules_for_phase(phase) when is_atom(phase) do
    if :ets.whereis(@table) == :undefined do
      []
    else
      case :ets.lookup(@table, {:phase, phase}) do
        [{_, modules}] -> modules
        [] -> []
      end
    end
  end

  @doc """
  List all registered callback modules (unique, in registration order).
  """
  @spec registered_modules() :: [module()]
  def registered_modules do
    if :ets.whereis(@table) == :undefined do
      []
    else
      case :ets.lookup(@table, :modules) do
        [{_, modules}] -> modules
        [] -> []
      end
    end
  end

  @doc """
  Check if a module is currently registered.
  """
  @spec registered?(module()) :: boolean()
  def registered?(module) when is_atom(module) do
    module in registered_modules()
  end

  @doc """
  Reset the registry by clearing all registrations.

  Primarily for test isolation. Returns `:ok`.
  """
  @spec reset() :: :ok
  def reset do
    if :ets.whereis(@table) != :undefined do
      GenServer.call(__MODULE__, :reset)
    else
      :ok
    end
  end

  # -- GenServer callbacks ---------------------------------------------------

  @impl true
  def init(opts) do
    table_opts = [
      :set,
      :named_table,
      :public,
      read_concurrency: true,
      write_concurrency: true
    ]

    :ets.new(@table, table_opts)
    :ets.insert(@table, {:modules, []})

    # Pre-seed phase keys for all canonical phases
    for phase <- @canonical_phases do
      :ets.insert(@table, {{:phase, phase}, []})
    end

    {:ok, %{name: Keyword.get(opts, :name, __MODULE__)}}
  end

  @impl true
  def handle_call({:register, module}, _from, state) do
    with {:ok, phases} <- validate_callback_module(module),
         :ok <- ensure_not_registered(module) do
      # Add to master module list
      modules = registered_modules_internal()
      :ets.insert(@table, {:modules, modules ++ [module]})

      # Add to each subscribed phase
      for phase <- phases do
        existing = phase_modules_internal(phase)
        :ets.insert(@table, {{:phase, phase}, existing ++ [module]})
      end

      {:reply, :ok, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:unregister, module}, _from, state) do
    modules = registered_modules_internal()
    :ets.insert(@table, {:modules, List.delete(modules, module)})

    # Remove from all canonical phase indices
    for phase <- @canonical_phases do
      phase_mods = phase_modules_internal(phase)
      :ets.insert(@table, {{:phase, phase}, List.delete(phase_mods, module)})
    end

    {:reply, :ok, state}
  end

  def handle_call(:reset, _from, state) do
    :ets.delete_all_objects(@table)
    :ets.insert(@table, {:modules, []})

    for phase <- @canonical_phases do
      :ets.insert(@table, {{:phase, phase}, []})
    end

    {:reply, :ok, state}
  end

  # -- Private: dispatch internals ------------------------------------------

  defp invoke_callback(module, phase, ctx, acc, errors) do
    invoke_meta = %{
      callback_name: module.name(),
      phase: phase
    }

    case safe_invoke(module, phase, ctx, acc, invoke_meta) do
      {:ok, new_acc} ->
        {new_acc, errors}

      {:error, reason} ->
        Logger.warning(
          "Callback #{inspect(module)} failed for phase #{phase}: #{inspect(reason)}"
        )

        {acc, [{module, reason} | errors]}
    end
  end

  defp safe_invoke(module, phase, ctx, acc, meta) do
    Telemetry.span(:callback, :invoke, meta, fn ->
      result = module.on_callback(phase, ctx, acc)
      {result, %{}}
    end)
  rescue
    exception ->
      # The :telemetry.span/3 inside Telemetry.span already emitted
      # a [:kiro_cockpit, :callback, :invoke, :exception] event with
      # :kind, :reason, and :stacktrace. Error details are also logged
      # via Logger.warning in invoke_callback/5. No duplicate needed.
      {:error, {:exception, exception}}
  end

  # -- Private: registry internals -------------------------------------------

  defp registered_modules_internal do
    case :ets.lookup(@table, :modules) do
      [{_, modules}] -> modules
      [] -> []
    end
  end

  defp phase_modules_internal(phase) do
    case :ets.lookup(@table, {:phase, phase}) do
      [{_, modules}] -> modules
      [] -> []
    end
  end

  defp validate_callback_module(module) do
    behaviours =
      try do
        module.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()
      rescue
        _ -> []
      end

    if Callback in behaviours do
      {:ok, module.phases()}
    else
      {:error, {:invalid_callback_module, module}}
    end
  end

  defp ensure_not_registered(module) do
    if module in registered_modules_internal() do
      {:error, {:already_registered, module}}
    else
      :ok
    end
  end

  defp dispatch_telemetry_meta(phase, callback_count) do
    %{phase: phase, callback_count: callback_count}
  end
end
