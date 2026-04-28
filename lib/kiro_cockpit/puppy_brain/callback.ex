defmodule KiroCockpit.PuppyBrain.Callback do
  @moduledoc """
  Behaviour for lifecycle callback modules (§26.13).

  Callback modules subscribe to one or more lifecycle phases and are
  invoked by `KiroCockpit.PuppyBrain.Callbacks.dispatch/3` when that
  phase fires. Unlike Swarm hooks (§27.1), callbacks are **advisory
  only** — they may add context, tools, events, or advice to the
  accumulator but they **cannot block execution**. If blocking is
  required, register a `KiroCockpit.Swarm.Hook` instead.

  ## Canonical phases (§26.13)

    * `:on_startup` / `:on_shutdown`
    * `:on_load_prompt` / `:on_load_rules`
    * `:on_prepare_model_prompt`
    * `:on_register_agents` / `:on_register_tools` / `:on_register_skills`
    * `:on_pre_action` / `:on_post_action`
    * `:on_stream_event`
    * `:on_plan_created` / `:on_plan_approved`
    * `:on_task_changed` / `:on_finding_promoted`
    * `:on_history_compaction_start` / `:on_history_compaction_end`

  ## Implementing a callback

      defmodule MyApp.StartupCallback do
        @behaviour KiroCockpit.PuppyBrain.Callback

        @impl true
        def name, do: :startup_callback

        @impl true
        def phases, do: [:on_startup]

        @impl true
        def on_callback(:on_startup, _ctx, acc) do
          {:ok, Map.put(acc, :environment, detect_env())}
        end
      end

  ## Accumulator discipline

  Each callback receives the current accumulator map and returns
  `{:ok, acc}` with its additions merged in. The dispatcher threads the
  accumulator through all callbacks for the phase in registration order.

  A callback that returns `{:error, reason}` is logged and skipped; it
  does **not** prevent other callbacks from running.
  """

  @type phase :: atom()
  @type context :: map()
  @type accumulator :: map()

  @doc "Returns the unique atom name of this callback module."
  @callback name() :: atom()

  @doc "Returns the list of phases this callback subscribes to."
  @callback phases() :: [phase()]

  @doc """
  Invoke the callback for the given phase.

  `ctx` is an opaque map provided by the dispatcher (session state,
  configuration, event payload, etc.). `acc` is the threaded accumulator
  — previous callbacks' additions are already present.

  Return `{:ok, acc}` with your additions merged, or `{:error, reason}`
  to signal failure. Errors are logged and skipped; they never block
  other callbacks.
  """
  @callback on_callback(phase(), context(), accumulator()) ::
              {:ok, accumulator()} | {:error, term()}
end
