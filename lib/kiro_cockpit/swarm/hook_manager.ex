defmodule KiroCockpit.Swarm.HookManager do
  @moduledoc """
  Deterministic hook chain executor for the Swarm runtime.

  Given an explicit list of hook modules and an event, the manager:

    1. Filters to applicable hooks via `c:KiroCockpit.Swarm.Hook.filter/1`
    2. Sorts by priority and phase (§27.3):
       - Pre-action: descending priority (highest first)
       - Post-action: ascending priority (lowest first)
    3. Ties are broken deterministically by hook name (alphabetical)
    4. Executes hooks in order, threading the event through
    5. Stops on `:block`, threads the modified event on `:modify`
    6. Returns `{:ok, event, messages}` or `{:blocked, event, reason, messages}`

  §27.11 Invariant 4: hook execution order is deterministic.
  """

  alias KiroCockpit.Swarm.{Event, HookResult}

  @type phase :: :pre | :post

  @type run_result ::
          {:ok, Event.t(), [String.t()]}
          | {:blocked, Event.t(), String.t(), [String.t()]}

  @doc """
  Run the hook chain against the given event.

  `hooks` is a list of modules implementing `KiroCockpit.Swarm.Hook`.
  `ctx` is an opaque map passed to each hook's `c:on_event/2`.
  `phase` is `:pre` or `:post`, controlling sort direction.

  ## Return values

    - `{:ok, event, messages}` — all hooks passed; event may be modified.
    - `{:blocked, event, reason, messages}` — a hook blocked the chain.
  """
  @spec run(Event.t(), [module()], map(), phase()) :: run_result()
  def run(event, hooks, ctx, phase) when is_atom(phase) do
    hooks
    |> filter_applicable(event)
    |> sort_for_phase(phase)
    |> Enum.reduce_while({:ok, event, []}, fn hook, {:ok, event_acc, messages} ->
      case hook.on_event(event_acc, ctx) do
        %HookResult{decision: :continue, event: evt, messages: msgs} ->
          {:cont, {:ok, evt, messages ++ msgs}}

        %HookResult{decision: :modify, event: evt, messages: msgs} ->
          {:cont, {:ok, evt, messages ++ msgs}}

        %HookResult{decision: :block, event: evt, reason: reason, messages: msgs} ->
          {:halt, {:blocked, evt, reason, messages ++ msgs}}
      end
    end)
  end

  @doc """
  Return only hooks whose `c:filter/1` returns `true` for the given event.
  """
  @spec filter_applicable([module()], Event.t()) :: [module()]
  def filter_applicable(hooks, event) do
    Enum.filter(hooks, fn hook -> hook.filter(event) end)
  end

  @doc """
  Sort hooks for the given phase.

  Pre-action: descending priority, then ascending name (highest-priority
  hooks run first).

  Post-action: ascending priority, then ascending name (lowest-priority
  hooks run first).

  §27.3 pre-action hooks run in descending priority; post-action in ascending.
  §27.11 Invariant 4: hook execution order is deterministic — tie-breaker is
  the hook's `name/0` in alphabetical order.
  """
  @spec sort_for_phase([module()], phase()) :: [module()]
  def sort_for_phase(hooks, :pre) do
    Enum.sort_by(hooks, fn hook -> {-hook.priority(), hook.name()} end)
  end

  def sort_for_phase(hooks, :post) do
    Enum.sort_by(hooks, fn hook -> {hook.priority(), hook.name()} end)
  end
end
