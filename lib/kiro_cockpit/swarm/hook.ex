defmodule KiroCockpit.Swarm.Hook do
  @moduledoc """
  Behaviour for Swarm hook modules.

  Hooks are priority-ordered interceptors (§27.1) that subscribe to events
  and return one of three decisions via `HookResult`: continue, modify, or block.

  The hook manager calls `c:filter/1` to determine whether a hook applies to
  a given event, then `c:on_event/2` for execution. `c:priority/0` determines
  execution order: higher-priority hooks run first in pre-action phases and
  last in post-action phases (§27.3).

  ## Implementing a hook

      defmodule MyApp.SecurityAuditHook do
        @behaviour KiroCockpit.Swarm.Hook

        alias KiroCockpit.Swarm.{Event, HookResult}

        @impl true
        def name, do: :security_audit

        @impl true
        def priority, do: 100

        @impl true
        def filter(%Event{action_name: :file_write}), do: true
        def filter(_event), do: false

        @impl true
        def on_event(event, _ctx) do
          if contains_secret?(event.payload) do
            HookResult.block(event, "Secret detected in payload")
          else
            HookResult.continue(event)
          end
        end
      end
  """

  alias KiroCockpit.Swarm.{Event, HookResult}

  @doc "Returns the unique atom name of this hook."
  @callback name() :: atom()

  @doc "Returns the priority integer. Higher = runs first in pre, last in post."
  @callback priority() :: integer()

  @doc "Returns `true` if this hook should run for the given event."
  @callback filter(Event.t()) :: boolean()

  @doc """
  Execute the hook logic against the event, returning a `HookResult`.

  `ctx` is an opaque map provided by the hook manager (may contain session
  state, configuration, or other runtime context).
  """
  @callback on_event(Event.t(), map()) :: HookResult.t()
end
