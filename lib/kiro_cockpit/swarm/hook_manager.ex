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

  alias KiroCockpit.Swarm.{Event, HookResult, HookTrace, TraceContext}
  alias KiroCockpit.Telemetry

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
    meta =
      %{
        session_id: event.session_id,
        plan_id: event.plan_id,
        task_id: event.task_id,
        agent_id: event.agent_id,
        action_name: event.action_name,
        phase: phase
      }
      |> maybe_add_trace_ids(event.trace_context)
      |> Telemetry.filter_metadata()

    Telemetry.span(:hook, :chain, meta, fn ->
      applicable_hooks = hooks |> filter_applicable(event) |> sort_for_phase(phase)
      started_at = System.monotonic_time()

      result = run_applicable_hooks(applicable_hooks, event, ctx, meta)
      persist_result(result, ctx, phase, duration_ms(started_at))
    end)
  end

  defp run_applicable_hooks(hooks, event, ctx, meta) do
    Enum.reduce_while(hooks, {:ok, event, [], []}, fn hook,
                                                      {:ok, event_acc, messages, hook_results_acc} ->
      hook_meta = Map.merge(meta, %{hook_name: hook.name(), priority: hook.priority()})

      case run_hook_with_telemetry(hook, event_acc, ctx, hook_meta) do
        {:ok, %HookResult{decision: decision, event: evt, messages: msgs} = hook_result}
        when decision in [:continue, :modify] ->
          new_hook_results = [
            HookTrace.normalize_hook_result(hook.name(), hook_result) | hook_results_acc
          ]

          {:cont, {:ok, evt, messages ++ msgs, new_hook_results}}

        {:ok,
         %HookResult{decision: :block, event: evt, reason: reason, messages: msgs} = hook_result} ->
          new_hook_results = [
            HookTrace.normalize_hook_result(hook.name(), hook_result) | hook_results_acc
          ]

          {:halt, {:blocked, evt, reason, messages ++ msgs, new_hook_results}}

        {:exception, reason} ->
          new_hook_results = [
            %{"hook" => to_string(hook.name()), "decision" => "exception", "reason" => reason}
            | hook_results_acc
          ]

          {:halt, {:blocked, event_acc, reason, messages, new_hook_results}}
      end
    end)
  end

  defp run_hook_with_telemetry(hook, event, ctx, hook_meta) do
    result =
      Telemetry.span(:hook, :run, hook_meta, fn ->
        hook_result = hook.on_event(event, ctx)
        {hook_result, %{decision: hook_result.decision}}
      end)

    {:ok, result}
  rescue
    exception ->
      {:exception, "Hook #{hook.name()} raised exception: #{Exception.message(exception)}"}
  end

  defp persist_result({:ok, final_event, messages, hook_results}, ctx, phase, duration_ms) do
    trace_summary =
      HookTrace.chain_summary(
        final_event,
        Enum.reverse(hook_results),
        :ok,
        nil,
        duration_ms,
        phase
      )

    HookTrace.maybe_persist_trace(final_event, trace_summary, Map.put(ctx, :phase, phase))
    {{:ok, final_event, messages}, %{}}
  end

  defp persist_result(
         {:blocked, final_event, reason, messages, hook_results},
         ctx,
         phase,
         duration_ms
       ) do
    trace_summary =
      HookTrace.chain_summary(
        final_event,
        Enum.reverse(hook_results),
        :blocked,
        reason,
        duration_ms,
        phase
      )

    HookTrace.maybe_persist_trace(final_event, trace_summary, Map.put(ctx, :phase, phase))
    {{:blocked, final_event, reason, messages}, %{}}
  end

  defp duration_ms(started_at) do
    System.monotonic_time()
    |> Kernel.-(started_at)
    |> System.convert_time_unit(:native, :millisecond)
  end

  defp maybe_add_trace_ids(meta, nil), do: meta

  defp maybe_add_trace_ids(meta, %TraceContext{trace_id: trace_id, span_id: span_id}) do
    meta
    |> Map.put(:trace_id, trace_id)
    |> Map.put(:span_id, span_id)
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
