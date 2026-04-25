defmodule KiroCockpit.Telemetry do
  @moduledoc """
  Canonical telemetry + structured-logging conventions for `kiro_cockpit`.

  Phase 1 seed: this module establishes the conventions that future ACP,
  session, and event-store work must use. It does **not** implement those
  features — it only provides the helpers and the closed-set vocabulary
  they will plug into.

  ## Event taxonomy

  Every event name has the canonical four-element shape:

      [:kiro_cockpit, <context>, <action>, :start | :stop | :exception]

  Contexts and actions are a **closed set**. Adding a new one is a code
  change here, on purpose — drift such as `:tool_dispatch` vs
  `:tool_run_dispatch` is exactly what this guards against. Use
  `event/3` to build the name and `span/4` whenever the work has a
  natural start/stop boundary so durations and exception capture come
  for free from `:telemetry.span/3`.

  ## Correlation metadata (Plan 3 hard rule R8 — `plan2.md` §25.3)

  > Every action is associated with `session_id`, `plan_id`, `task_id`,
  > `agent_id`, and permission level when possible.

  The closed set of correlation keys recognised by both telemetry meta
  and Logger metadata is:

  `request_id`, `session_id`, `turn_id`, `plan_id`, `task_id`,
  `agent_id`, `permission_level`, `trace_id`, `span_id`.

  `filter_metadata/1` is the single funnel that drops any other keys
  before they reach a telemetry handler or the Logger. Treat it the
  same way you'd treat a redactor: redact / filter at the **source**,
  never at the sink.

  ## Examples

      iex> event = KiroCockpit.Telemetry.event(:session, :create, :stop)
      [:kiro_cockpit, :session, :create, :stop]

      KiroCockpit.Telemetry.span(:event_store, :append, %{session_id: id}, fn ->
        result = do_append!()
        {result, %{rows: 1}}
      end)

      KiroCockpit.Telemetry.with_metadata([session_id: id, plan_id: pid], fn ->
        Logger.info("session resumed")
      end)
  """

  require Logger

  @app :kiro_cockpit

  # Closed set of contexts. Adding a context is a deliberate code change
  # — see moduledoc.
  @contexts [:acp, :session, :event_store]

  # Closed set of actions per context. Phase 1 seed only — these are the
  # actions ACP/session/EventStore work is expected to emit.
  @actions %{
    acp: [:initialize, :prompt, :turn, :update, :callback],
    session: [:create, :resume, :archive],
    event_store: [:append, :read]
  }

  @phases [:start, :stop, :exception]

  # Closed set of correlation keys — Plan 3 R8 plus standard request /
  # turn / trace correlation.
  @metadata_keys [
    :request_id,
    :session_id,
    :turn_id,
    :plan_id,
    :task_id,
    :agent_id,
    :permission_level,
    :trace_id,
    :span_id
  ]

  @typedoc "One of the canonical contexts."
  @type context :: :acp | :session | :event_store

  @typedoc "One of the canonical phases."
  @type phase :: :start | :stop | :exception

  @typedoc "Canonical event name list."
  @type event_name :: [atom(), ...]

  @doc """
  Returns the closed list of canonical contexts.
  """
  @spec contexts() :: [context()]
  def contexts, do: @contexts

  @doc """
  Returns the closed list of canonical actions for `context`.

  Raises `ArgumentError` for an unknown context.
  """
  @spec actions(context()) :: [atom()]
  def actions(context) when is_atom(context) do
    case Map.fetch(@actions, context) do
      {:ok, actions} -> actions
      :error -> raise ArgumentError, "unknown telemetry context: #{inspect(context)}"
    end
  end

  @doc """
  Returns the closed list of correlation metadata keys.
  """
  @spec metadata_keys() :: [atom()]
  def metadata_keys, do: @metadata_keys

  @doc """
  Builds a canonical four-element event name.

  Validates `context`, `action`, and `phase` against the closed sets.
  Raises `ArgumentError` for any near-duplicate or unknown value.

      iex> KiroCockpit.Telemetry.event(:session, :create, :stop)
      [:kiro_cockpit, :session, :create, :stop]
  """
  @spec event(context(), atom(), phase()) :: event_name()
  def event(context, action, phase)
      when is_atom(context) and is_atom(action) and is_atom(phase) do
    valid_actions = actions(context)

    unless action in valid_actions do
      raise ArgumentError,
            "unknown telemetry action #{inspect(action)} for context " <>
              "#{inspect(context)}; allowed: #{inspect(valid_actions)}"
    end

    unless phase in @phases do
      raise ArgumentError,
            "unknown telemetry phase #{inspect(phase)}; allowed: #{inspect(@phases)}"
    end

    [@app, context, action, phase]
  end

  @doc """
  Wraps `:telemetry.execute/3`, filtering metadata to the canonical
  correlation keys before emission.

  Use this for one-shot events that do not have a natural span boundary
  (for example a permission denial, or an event-store append that has
  already completed). For start/stop work, prefer `span/4`.
  """
  @spec execute(event_name(), map(), map()) :: :ok
  def execute(event, measurements, meta)
      when is_list(event) and is_map(measurements) and is_map(meta) do
    :telemetry.execute(event, measurements, filter_metadata(meta))
  end

  @doc """
  Wraps `:telemetry.span/3`, building the canonical event prefix from
  `context`/`action` and filtering start metadata.

  `:telemetry.span/3` automatically emits `:start`, `:stop`, and
  `:exception` child events with correct durations — always prefer this
  over hand-rolled start/stop pairs.

  Unlike raw `:telemetry.span/3`, this wrapper **propagates the start
  metadata into the `:stop` and `:exception` events** so dashboards and
  trace exporters see the same correlation IDs across the lifecycle.
  The library does not do this for you, and forgetting it is how
  `session_id` ends up missing on half your stop events.

  `fun` may return either:

    * `{result, extra_metadata}` — the 2-tuple form. Extras are merged
      into the `:stop` metadata (after filtering through the canonical
      whitelist).
    * `{result, extra_measurements, extra_metadata}` — the 3-tuple form.
      Prefer this when emitting numeric attributes such as `:duration`,
      `:tokens_in`, or `:rows` so they land in measurements (where
      Prometheus / Telemetry.Metrics expects them) rather than meta.

  ## Example

      KiroCockpit.Telemetry.span(:event_store, :append, %{session_id: id}, fn ->
        rows = do_append!()
        {:ok, %{rows: rows}, %{}}
      end)
  """
  @spec span(context(), atom(), map(), (-> {term(), map()} | {term(), map(), map()})) ::
          term()
  def span(context, action, meta, fun)
      when is_atom(context) and is_atom(action) and is_map(meta) and is_function(fun, 0) do
    valid_actions = actions(context)

    unless action in valid_actions do
      raise ArgumentError,
            "unknown telemetry action #{inspect(action)} for context " <>
              "#{inspect(context)}; allowed: #{inspect(valid_actions)}"
    end

    start_meta = filter_metadata(meta)
    wrapped = wrap_span_fun(fun, start_meta)

    :telemetry.span([@app, context, action], start_meta, wrapped)
  end

  # Re-shape the user's span function so :stop and :exception inherit
  # the start metadata (filtered through the canonical whitelist), and
  # any extras the user returns are filtered too. Both 2-tuple and
  # 3-tuple return shapes are honoured.
  defp wrap_span_fun(fun, start_meta) do
    fn ->
      case fun.() do
        {result, extra_meta} when is_map(extra_meta) ->
          {result, Map.merge(start_meta, filter_metadata(extra_meta))}

        {result, extra_measurements, extra_meta}
        when is_map(extra_measurements) and is_map(extra_meta) ->
          {result, extra_measurements, Map.merge(start_meta, filter_metadata(extra_meta))}

        other ->
          raise ArgumentError,
                "span function must return {result, meta} or " <>
                  "{result, measurements, meta}; got: #{inspect(other)}"
      end
    end
  end

  @doc """
  Filters arbitrary metadata down to the canonical correlation keys.

  Accepts either a map or a keyword list and preserves the input shape.
  Anything outside `metadata_keys/0` is dropped — the goal is to keep
  free-form payloads (user input, raw structs, secrets) out of telemetry
  meta and Logger metadata. The full redactor (plan2.md §22.6 / §25.6)
  will plug in here when it lands.
  """
  @spec filter_metadata(map()) :: map()
  @spec filter_metadata(keyword()) :: keyword()
  def filter_metadata(meta) when is_map(meta) do
    Map.take(meta, @metadata_keys)
  end

  def filter_metadata(meta) when is_list(meta) do
    Keyword.take(meta, @metadata_keys)
  end

  @doc """
  Sets Logger metadata to `meta`, dropping any keys outside the canonical
  correlation set.

  Unlike `Logger.metadata/1`, this never lets a stray `:user_input` or
  `:secret` field smuggle itself into log output. Use it at the entry
  points (Plug, ACP message handler, LiveView mount) once those features
  land.
  """
  @spec put_metadata(keyword() | map()) :: :ok
  def put_metadata(meta) when is_list(meta) or is_map(meta) do
    meta
    |> to_keyword()
    |> filter_metadata()
    |> Logger.metadata()
  end

  @doc """
  Runs `fun` with Logger metadata extended by `meta` (filtered through
  the correlation whitelist), restoring the previous Logger metadata
  afterwards.

  Useful for wrapping a unit of work — an ACP turn, a session resume,
  an event-store batch — so log lines emitted inside it carry the right
  correlation IDs without leaking them to surrounding code.
  """
  @spec with_metadata(keyword() | map(), (-> result)) :: result when result: var
  def with_metadata(meta, fun) when (is_list(meta) or is_map(meta)) and is_function(fun, 0) do
    previous = Logger.metadata()
    additions = meta |> to_keyword() |> filter_metadata()

    try do
      Logger.metadata(additions)
      fun.()
    after
      Logger.reset_metadata(previous)
    end
  end

  # Coerce maps to keyword lists for Logger; Logger.metadata/1 wants
  # keyword lists, but call sites are friendlier when both shapes work.
  defp to_keyword(meta) when is_list(meta), do: meta

  defp to_keyword(meta) when is_map(meta) do
    Enum.map(meta, fn {k, v} when is_atom(k) -> {k, v} end)
  end
end
