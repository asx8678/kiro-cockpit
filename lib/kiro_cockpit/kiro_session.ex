defmodule KiroCockpit.KiroSession do
  @moduledoc """
  ACP session lifecycle manager over `KiroCockpit.Acp.PortProcess`.

  Orchestrates the full ACP protocol lifecycle per `kiro-acp-instructions.md`:

      initialize → session/new | session/load → session/prompt

  KiroSession owns the underlying `PortProcess` and forwards inbound agent
  traffic (notifications, requests, protocol errors, exits) to a subscriber
  pid in stable tuple shapes:

      {:acp_notification, session_pid, %{method: method, params: params}}
      {:acp_request,     session_pid, %{id: id, method: method, params: params}}
      {:acp_protocol_error, session_pid, reason, raw}
      {:acp_exit,       session_pid, status}

  Streaming normalization, back-pressure, and cancellation (kiro-1rd) live
  here. Client callback handling for `fs/*` / `terminal/*` (kiro-4ff) is
  integrated via the `:auto_callbacks` option (default `true`). When enabled,
  known callback methods are automatically dispatched to
  `KiroCockpit.KiroSession.Callbacks` and the JSON-RPC response is sent without
  requiring the subscriber to call `respond/3`. The raw request is still
  forwarded to the subscriber for observability/backward compatibility.
  Unknown methods continue to require the subscriber to respond manually.

  ## Stream events (kiro-1rd)

  Every inbound `session/update` notification is normalized through
  `KiroCockpit.KiroSession.StreamEvent.normalize/3` and pushed to the
  subscriber as:

      {:kiro_stream_event, session_pid, %KiroCockpit.KiroSession.StreamEvent{}}

  The legacy `{:acp_notification, session_pid, msg}` is **also** sent for
  backward compatibility. New code should subscribe to `:kiro_stream_event`;
  raw `:acp_notification` will be deprecated when no callers remain.

  Sequence numbers are monotonic per-session and assigned at receipt time,
  so an ordered stream of events maps deterministically onto its source
  ordering of `session/update` notifications.

  A bounded recent-events buffer (`stream_buffer_limit`, default 256) is
  kept in memory for inspection. Overflow drops the oldest event and
  bumps `stream_dropped_count`; subscribers receive a one-shot marker
  `{:kiro_stream_overflow, session_pid, total_dropped}` per drop.

  ## Turn discipline (kiro-1rd)

  A turn is **running** from the moment `prompt/3` is called until a
  normalized `:turn_end` stream event arrives. The `session/prompt` RPC
  result alone does **not** complete the turn — this is plan2.md §17 +
  §30.4 gold-memory rule "Do not mark Kiro turns complete from
  `session/prompt` response alone. Wait for `session/update` `turn_end`."

  Inspect via `state/1`:

    * `:turn_id` — increments per `prompt/3` call
    * `:turn_status` — `:idle | :running | :cancel_requested | :complete`
    * `:last_stop_reason` — recorded when prompt RPC result returns
      (does NOT mark complete)

  Cancellation (`cancel/2`) is **async per ACP spec**: it locally records
  intent (`:cancel_requested`), fires a `session/cancel` notification, and
  returns `:ok` immediately. The agent decides when to wrap up; the turn
  isn't `:complete` until the matching `:turn_end` event lands.

  ## Lifecycle phases

    * `:uninitialized` — transport subprocess is running but `initialize/2`
      has not been called.
    * `:initialized` — `initialize/2` succeeded; agent capabilities are known.
    * `:session_active` — a session (created or loaded) is active; `prompt/3`
      may be called.

  Out-of-order calls return `{:error, {:invalid_phase, actual_phase}}`.

  ## `session/prompt` is non-blocking internally

  The `prompt/3` call blocks the **caller** until the agent sends the final
  `session/prompt` result, but the KiroSession GenServer itself stays
  responsive: it continues forwarding inbound notifications and requests to
  the subscriber while the prompt is in flight. This avoids deadlocks when
  the agent sends `fs/*` or `terminal/*` callbacks during a turn.
  """

  use GenServer

  require Logger

  alias KiroCockpit.Acp.{JsonRpc, PortProcess}
  alias KiroCockpit.EventStore
  alias KiroCockpit.KiroSession.Callbacks
  alias KiroCockpit.KiroSession.StreamEvent
  alias KiroCockpit.KiroSession.TerminalManager
  alias KiroCockpit.Plans
  alias KiroCockpit.Swarm.ActionBoundary
  alias KiroCockpit.Swarm.DataPipeline
  alias KiroCockpit.Swarm.PlanMode
  alias KiroCockpit.Telemetry

  # ACP protocol defaults per kiro-acp-instructions.md
  @default_protocol_version 1
  @default_client_name "kiro-cockpit"
  @default_client_title "Kiro Cockpit"
  @default_client_version "0.1.0"
  @default_callback_policy :read_only
  @default_executable_args ["acp"]
  @default_request_timeout 30_000
  @default_prompt_timeout 300_000

  # Default cap on the runtime-local recent-events ring. Tuned for
  # introspection, not durability — storage owns truth, the runtime caches.
  @default_stream_buffer_limit 256

  # kiro-8v5: Safe prompt opt keys — the whitelist of public opts that may
  # pass through to `prompt_boundary_opts/2`.  Everything else is stripped
  # because the merge `Keyword.merge(base, opts)` would let arbitrary caller
  # opts override server-derived trust/authorization fields.
  #
  # Identifiers (plan_id, task_id, agent_id, swarm_plan_id) are allowed
  # because they feed derivation/hydration, not direct authorization.
  # Actual authorization is derived from durable DB state by ActionBoundary.
  @safe_prompt_opt_keys [
    :timeout,
    :plan_id,
    :task_id,
    :agent_id,
    :swarm_plan_id
  ]

  # -- Types ----------------------------------------------------------------

  @typedoc """
  Current lifecycle phase.

  The `:transport_closed` phase is entered after the port subprocess exits
  (clean or abnormal). All lifecycle calls (`initialize/2`, `new_session/3`,
  `load_session/4`, `prompt/3`) return `{:error, :transport_closed}` in this
  phase. The session remains alive so `state/1` still works and the subscriber
  can inspect the final state, but no further ACP operations are possible.
  """
  @type phase :: :uninitialized | :initialized | :session_active | :transport_closed

  @typedoc """
  Turn lifecycle status.

    * `:idle` — no turn has been started, or the previous turn completed.
    * `:running` — `prompt/3` was called; awaiting normalized `turn_end`.
    * `:cancel_requested` — `cancel/2` was called during a running turn;
      the `session/cancel` notification has been sent. The turn stays in
      this state until the agent wraps up and emits `turn_end`.
    * `:complete` — a normalized `turn_end` event has arrived.
  """
  @type turn_status :: :idle | :running | :cancel_requested | :complete

  @typedoc """
  Summary of session state returned by `state/1`.

  Decoupled from the internal struct so callers don't depend on
  implementation details.
  """
  @type state_summary :: %{
          phase: phase(),
          session_id: String.t() | nil,
          cwd: Path.t() | nil,
          agent_capabilities: map() | nil,
          agent_info: map() | nil,
          auth_methods: [map()] | nil,
          modes: map() | nil,
          config_options: [map()] | nil,
          protocol_version: pos_integer() | nil,
          auto_callbacks: boolean(),
          turn_id: non_neg_integer(),
          turn_status: turn_status(),
          last_stop_reason: String.t() | nil,
          stream_sequence: non_neg_integer(),
          stream_buffer_size: non_neg_integer(),
          stream_buffer_limit: pos_integer(),
          stream_dropped_count: non_neg_integer(),
          swarm_hooks: boolean(),
          swarm_agent_id: String.t(),
          swarm_plan_id: String.t() | nil,
          swarm_ctx: map(),
          swarm_test_bypass: boolean()
        }

  # Internal state — 37 fields: unavoidable GenServer state; splitting
  # would scatter cohesive session state across sub-structs.
  # credo:disable-for-next-line Credo.Check.Warning.StructFieldAmount
  defstruct port_process: nil,
            port_ref: nil,
            subscriber: nil,
            subscriber_ref: nil,
            pending_prompt: nil,
            prompt_task_ref: nil,
            phase: :uninitialized,
            session_id: nil,
            cwd: nil,
            agent_capabilities: nil,
            agent_info: nil,
            auth_methods: nil,
            modes: nil,
            config_options: nil,
            protocol_version: nil,
            executable: nil,
            args: nil,
            client_info: nil,
            client_capabilities: nil,
            persist_messages: true,
            # Auto callback handling (kiro-4ff) --------------------------
            auto_callbacks: true,
            callback_policy: @default_callback_policy,
            terminal_manager: nil,
            # Swarm action hook boundary (kiro-00j) ----------------------
            swarm_hooks: false,
            swarm_agent_id: "kiro-session",
            swarm_plan_id: nil,
            swarm_ctx: %{},
            plan_mode: nil,
            swarm_hooks_module: ActionBoundary,
            # kiro-egn: test bypass flag for non-bypassable action boundary.
            # Only effective in Mix.env() == :test. In production, always false.
            swarm_test_bypass: false,
            # Stream normalization (kiro-1rd) -----------------------------
            stream_buffer: nil,
            stream_buffer_size: 0,
            stream_buffer_limit: @default_stream_buffer_limit,
            stream_dropped_count: 0,
            stream_sequence: 0,
            # Turn discipline (kiro-1rd) ----------------------------------
            turn_id: 0,
            turn_status: :idle,
            last_stop_reason: nil

  @type t :: %__MODULE__{}

  # -- Public API -----------------------------------------------------------

  @doc """
  Start a KiroSession linked to the calling process.

  Spawns an ACP agent subprocess and prepares for the `initialize` handshake.
  The `:subscriber` pid receives all forwarded inbound ACP messages.

  ## Options

    * `:executable` (required) — absolute path to the ACP agent executable.
    * `:args` — argv for the executable (default `["acp"]`).
    * `:subscriber` — pid that receives forwarded inbound ACP messages.
      Defaults to the calling process.
    * `:cd` — working directory for the child process.
    * `:env` — environment variables for the child process.
    * `:max_line_bytes` — max line length for the port (default 4 MiB).
    * `:stream_buffer_limit` — cap on the runtime-local recent-events ring
      buffer (default `#{@default_stream_buffer_limit}`). Once the buffer
      is full, the oldest event is evicted and `stream_dropped_count`
      increments. The subscriber receives a one-shot
      `{:kiro_stream_overflow, session_pid, total_dropped}` per drop.
    * `:persist_messages` — whether to persist raw inbound/outbound ACP
      messages to `EventStore` (default `true`).
    * `:auto_callbacks` — whether to automatically handle known
      client callback methods (`fs/*`, `terminal/*`) per
      kiro-acp-instructions.md §9 (default `true`). When `true`,
      inbound requests for known methods are both forwarded to the
      subscriber (for observability) AND auto-replied. When `false`,
      the subscriber is responsible for calling `respond/3`.
    * `:callback_policy` — which callback methods are allowed when
      `auto_callbacks` is `true` (default `:read_only`). Options:
        * `:read_only` — only `fs/read_text_file` is auto-handled.
          Mutating methods (`fs/write_text_file`, `terminal/*`) are
          auto-denied with a JSON-RPC error while still forwarded to
          the subscriber for observability.
        * `:all` / `:trusted` — all known methods are allowed and
          auto-handled (previous default behavior). Use for
          trusted/approved execution contexts.
    * `:swarm_ctx` — map of durable trusted context flags for the swarm
      hook boundary (e.g. `%{approved: true, policy_allows_write: true}`).
      Merged into every prompt/callback boundary call so that session-
      level trust decisions don't need to be repeated per-prompt opts.
    * `:name` — GenServer registration name.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    opts = Keyword.put_new(opts, :subscriber, self())
    {gen_opts, server_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, server_opts, gen_opts)
  end

  @doc """
  Perform the ACP `initialize` handshake (kiro-acp-instructions.md §4).

  Sends `protocolVersion`, `clientCapabilities`, and `clientInfo` to the
  agent. On success, transitions from `:uninitialized` to `:initialized`
  and stores agent capabilities, info, and auth methods.

  Returns `{:error, {:protocol_version_mismatch, ...}}` if the agent
  reports a different protocol version than requested.

  ## Options

    * `:protocol_version` — ACP protocol version (default `1`).
    * `:client_capabilities` — capabilities map to advertise.
    * `:client_info` — `%{"name" => ..., "title" => ..., "version" => ...}`.
    * `:timeout` — request timeout in ms (default 30 000).
  """
  @spec initialize(GenServer.server(), keyword()) :: {:ok, map()} | {:error, term()}
  def initialize(session, opts \\ []) do
    GenServer.call(session, {:initialize, opts}, call_timeout(opts))
  end

  @doc """
  Create a new ACP session via `session/new` (kiro-acp-instructions.md §5).

  Transitions from `:initialized` to `:session_active` on success.
  Stores `session_id`, `modes`, and `config_options` from the result.

  ## Parameters

    * `cwd` — absolute working directory for the session.

  ## Options

    * `:mcp_servers` — list of MCP server configurations (default `[]`).
    * `:timeout` — request timeout in ms (default 30 000).
  """
  @spec new_session(GenServer.server(), Path.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def new_session(session, cwd, opts \\ []) do
    GenServer.call(session, {:new_session, cwd, opts}, call_timeout(opts))
  end

  @doc """
  Load an existing ACP session via `session/load` (kiro-acp-instructions.md §5).

  Transitions from `:initialized` to `:session_active`. The agent streams
  prior conversation via `session/update` notifications (forwarded to the
  subscriber). Per ACP spec, the RPC result is `null`.

  ## Parameters

    * `session_id` — the ACP session ID string (e.g. `"sess_abc123"`).
    * `cwd` — absolute working directory for the session.

  ## Options

    * `:mcp_servers` — list of MCP server configurations (default `[]`).
    * `:timeout` — request timeout in ms (default 30 000).
  """
  @spec load_session(GenServer.server(), String.t(), Path.t(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def load_session(session, session_id, cwd, opts \\ []) do
    GenServer.call(session, {:load_session, session_id, cwd, opts}, call_timeout(opts))
  end

  @doc """
  Send a prompt to the active session via `session/prompt`
  (kiro-acp-instructions.md §8).

  Accepts either a plain text binary (automatically normalized to a single
  text content block) or a list of content block maps per ACP spec.

  **This call blocks** the caller until the agent sends the final
  `session/prompt` result (with `stopReason`). During the wait, KiroSession
  continues forwarding inbound notifications and requests to the subscriber.

  ## Active-turn rejection (kiro-1rd)

  A new prompt is rejected while the previous turn is still in flight:

    * `{:error, :prompt_in_progress}` — the previous `session/prompt` RPC
      has not returned yet (the request is on the wire).
    * `{:error, :turn_in_progress}` — the prompt RPC has returned but the
      normalized `:turn_end` stream event has not arrived yet, so
      `turn_status` is still `:running` or `:cancel_requested`. Per
      plan2.md §17 / §30.4 the turn is not complete on the prompt RPC
      result alone — wait for `turn_end`.

  Both errors are stable atoms; callers may pattern-match either.

  ## Parameters

    * `prompt_or_blocks` — a binary string or list of `%{"type" => ..., ...}` maps.

  ## Options

    * `:timeout` — request timeout in ms (default 300 000, i.e. 5 minutes).
      Use `:infinity` for turns that may run indefinitely.
  """
  @spec prompt(GenServer.server(), binary() | [map()], keyword()) ::
          {:ok, map()} | {:error, term()}
  def prompt(session, prompt_or_blocks, opts \\ []) do
    GenServer.call(session, {:prompt, prompt_or_blocks, opts}, prompt_call_timeout(opts))
  end

  @doc """
  Returns a summary of the current session state.

  The returned map is a stable public shape — callers should not depend
  on the internal struct.
  """
  @spec state(GenServer.server()) :: state_summary()
  def state(session) do
    GenServer.call(session, :state, 5_000)
  end

  @doc """
  Reply to an inbound agent→client request with a success result.

  The `request_id` MUST be the id from the original
  `{:acp_request, session_pid, %{id: id, ...}}` message.

  This is a thin pass-through to `PortProcess.respond/3`. The actual
  callback logic (`fs/*`, `terminal/*`) is kiro-4ff's concern.
  """
  @spec respond(GenServer.server(), integer() | binary(), term()) :: :ok
  def respond(session, request_id, result) when is_integer(request_id) or is_binary(request_id) do
    GenServer.call(session, {:respond, request_id, result}, 5_000)
  end

  @doc """
  Reply to an inbound agent→client request with a JSON-RPC error.

  This is a thin pass-through to `PortProcess.respond_error/5`.
  """
  @spec respond_error(
          GenServer.server(),
          integer() | binary(),
          integer(),
          String.t(),
          term() | nil
        ) ::
          :ok
  def respond_error(session, request_id, code, message, data \\ nil)
      when (is_integer(request_id) or is_binary(request_id)) and is_integer(code) and
             is_binary(message) do
    GenServer.call(session, {:respond_error, request_id, code, message, data}, 5_000)
  end

  @doc """
  Send a JSON-RPC notification to the agent (fire-and-forget).

  This is a thin pass-through to `PortProcess.notify/3` and does not
  update any local turn or stream state. Prefer `cancel/2` for cancellation
  — it does the right thing with `turn_status`.
  """
  @spec notify(GenServer.server(), String.t(), map() | list() | nil) :: :ok
  def notify(session, method, params \\ %{}) when is_binary(method) do
    GenServer.cast(session, {:notify, method, params})
  end

  @doc """
  Request cancellation of the active turn (kiro-1rd / kiro-acp-instructions §8).

  Behavior depends on `turn_status`:

    * `:running` — transitions to `:cancel_requested`, sends a
      `session/cancel` notification with the active `sessionId`, and
      returns `:ok`. The turn is **not** marked complete here —
      cancellation is async per ACP: the agent must wrap up and emit a
      `turn_end` (typically with `reason: "cancelled"`) before
      `turn_status` becomes `:complete`.
    * `:cancel_requested` — idempotent; returns `:ok` without sending another
      notification.
    * `:idle` or `:complete` — returns `{:error, :no_active_turn}`.
    * Any phase other than `:session_active` — returns
      `{:error, {:invalid_phase, phase}}`.

  This is a synchronous `call` so the local state mutation is observable
  immediately on return; the actual notification write is async to the
  port.
  """
  @spec cancel(GenServer.server(), keyword()) :: :ok | {:error, term()}
  def cancel(session, opts \\ []) when is_list(opts) do
    GenServer.call(session, {:cancel, opts}, Keyword.get(opts, :timeout, 5_000))
  end

  @doc """
  Returns the runtime-local buffer of recent normalized stream events,
  oldest-first.

  This is a **runtime cache**, not durable history (§10.2). The buffer is
  bounded by `:stream_buffer_limit` — anything older than the cap has been
  evicted. For full history, query `EventStore`.

  ## Options

    * `:limit` — take the most-recent N events (default: all in buffer).
      Must be a non-negative integer; an invalid value returns
      `{:error, {:invalid_option, {:limit, value}}}` rather than
      crashing the GenServer.
  """
  @spec recent_stream_events(GenServer.server(), keyword()) ::
          [StreamEvent.t()] | {:error, {:invalid_option, {:limit, term()}}}
  def recent_stream_events(session, opts \\ []) when is_list(opts) do
    GenServer.call(session, {:recent_stream_events, opts}, 5_000)
  end

  @doc """
  Stop the session and its transport subprocess gracefully.
  """
  @spec stop(GenServer.server()) :: :ok
  def stop(session) do
    GenServer.stop(session, :normal, 5_000)
  end

  # -- GenServer callbacks --------------------------------------------------

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    with {:ok, executable} <- fetch_required(opts, :executable),
         {:ok, subscriber} <- fetch_required(opts, :subscriber),
         {:ok, buffer_limit} <- fetch_buffer_limit(opts) do
      args = Keyword.get(opts, :args, @default_executable_args)
      auto_callbacks = Keyword.get(opts, :auto_callbacks, true)
      callback_policy = Keyword.get(opts, :callback_policy, @default_callback_policy)

      swarm_hooks =
        Keyword.get(
          opts,
          :swarm_hooks,
          Application.get_env(:kiro_cockpit, :swarm_action_hooks_enabled, true)
        )

      swarm_agent_id = Keyword.get(opts, :swarm_agent_id, "kiro-session")
      swarm_plan_id = Keyword.get(opts, :swarm_plan_id)
      swarm_ctx = Keyword.get(opts, :swarm_ctx, %{})
      plan_mode = Keyword.get(opts, :plan_mode)
      swarm_hooks_module = Keyword.get(opts, :swarm_hooks_module, ActionBoundary)
      # kiro-egn: test_bypass only effective in Mix.env() == :test.
      # Allows direct execution when swarm_hooks is disabled.
      # In production (dev/staging/prod), Mix.env() != :test, so this
      # is always false — non-exempt actions can NEVER bypass.
      explicit_test_bypass = Keyword.get(opts, :test_bypass, false)
      swarm_test_bypass = explicit_test_bypass and Mix.env() == :test

      port_opts =
        [executable: executable, args: args, owner: self()] ++ extra_port_opts(opts)

      case PortProcess.start_link(port_opts) do
        {:ok, port_pid} ->
          port_ref = Process.monitor(port_pid)
          sub_ref = Process.monitor(subscriber)

          # Start TerminalManager if auto_callbacks is enabled.
          # The TerminalManager is linked to this process; if it crashes,
          # KiroSession also exits (which is acceptable for Stage-1).
          terminal_manager = maybe_start_terminal_manager(auto_callbacks, callback_policy)

          state = %__MODULE__{
            port_process: port_pid,
            port_ref: port_ref,
            subscriber: subscriber,
            subscriber_ref: sub_ref,
            executable: executable,
            args: args,
            persist_messages: Keyword.get(opts, :persist_messages, true),
            auto_callbacks: auto_callbacks,
            callback_policy: callback_policy,
            terminal_manager: terminal_manager,
            swarm_hooks: swarm_hooks,
            swarm_agent_id: swarm_agent_id,
            swarm_plan_id: swarm_plan_id,
            swarm_ctx: swarm_ctx,
            plan_mode: plan_mode,
            swarm_hooks_module: swarm_hooks_module,
            swarm_test_bypass: swarm_test_bypass,
            stream_buffer: :queue.new(),
            stream_buffer_limit: buffer_limit
          }

          {:ok, state}

        {:error, reason} ->
          {:stop, {:port_start_failed, reason}}
      end
    end
  end

  # -- Transport-closed guard -----------------------------------------------

  # After the port subprocess exits, the session transitions to
  # `:transport_closed`. All lifecycle calls in this phase return
  # `{:error, :transport_closed}` instead of crashing on `nil` port_process.
  # The session remains alive so `state/1` still works.

  @impl GenServer
  def handle_call({:initialize, _opts}, _from, %{phase: :transport_closed} = state) do
    {:reply, {:error, :transport_closed}, state}
  end

  def handle_call({:new_session, _cwd, _opts}, _from, %{phase: :transport_closed} = state) do
    {:reply, {:error, :transport_closed}, state}
  end

  def handle_call(
        {:load_session, _session_id, _cwd, _opts},
        _from,
        %{phase: :transport_closed} = state
      ) do
    {:reply, {:error, :transport_closed}, state}
  end

  def handle_call({:prompt, _prompt_or_blocks, _opts}, _from, %{phase: :transport_closed} = state) do
    {:reply, {:error, :transport_closed}, state}
  end

  # -- initialize -----------------------------------------------------------

  @impl GenServer
  def handle_call({:initialize, opts}, _from, %{phase: :uninitialized} = state) do
    protocol_version = Keyword.get(opts, :protocol_version, @default_protocol_version)
    client_info = Keyword.get(opts, :client_info, build_default_client_info())

    requested_client_capabilities =
      Keyword.get(
        opts,
        :client_capabilities,
        Callbacks.capabilities_for_policy(state.callback_policy)
      )

    client_capabilities =
      Callbacks.clamp_capabilities_for_policy(
        requested_client_capabilities,
        state.callback_policy
      )

    timeout = Keyword.get(opts, :timeout, @default_request_timeout)

    params = %{
      "protocolVersion" => protocol_version,
      "clientCapabilities" => client_capabilities,
      "clientInfo" => client_info
    }

    result =
      Telemetry.span(:acp, :initialize, %{}, fn ->
        do_initialize(state.port_process, params, protocol_version, timeout)
      end)

    case result do
      {:ok, response} ->
        state = %{
          state
          | phase: :initialized,
            protocol_version: protocol_version,
            client_info: client_info,
            client_capabilities: client_capabilities,
            agent_capabilities: Map.get(response, "agentCapabilities"),
            agent_info: Map.get(response, "agentInfo"),
            auth_methods: Map.get(response, "authMethods", [])
        }

        {:reply, {:ok, response}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:initialize, _opts}, _from, state) do
    {:reply, {:error, {:invalid_phase, state.phase}}, state}
  end

  # -- session/new ----------------------------------------------------------

  @impl GenServer
  def handle_call({:new_session, cwd, opts}, _from, %{phase: :initialized} = state) do
    mcp_servers = Keyword.get(opts, :mcp_servers, [])
    timeout = Keyword.get(opts, :timeout, @default_request_timeout)

    params = %{
      "cwd" => cwd,
      "mcpServers" => mcp_servers
    }

    result =
      Telemetry.span(:session, :create, %{session_id: nil}, fn ->
        case PortProcess.request(state.port_process, "session/new", params, timeout) do
          {:ok, response} -> {{:ok, response}, %{session_id: Map.get(response, "sessionId")}}
          {:error, reason} -> {{:error, reason}, %{}}
        end
      end)

    case result do
      {:ok, response} ->
        session_id = Map.get(response, "sessionId")

        state = %{
          state
          | phase: :session_active,
            session_id: session_id,
            cwd: cwd,
            modes: Map.get(response, "modes"),
            config_options: Map.get(response, "configOptions")
        }

        {:reply, {:ok, response}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:new_session, _cwd, _opts}, _from, state) do
    {:reply, {:error, {:invalid_phase, state.phase}}, state}
  end

  # -- session/load ---------------------------------------------------------

  @impl GenServer
  def handle_call({:load_session, session_id, cwd, opts}, _from, %{phase: :initialized} = state) do
    mcp_servers = Keyword.get(opts, :mcp_servers, [])
    timeout = Keyword.get(opts, :timeout, @default_request_timeout)

    params = %{
      "sessionId" => session_id,
      "cwd" => cwd,
      "mcpServers" => mcp_servers
    }

    result =
      Telemetry.span(:session, :resume, %{session_id: session_id}, fn ->
        case PortProcess.request(state.port_process, "session/load", params, timeout) do
          {:ok, response} -> {{:ok, response}, %{session_id: session_id}}
          {:error, reason} -> {{:error, reason}, %{}}
        end
      end)

    case result do
      {:ok, _response} ->
        state = %{
          state
          | phase: :session_active,
            session_id: session_id,
            cwd: cwd
        }

        {:reply, {:ok, nil}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:load_session, _session_id, _cwd, _opts}, _from, state) do
    {:reply, {:error, {:invalid_phase, state.phase}}, state}
  end

  # -- session/prompt (async) -----------------------------------------------

  # Happy path: session is active, no in-flight RPC, and the prior turn
  # has been observed as fully complete (turn_end already landed) or
  # there has been no turn at all (idle).
  @impl GenServer
  def handle_call(
        {:prompt, prompt_or_blocks, opts},
        from,
        %{phase: :session_active, pending_prompt: nil, turn_status: turn_status} = state
      )
      when turn_status in [:idle, :complete] do
    # Swarm action hook boundary (kiro-00j): run pre-hooks before prompt.
    # The actual prompt-start runs inside the executor fun so that
    # pre/post trace semantics match the real action start.
    # Blocked prompts return immediately and do not start a turn or send
    # a prompt to the agent.
    # kiro-egn: Non-bypassable action boundary.
    # When swarm_hooks is disabled, non-exempt actions (like prompts)
    # MUST fail closed. Only test_bypass allows direct execution in
    # test environment.
    if state.swarm_hooks do
      boundary_opts = prompt_boundary_opts(state, opts)

      run_hooks_if_enabled(
        state.swarm_hooks_module,
        :kiro_session_prompt,
        boundary_opts,
        fn -> do_start_prompt(prompt_or_blocks, opts, from, state) end,
        state
      )
    else
      # swarm_hooks disabled — non-exempt action must fail closed (kiro-egn)
      # Only test_bypass (set at init, only effective in Mix.env() == :test)
      # allows direct execution.
      if state.swarm_test_bypass do
        do_start_prompt(prompt_or_blocks, opts, from, state)
      else
        {:reply, {:error, {:swarm_boundary_disabled, :kiro_session_prompt}}, state}
      end
    end
  end

  # An RPC is currently on the wire — short-circuit fast.
  def handle_call({:prompt, _prompt_or_blocks, _opts}, _from, %{pending_prompt: pp} = state)
      when not is_nil(pp) do
    {:reply, {:error, :prompt_in_progress}, state}
  end

  # Active-turn guard (kiro-1rd Shepherd MUST fix): the previous prompt's
  # RPC result has returned (`pending_prompt: nil`) but no normalized
  # `:turn_end` event has arrived, so the turn is still in flight from
  # the runtime's perspective. Reject with a stable distinct atom so
  # callers can tell this apart from `:prompt_in_progress`.
  def handle_call({:prompt, _prompt_or_blocks, _opts}, _from, %{turn_status: ts} = state)
      when ts in [:running, :cancel_requested] do
    {:reply, {:error, :turn_in_progress}, state}
  end

  def handle_call({:prompt, _prompt_or_blocks, _opts}, _from, state) do
    {:reply, {:error, {:invalid_phase, state.phase}}, state}
  end

  # -- state ----------------------------------------------------------------

  @impl GenServer
  def handle_call(:state, _from, state) do
    summary = %{
      phase: state.phase,
      session_id: state.session_id,
      cwd: state.cwd,
      agent_capabilities: state.agent_capabilities,
      agent_info: state.agent_info,
      auth_methods: state.auth_methods,
      modes: state.modes,
      config_options: state.config_options,
      protocol_version: state.protocol_version,
      client_capabilities: state.client_capabilities,
      auto_callbacks: state.auto_callbacks,
      callback_policy: state.callback_policy,
      turn_id: state.turn_id,
      turn_status: state.turn_status,
      last_stop_reason: state.last_stop_reason,
      stream_sequence: state.stream_sequence,
      stream_buffer_size: state.stream_buffer_size,
      stream_buffer_limit: state.stream_buffer_limit,
      stream_dropped_count: state.stream_dropped_count,
      swarm_hooks: state.swarm_hooks,
      swarm_agent_id: state.swarm_agent_id,
      swarm_plan_id: state.swarm_plan_id,
      swarm_ctx: state.swarm_ctx,
      swarm_test_bypass: state.swarm_test_bypass
    }

    {:reply, summary, state}
  end

  # -- cancel ---------------------------------------------------------------

  def handle_call({:cancel, _opts}, _from, %{phase: :transport_closed} = state) do
    {:reply, {:error, :transport_closed}, state}
  end

  def handle_call({:cancel, _opts}, _from, %{phase: phase} = state)
      when phase != :session_active do
    {:reply, {:error, {:invalid_phase, phase}}, state}
  end

  def handle_call({:cancel, _opts}, _from, %{turn_status: :running} = state) do
    # Route egress through ActionBoundary.run_egress/3 (kiro-bih).
    # cancel is EXEMPT from pre-hook blocking (safety mechanism), but
    # Bronze action_before/action_after records are still emitted with
    # full session/plan/task/agent correlation per §27.11 inv. 7.
    params = %{"sessionId" => state.session_id}

    egress_result =
      run_egress_if_hooks(state, :acp_egress_cancel, [method: "session/cancel"], fn ->
        PortProcess.notify(state.port_process, "session/cancel", params)
      end)

    # cancel is exempt — egress_result is always {:ok, _} when hooks enabled.
    # When hooks disabled, the notification is still sent.
    _ = egress_result

    # Local state flips immediately so callers see :cancel_requested.
    {:reply, :ok, %{state | turn_status: :cancel_requested}}
  end

  def handle_call({:cancel, _opts}, _from, %{turn_status: :cancel_requested} = state) do
    # Idempotent.
    {:reply, :ok, state}
  end

  def handle_call({:cancel, _opts}, _from, state) do
    {:reply, {:error, :no_active_turn}, state}
  end

  # -- recent_stream_events -------------------------------------------------

  def handle_call({:recent_stream_events, opts}, _from, state) do
    case fetch_events_limit(opts) do
      {:ok, nil} ->
        {:reply, :queue.to_list(state.stream_buffer), state}

      {:ok, n} ->
        {:reply, Enum.take(:queue.to_list(state.stream_buffer), -n), state}

      {:error, reason} ->
        # Invalid `:limit` is a caller bug, not a runtime fault. Surface
        # it as a plain error tuple so the GenServer keeps serving.
        {:reply, {:error, reason}, state}
    end
  end

  # -- respond / respond_error / notify -------------------------------------

  @impl GenServer
  def handle_call({:respond, request_id, result}, _from, %{port_process: port_pid} = state)
      when is_pid(port_pid) do
    # Route egress through ActionBoundary.run_egress/3 (kiro-bih).
    # respond is EXEMPT from pre-hook blocking (protocol completion —
    # the agent is waiting for a response), but Bronze action lifecycle
    # records are still emitted with correlation per §27.11 inv. 7.
    egress_result =
      run_egress_if_hooks(
        state,
        :acp_egress_respond,
        [method: "callback_response", request_id: request_id],
        fn ->
          PortProcess.respond(port_pid, request_id, result)
        end
      )

    # respond is exempt — always {:ok, _} when hooks enabled.
    _ = egress_result
    {:reply, :ok, state}
  end

  def handle_call({:respond, _request_id, _result}, _from, state) do
    {:reply, {:error, :transport_closed}, state}
  end

  @impl GenServer
  def handle_call(
        {:respond_error, request_id, code, message, data},
        _from,
        %{port_process: port_pid} = state
      )
      when is_pid(port_pid) do
    # Route egress through ActionBoundary.run_egress/3 (kiro-bih).
    # respond_error is EXEMPT from pre-hook blocking (protocol completion —
    # the agent is waiting for a response), but Bronze action lifecycle
    # records are still emitted with correlation per §27.11 inv. 7.
    egress_result =
      run_egress_if_hooks(
        state,
        :acp_egress_respond_error,
        [method: "callback_response_error", request_id: request_id],
        fn -> PortProcess.respond_error(port_pid, request_id, code, message, data) end
      )

    # respond_error is exempt — always {:ok, _} when hooks enabled.
    _ = egress_result
    {:reply, :ok, state}
  end

  def handle_call({:respond_error, _request_id, _code, _message, _data}, _from, state) do
    {:reply, {:error, :transport_closed}, state}
  end

  @impl GenServer
  def handle_cast({:notify, method, params}, %{port_process: port_pid} = state)
      when is_pid(port_pid) do
    # Route egress through ActionBoundary.run_egress/3 (kiro-bih, kiro-fmn).
    # notify is NON-EXEMPT — pre-hooks may block it. When blocked, the
    # notification is dropped (fire-and-forget cast semantics), but the
    # blocked attempt is recorded in Bronze per §27.11 inv. 7.
    # kiro-fmn: when boundary is disabled and swarm_hooks is false, non-exempt
    # egress fails closed — the notification is dropped (same semantics as
    # a block, but the boundary returns {:swarm_boundary_disabled, action}).
    case run_egress_if_hooks(state, :acp_egress_notify, [method: method], fn ->
           PortProcess.notify(port_pid, method, params)
         end) do
      {:ok, _} -> :ok
      # dropped, Bronze records it
      {:error, {:swarm_blocked, _reason, _messages}} -> :ok
      # kiro-fmn: boundary disabled for non-exempt egress — fail closed
      {:error, {:swarm_boundary_disabled, _action}} -> :ok
    end

    {:noreply, state}
  end

  def handle_cast({:notify, _method, _params}, state) do
    {:noreply, state}
  end

  # -- Inbound message forwarding -------------------------------------------

  @impl GenServer
  def handle_info({:acp_outbound, port_pid, payload}, %{port_process: port_pid} = state) do
    # Exact raw outbound JSON-RPC payload from PortProcess — persist the
    # true wire map (including the real assigned id) without reconstruction.
    persist_raw_outbound(state, payload)
    {:noreply, state}
  end

  # Inbound JSON-RPC response/error forwarded by PortProcess after
  # resolve_pending/3. These are responses to KiroSession-originated
  # requests (e.g. session/prompt result). PortProcess already resolved
  # the pending GenServer call; we persist the raw ACP and Bronze rows.
  @impl GenServer
  def handle_info({:acp_inbound_response, port_pid, payload}, %{port_process: port_pid} = state) do
    persist_inbound_response(state, payload)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:acp_notification, port_pid, msg}, %{port_process: port_pid} = state) do
    # 1. Forward raw notification to subscriber (back-compat).
    send(state.subscriber, {:acp_notification, self(), msg})
    # 2. Persist (best-effort) before any normalization side-effects.
    persist_inbound(state, msg)
    # 3. Normalize and fan out to subscriber if it's a session/update.
    state = maybe_emit_stream_event(state, msg)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:acp_request, port_pid, msg}, %{port_process: port_pid} = state) do
    # Always forward to subscriber for observability/backward compatibility.
    send(state.subscriber, {:acp_request, self(), msg})
    persist_inbound(state, msg)
    # Auto-handle known callback methods when enabled (kiro-4ff).
    maybe_auto_handle_callback(state, port_pid, msg)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:acp_protocol_error, port_pid, reason, raw}, %{port_process: port_pid} = state) do
    Logger.warning(fn -> "KiroSession ACP protocol error: #{inspect(reason)}" end)
    send(state.subscriber, {:acp_protocol_error, self(), reason, raw})
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:acp_exit, port_pid, status}, %{port_process: port_pid} = state) do
    Logger.info(fn -> "KiroSession ACP port exited with status: #{inspect(status)}" end)

    state = reply_pending_prompt(state, {:error, {:port_exited, status}})
    send(state.subscriber, {:acp_exit, self(), status})

    {:noreply, %{state | phase: :transport_closed, port_process: nil, port_ref: nil}}
  end

  # Prompt task completed successfully
  @impl GenServer
  def handle_info({:prompt_result, _result}, %{pending_prompt: nil} = state) do
    # Already replied (e.g. via :acp_exit). Discard duplicate.
    {:noreply, state}
  end

  def handle_info({:prompt_result, result}, %{pending_prompt: from} = state)
      when not is_nil(from) do
    GenServer.reply(from, result)
    emit_prompt_telemetry(:stop, state.session_id)

    # Turn discipline (kiro-1rd): record the prompt's stopReason for
    # introspection but do NOT flip turn_status here. The turn isn't
    # complete until the normalized :turn_end event arrives.
    state = record_prompt_stop_reason(state, result)

    cleanup_prompt(state)
  end

  # Prompt task crashed
  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{prompt_task_ref: ref} = state) do
    state = reply_pending_prompt(state, {:error, {:prompt_task_crashed, reason}})
    {:noreply, state}
  end

  # Port process died (monitor from init)
  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{port_ref: ref} = state) do
    Logger.warning(fn -> "KiroSession port process down: #{inspect(reason)}" end)

    state = reply_pending_prompt(state, {:error, {:port_exited, reason}})
    send(state.subscriber, {:acp_exit, self(), reason})

    {:noreply, %{state | phase: :transport_closed, port_process: nil, port_ref: nil}}
  end

  # Subscriber died
  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{subscriber_ref: ref} = state) do
    Logger.warning(fn -> "KiroSession subscriber down; stopping session" end)
    state = reply_pending_prompt(state, {:error, :subscriber_down})
    {:stop, :normal, state}
  end

  # Ignore stale messages from unknown port pids
  @impl GenServer
  def handle_info({:acp_outbound, _port_pid, _payload}, state), do: {:noreply, state}

  def handle_info({:acp_inbound_response, _port_pid, _payload}, state), do: {:noreply, state}

  def handle_info({:acp_notification, _port_pid, _msg}, state), do: {:noreply, state}

  def handle_info({:acp_request, _port_pid, _msg}, state), do: {:noreply, state}

  def handle_info({:acp_protocol_error, _port_pid, _, _}, state), do: {:noreply, state}

  def handle_info({:acp_exit, _port_pid, _}, state), do: {:noreply, state}

  # Catch-all for unknown messages
  @impl GenServer
  def handle_info(msg, state) do
    Logger.debug(fn -> "KiroSession ignoring: #{inspect(msg)}" end)
    {:noreply, state}
  end

  @impl GenServer
  def terminate(reason, state) do
    # Crash dump (kiro-1rd / plan2.md §12.9): on abnormal stop, emit a
    # structured snapshot before the process dies. Storage owns truth;
    # this dump is the runtime's last word for debugging.
    if abnormal?(reason), do: dump_crash(reason, state)

    state = reply_pending_prompt(state, {:error, :session_terminated})

    if is_pid(state.port_process) and Process.alive?(state.port_process) do
      PortProcess.stop(state.port_process, :normal, 2_000)
    end

    # Clean up TerminalManager (kiro-4ff): kill all running terminal
    # processes. TerminalManager.terminate/2 handles port cleanup.
    if state.terminal_manager != nil and Process.alive?(state.terminal_manager) do
      TerminalManager.stop(state.terminal_manager)
    end

    :ok
  end

  # -- Internals ------------------------------------------------------------

  # -- Prompt boundary helpers (kiro-00j) -----------------------------------

  # Executes the prompt after boundary approval — starts the Task, monitors, etc.
  defp do_start_prompt(prompt_or_blocks, opts, from, state) do
    blocks = normalize_prompt(prompt_or_blocks)
    timeout = Keyword.get(opts, :timeout, @default_prompt_timeout)

    params = %{
      "sessionId" => state.session_id,
      "prompt" => blocks
    }

    emit_prompt_telemetry(:start, state.session_id)

    parent = self()
    port_pid = state.port_process

    {:ok, task_pid} =
      Task.start(fn ->
        result = PortProcess.request(port_pid, "session/prompt", params, timeout)
        send(parent, {:prompt_result, result})
      end)

    task_ref = Process.monitor(task_pid)

    # Turn discipline (kiro-1rd): mark the turn running. The prompt RPC
    # result alone will NOT mark the turn complete — we wait for a
    # normalized `:turn_end` stream event.
    state = %{
      state
      | pending_prompt: from,
        prompt_task_ref: task_ref,
        turn_id: state.turn_id + 1,
        turn_status: :running,
        last_stop_reason: nil
    }

    {:noreply, state}
  end

  # Build boundary options for prompt action.
  # Merges session-level swarm_ctx (durable trusted flags) into the
  # boundary opts so hooks see approved/policy flags set at session
  # construction time.
  #
  # Derives plan_mode from durable plan status when a plan_id is available
  # from opts, or state.swarm_plan_id, and no explicit plan_mode exists.
  # This makes execution prompt opts from NanoPlanner.approve produce an
  # executing/approved plan mode without caller explicitly passing PlanMode.
  #
  # Sets permission_level to :executor_dispatch for KiroSession.prompt to
  # distinguish it from arbitrary subagent invocation. This is a control-plane
  # action that bypasses category/scope checks when plan is approved and
  # active task exists (kiro-rhk issue bd).
  #
  # kiro-8v5: Public prompt opts are sanitized before the merge so that
  # untrusted caller keys cannot override server-derived trust/authorization
  # fields.  Only keys in `@safe_prompt_opt_keys` survive.  Authorization
  # flags (approved, policy_allows_write, plan_mode, permission_level,
  # enabled, swarm_ctx, session_id, agent_id, project_dir, and hook/trust
  # flags) are ALWAYS taken from server state — never from caller opts.
  defp prompt_boundary_opts(state, opts) do
    # derive_plan_mode reads plan_id from raw opts (pre-sanitization)
    # because it uses plan_id as a lookup key for DB derivation.
    plan_mode = state.plan_mode || derive_plan_mode(opts, state)
    safe_opts = sanitize_prompt_opts(opts)

    Keyword.merge(
      [
        session_id: state.session_id,
        agent_id: state.swarm_agent_id,
        plan_id: state.swarm_plan_id,
        permission_level: :executor_dispatch,
        project_dir: state.cwd,
        plan_mode: plan_mode,
        swarm_ctx: state.swarm_ctx,
        approved: truthy_lookup(state.swarm_ctx, :approved),
        # kiro-egn: per-session swarm_hooks=true overrides app config disabled.
        # Without this, ActionBoundary.boundary_enabled?/1 falls back to
        # Application env (:swarm_action_hooks_enabled, false in test),
        # which would disable the boundary even when the session explicitly
        # enables hooks.
        enabled: state.swarm_hooks
      ],
      safe_opts
    )
  end

  @doc """
  Sanitizes public prompt opts by keeping only safe keys.

  kiro-8v5: Untrusted caller opts passed to `prompt/3` must not be able
  to override server-derived boundary fields (plan_mode, approved,
  permission_level, etc.). This function strips every key NOT in the
  `@safe_prompt_opt_keys` whitelist before the merge in
  `prompt_boundary_opts/2`.

  Authorization flags are always derived from server state or durable
  DB state by `ActionBoundary`, never from caller opts.
  """
  @doc since: "0.1.0"
  @spec sanitize_prompt_opts(keyword()) :: keyword()
  def sanitize_prompt_opts(opts) when is_list(opts) do
    Keyword.take(opts, @safe_prompt_opt_keys)
  end

  # Run hooks through the boundary module if enabled; otherwise invoke
  # the fun directly. Unifies the if/case nesting pattern used by
  # prompt and callback boundary entry points.
  defp run_hooks_if_enabled(hooks_module, action, boundary_opts, fun, state) do
    case hooks_module.run(action, boundary_opts, fun) do
      {:ok, {:noreply, new_state}} ->
        {:noreply, new_state}

      {:error, {:swarm_blocked, reason, messages}} ->
        {:reply, {:error, {:swarm_blocked, reason, messages}}, state}

      # kiro-egn: defensive handling — boundary returned disabled for
      # a non-exempt action. Return stable error instead of GenServer
      # crash from unhandled clause.
      {:error, {:swarm_boundary_disabled, action}} ->
        {:reply, {:error, {:swarm_boundary_disabled, action}}, state}
    end
  end

  # -- ACP egress boundary routing (kiro-bih, kiro-fmn) ---------------------
  #
  # All ACP egress actions are routed through ActionBoundary.run_egress/3
  # with enabled: state.swarm_hooks so the boundary decides enforcement.
  #
  # When swarm_hooks is true, the boundary enforces:
  #   - Exempt actions (cancel, respond, respond_error) — execute with Bronze audit
  #   - Non-exempt actions (notify) — full boundary pipeline (can be blocked)
  #
  # When swarm_hooks is false (enabled: false), the boundary fails closed
  # for non-exempt egress and executes exempt egress with Bronze audit
  # (kiro-fmn: non-bypassable enforcement for egress).

  defp run_egress_if_hooks(state, action, extra, fun)
       when is_list(extra) and is_function(fun, 0) do
    boundary_opts = egress_boundary_opts(state, extra)
    state.swarm_hooks_module.run_egress(action, boundary_opts, fun)
  end

  # Build boundary options for ACP egress actions.
  # Egress actions are client→agent messages; permission_level is :read
  # because they don't directly modify the environment (the agent decides
  # how to act on them). Persists egress_type and method in payload and
  # raw_payload (not metadata-only) so Bronze action capture records the
  # ACP method. Mirrors callback_boundary_opts style (kiro-bih).
  defp egress_boundary_opts(state, extra) do
    plan_mode = state.plan_mode || derive_plan_mode([], state)

    base =
      [
        session_id: state.session_id,
        agent_id: state.swarm_agent_id,
        plan_id: state.swarm_plan_id,
        permission_level: :read,
        project_dir: state.cwd,
        plan_mode: plan_mode,
        swarm_ctx: state.swarm_ctx,
        # kiro-fmn: pass session's swarm_hooks as enabled so the boundary
        # enforces fail-closed for non-exempt egress even when app config
        # has :swarm_action_hooks_enabled = false.
        enabled: state.swarm_hooks,
        # kiro-fmn: pass test_bypass so ActionBoundary.run_egress/3 can
        # allow non-exempt egress in test env when boundary is disabled
        # (mirrors the test_bypass_allowed? check in handle_disabled_boundary/3).
        test_bypass: state.swarm_test_bypass
      ]

    extra_map = Enum.into(extra, %{})
    egress_method = Map.get(extra_map, :method)

    # Metadata for hook context (not directly persisted in Bronze rows)
    metadata =
      extra_map
      |> Map.put(:egress_type, :acp_egress)

    # Payload: egress_type + egress_method so Bronze payload summary
    # captures the keys (and full values in safe mode).
    payload = %{
      egress_type: :acp_egress,
      egress_method: egress_method
    }

    # Raw payload: method key so Bronze summarizer extracts it as
    # method_hint in the raw_payload_summary. Include request_id as
    # :id when present (safe correlation integer — avoids leaking
    # full result/error payloads).
    raw_payload = %{method: egress_method}

    raw_payload =
      case Map.get(extra_map, :request_id) do
        nil -> raw_payload
        request_id -> Map.put(raw_payload, :id, request_id)
      end

    base
    |> Keyword.put(:metadata, metadata)
    |> Keyword.put(:payload, payload)
    |> Keyword.put(:raw_payload, raw_payload)
  end

  defp truthy_lookup(map, key) when is_map(map) do
    case Map.get(map, key) do
      true -> true
      "true" -> true
      1 -> true
      "1" -> true
      :yes -> true
      "yes" -> true
      _ -> false
    end
  end

  defp truthy_lookup(_nil_or_not_map, _key), do: false
  # -- Auto callback handling (kiro-4ff) ------------------------------------

  # When auto_callbacks is enabled and the inbound request method is known,
  # dispatch to the callback handler and send the JSON-RPC response
  # automatically. The subscriber still receives the raw request for
  # observability but does NOT need to call respond/3.
  #
  # Unknown methods are NOT auto-handled — the subscriber must respond.
  #
  # Terminal methods are dispatched in a Task to avoid blocking the
  # GenServer (terminal/wait_for_exit may block until the process exits).
  @spec maybe_auto_handle_callback(t(), pid(), map()) :: :ok
  defp maybe_auto_handle_callback(%{auto_callbacks: false}, _port_pid, _msg), do: :ok

  defp maybe_auto_handle_callback(state, port_pid, %{id: id, method: method, params: params}) do
    cond do
      not Callbacks.known_method?(method) ->
        :ok

      state.swarm_hooks ->
        # When hooks are enabled, run the boundary BEFORE policy denial
        # (kiro-00j issue 5). This ensures no-active-task/scope/stale
        # blocks are visible in Bronze traces before policy denial.
        # The real callback dispatch runs inside the executor fun so
        # pre/post trace semantics match the actual action (kiro-00j
        # issue 4).
        run_callback_with_boundary(state, port_pid, id, method, params)

      not Callbacks.allowed_by_policy?(method, state.callback_policy) ->
        # Method is known but denied by policy — auto-respond with error.
        # For observability the subscriber still received the raw request.
        {:error, code, message, data} = Callbacks.denied_error(method)
        PortProcess.respond_error(port_pid, id, code, message, data)
        :ok

      true ->
        # kiro-egn: swarm_hooks is disabled but method is known and
        # policy allows it. Non-exempt callback actions must fail closed
        # rather than executing without boundary enforcement.
        # Only swarm_test_bypass (set at init, only in Mix.env() == :test)
        # allows direct execution.
        {action, _permission} = Callbacks.action_mapping(method)

        if state.swarm_test_bypass or ActionBoundary.exempt_action?(action) do
          dispatch_callback(state, port_pid, id, method, params)
        else
          PortProcess.respond_error(
            port_pid,
            id,
            -32_000,
            "Action blocked: swarm boundary disabled for non-exempt action",
            nil
          )
        end
    end

    :ok
  end

  defp maybe_auto_handle_callback(_state, _port_pid, _msg), do: :ok

  # Run the action boundary for known callback methods.
  # The boundary runs BEFORE policy denial when hooks are enabled (issue 5).
  # The actual callback dispatch executes inside the executor fun so
  # pre/post trace semantics match the real action (issue 4).
  # If hooks allow but callback_policy denies, respond with
  # Callbacks.denied_error (preserving existing behavior).
  defp run_callback_with_boundary(state, port_pid, id, method, params) do
    {action, permission} = Callbacks.action_mapping(method)
    target_path = extract_callback_target_path(method, params)

    boundary_opts =
      callback_boundary_opts(state, action, permission, target_path, params, method)

    case state.swarm_hooks_module.run(action, boundary_opts, fn ->
           dispatch_if_policy_allows(state, port_pid, id, method, params)
         end) do
      {:ok, _result} ->
        :ok

      {:error, {:swarm_blocked, reason, _messages}} ->
        PortProcess.respond_error(
          port_pid,
          id,
          -32_000,
          "Action blocked by swarm boundary: #{reason}",
          nil
        )

      # kiro-egn: defensive handling — boundary returned disabled for
      # a non-exempt callback action. Respond with error instead of
      # GenServer crash from unhandled clause. No side effect dispatched.
      {:error, {:swarm_boundary_disabled, ^action}} ->
        PortProcess.respond_error(
          port_pid,
          id,
          -32_000,
          "Action blocked: swarm boundary disabled for non-exempt action",
          nil
        )
    end
  end

  # Dispatch callback if policy allows; otherwise respond with denied_error.
  # Extracted from run_callback_with_boundary to reduce nesting depth.
  defp dispatch_if_policy_allows(state, port_pid, id, method, params) do
    if Callbacks.allowed_by_policy?(method, state.callback_policy) do
      dispatch_callback(state, port_pid, id, method, params)
    else
      {:error, code, message, data} = Callbacks.denied_error(method)
      PortProcess.respond_error(port_pid, id, code, message, data)
    end
  end

  # Dispatch the actual callback (sync or async terminal).
  defp dispatch_callback(state, port_pid, id, method, params) do
    if String.starts_with?(method, "terminal/") do
      handle_terminal_callback_async(state, port_pid, id, method, params)
    else
      handle_sync_callback(state, port_pid, id, method, params)
    end
  end

  # callback_action_mapping/1 moved to Callbacks.action_mapping/1 (kiro-2ai).

  # Extract target file path from callback params for file scope checks.
  defp extract_callback_target_path("fs/" <> _, params) when is_map(params) do
    Map.get(params, "path")
  end

  defp extract_callback_target_path(_method, _params), do: nil

  # Build boundary options for callback actions.
  # Includes session-level swarm_ctx for durable trusted flags.
  # Derives plan_mode from durable plan status when a plan_id is available
  # from state.swarm_plan_id and no explicit plan_mode exists.
  # The raw `method` string is always included in metadata/payload for
  # observability — even when the action atom is a stable fallback
  # (kiro-2ai: no String.to_atom on unknown methods).
  defp callback_boundary_opts(state, _action, permission, target_path, _params, method) do
    plan_mode = state.plan_mode || derive_plan_mode([], state)

    base =
      [
        session_id: state.session_id,
        agent_id: state.swarm_agent_id,
        plan_id: state.swarm_plan_id,
        permission_level: permission,
        project_dir: state.cwd,
        plan_mode: plan_mode,
        swarm_ctx: state.swarm_ctx,
        # kiro-egn: per-session swarm_hooks=true overrides app config disabled.
        # See prompt_boundary_opts/2 for rationale.
        enabled: state.swarm_hooks
      ]

    meta = %{callback_method: method}
    payload = %{callback_method: method}

    meta = if target_path, do: Map.put(meta, :target_path, target_path), else: meta
    payload = if target_path, do: Map.put(payload, :target_path, target_path), else: payload

    base
    |> Keyword.put(:metadata, meta)
    |> Keyword.put(:payload, payload)
  end

  # Derive plan_mode from durable plan status when a plan_id is available.
  # Checks opts first, then state.swarm_plan_id.
  #
  # kiro-6dw: Fail-closed — when a plan_id exists but the plan cannot
  # be loaded from the durable store, return a locked PlanMode instead
  # of nil/idle. Unknown/missing durable plan state for plan-correlated
  # execution must fail closed. Only when no plan_id exists at all does
  # the function return nil (no plan → no plan-mode restriction).
  defp derive_plan_mode(opts, state) do
    plan_id =
      Keyword.get(opts, :plan_id) || Keyword.get(opts, :swarm_plan_id) || state.swarm_plan_id

    do_derive_plan_mode(plan_id)
  end

  defp do_derive_plan_mode(nil), do: nil

  defp do_derive_plan_mode(plan_id) do
    case Plans.get_plan(plan_id) do
      nil ->
        # Plan referenced but not found — fail closed (kiro-6dw)
        PlanMode.locked(plan_id, :plan_not_found)

      plan ->
        # Delegate all status handling (including corrupt/non-binary)
        # to PlanMode.from_plan/1 at the widened API boundary (kiro-6dw).
        PlanMode.from_plan(plan)
    end
  rescue
    # DB/plan lookup failure during plan-correlated execution — fail closed
    _ -> PlanMode.locked(plan_id, :plan_lookup_failed)
  end

  # fs/* methods are fast file operations — handle synchronously.
  @spec handle_sync_callback(t(), pid(), integer() | binary(), String.t(), map()) :: :ok
  defp handle_sync_callback(state, port_pid, id, method, params) do
    case Callbacks.handle_request(method, params, state.terminal_manager) do
      {:ok, result} ->
        PortProcess.respond(port_pid, id, result)

      {:error, code, message, data} ->
        PortProcess.respond_error(port_pid, id, code, message, data)
    end

    :ok
  end

  # terminal/* methods may block (wait_for_exit) — handle async via Task.
  # Both exceptions and exits from Callbacks.handle_request/3 (e.g. a dead
  # TerminalManager causing GenServer.call to exit) are converted to a safe
  # JSON-RPC Internal error response. safe_respond also catches exits around
  # response-sending itself, so a dead PortProcess won't crash the Task either.
  @spec handle_terminal_callback_async(t(), pid(), integer() | binary(), String.t(), term()) ::
          :ok
  defp handle_terminal_callback_async(state, port_pid, id, method, params) do
    tm = state.terminal_manager

    Task.start(fn ->
      method
      |> run_terminal_callback(params, tm)
      |> send_terminal_callback_response(port_pid, id)
    end)

    :ok
  end

  @spec run_terminal_callback(String.t(), term(), GenServer.server() | nil) ::
          {:ok, term()} | {:error, integer(), String.t(), term()}
  defp run_terminal_callback(method, params, terminal_manager) do
    Callbacks.handle_request(method, params, terminal_manager)
  catch
    :exit, reason ->
      Logger.warning(fn ->
        "KiroSession terminal callback handler exited: #{inspect(reason)}"
      end)

      {:error, -32_000, "Internal error", nil}

    :error, exception ->
      Logger.warning(fn ->
        "KiroSession terminal callback handler crashed: #{Exception.message(exception)}"
      end)

      {:error, -32_000, "Internal error", nil}
  end

  @spec send_terminal_callback_response(
          {:ok, term()} | {:error, integer(), String.t(), term()},
          pid(),
          JsonRpc.id()
        ) :: :ok
  defp send_terminal_callback_response({:ok, value}, port_pid, id) do
    safe_respond(port_pid, id, fn ->
      PortProcess.respond(port_pid, id, value)
    end)
  end

  defp send_terminal_callback_response({:error, code, message, data}, port_pid, id) do
    safe_respond(port_pid, id, fn ->
      PortProcess.respond_error(port_pid, id, code, message, data)
    end)
  end

  # Best-effort response: if the ACP port process has died, respond/3 or
  # respond_error/5 may exit. We catch that to avoid a noisy Task crash —
  # the port is already gone so there's nobody to tell anyway.
  @spec safe_respond(pid(), JsonRpc.id(), (-> :ok)) :: :ok
  defp safe_respond(_port_pid, _id, fun) do
    try do
      fun.()
    catch
      :exit, _ -> :ok
    end

    :ok
  end

  @spec fetch_required(keyword(), atom()) :: {:ok, term()} | {:stop, term()}
  defp fetch_required(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:stop, {:invalid_option, key}}
    end
  end

  @spec maybe_start_terminal_manager(boolean(), Callbacks.callback_policy()) :: pid() | nil
  defp maybe_start_terminal_manager(true, policy) when policy in [:all, :trusted] do
    {:ok, tm} = TerminalManager.start_link()
    tm
  end

  defp maybe_start_terminal_manager(true, :read_only), do: nil

  defp maybe_start_terminal_manager(false, _policy), do: nil

  @spec do_initialize(pid(), map(), pos_integer(), timeout()) ::
          {{:ok, map()}, map()} | {{:error, term()}, map()}
  defp do_initialize(port_pid, params, protocol_version, timeout) do
    case PortProcess.request(port_pid, "initialize", params, timeout) do
      {:ok, %{"protocolVersion" => ^protocol_version} = response} ->
        {{:ok, response}, %{}}

      {:ok, %{"protocolVersion" => other}} ->
        {{:error, {:protocol_version_mismatch, expected: protocol_version, got: other}}, %{}}

      {:ok, response} ->
        # Agent omitted protocolVersion — accept leniently with a warning.
        Logger.warning(fn ->
          "Agent initialize response missing protocolVersion; accepting leniently"
        end)

        {{:ok, response}, %{}}

      {:error, reason} ->
        {{:error, reason}, %{}}
    end
  end

  @spec extra_port_opts(keyword()) :: keyword()
  defp extra_port_opts(opts) do
    []
    |> maybe_add(:cd, Keyword.get(opts, :cd))
    |> maybe_add(:env, Keyword.get(opts, :env))
    |> maybe_add(:max_line_bytes, Keyword.get(opts, :max_line_bytes))
  end

  @spec maybe_add(keyword(), atom(), term()) :: keyword()
  defp maybe_add(list, _key, nil), do: list
  defp maybe_add(list, key, value), do: list ++ [{key, value}]

  @spec build_default_client_info() :: map()
  defp build_default_client_info do
    %{
      "name" => @default_client_name,
      "title" => @default_client_title,
      "version" => @default_client_version
    }
  end

  @spec normalize_prompt(binary() | [map()]) :: [map()]
  defp normalize_prompt(text) when is_binary(text) do
    [%{"type" => "text", "text" => text}]
  end

  defp normalize_prompt(blocks) when is_list(blocks), do: blocks

  # -- Stream event normalization (kiro-1rd) -------------------------------

  # Only `session/update` notifications normalize into stream events. Other
  # methods (e.g. agent-initiated `_kiro.dev/...` if any are notifications)
  # pass through the legacy raw forwarding path only.
  @spec maybe_emit_stream_event(t(), map()) :: t()
  defp maybe_emit_stream_event(state, %{method: "session/update", params: params})
       when is_map(params) do
    sequence = state.stream_sequence
    occurred_at = DateTime.utc_now()
    event = StreamEvent.normalize(params, sequence, occurred_at)

    # Push to subscriber FIRST — ordering must follow inbound arrival.
    send(state.subscriber, {:kiro_stream_event, self(), event})

    state = enqueue_stream_event(state, event)
    state = apply_turn_end_if_present(state, event)
    %{state | stream_sequence: sequence + 1}
  end

  defp maybe_emit_stream_event(state, _msg), do: state

  # Bounded enqueue: if at limit, drop oldest, bump dropped_count, and
  # send a one-shot overflow marker to the subscriber. The PortProcess
  # hot path is never blocked here — we just shrink the buffer.
  @spec enqueue_stream_event(t(), StreamEvent.t()) :: t()
  defp enqueue_stream_event(state, event) do
    if state.stream_buffer_size >= state.stream_buffer_limit do
      # Drop oldest. :queue.out/1 returns {{:value, item}, q} | {:empty, q}.
      {_dropped, smaller} = :queue.out(state.stream_buffer)
      dropped = state.stream_dropped_count + 1
      send(state.subscriber, {:kiro_stream_overflow, self(), dropped})

      %{
        state
        | stream_buffer: :queue.in(event, smaller),
          stream_dropped_count: dropped
      }
    else
      %{
        state
        | stream_buffer: :queue.in(event, state.stream_buffer),
          stream_buffer_size: state.stream_buffer_size + 1
      }
    end
  end

  # Turn discipline: a normalized :turn_end stream event is the ONLY signal
  # that flips :running / :cancel_requested → :complete.
  @spec apply_turn_end_if_present(t(), StreamEvent.t()) :: t()
  defp apply_turn_end_if_present(state, %StreamEvent{kind: :turn_end} = event)
       when state.turn_status in [:running, :cancel_requested] do
    reason = get_in(event.raw, ["update", "reason"])
    last_stop_reason = state.last_stop_reason || reason

    %{state | turn_status: :complete, last_stop_reason: last_stop_reason}
  end

  defp apply_turn_end_if_present(state, _event), do: state

  # Record the prompt RPC's stopReason without flipping turn_status. Plan2
  # §30.4 gold-memory rule: "Do not mark Kiro turns complete from
  # session/prompt response alone."
  @spec record_prompt_stop_reason(t(), term()) :: t()
  defp record_prompt_stop_reason(state, {:ok, %{"stopReason" => reason}})
       when is_binary(reason) do
    %{state | last_stop_reason: reason}
  end

  defp record_prompt_stop_reason(state, _result), do: state

  # Init-time validator: returns `{:stop, ...}` on bad input so start_link
  # surfaces a clean `{:error, reason}` rather than crashing the parent.
  @spec fetch_buffer_limit(keyword()) :: {:ok, pos_integer()} | {:stop, term()}
  defp fetch_buffer_limit(opts) do
    case Keyword.get(opts, :stream_buffer_limit, @default_stream_buffer_limit) do
      n when is_integer(n) and n > 0 ->
        {:ok, n}

      other ->
        {:stop, {:invalid_option, {:stream_buffer_limit, other}}}
    end
  end

  # Caller-time validator for `recent_stream_events/2` :limit option.
  # Invalid input is the caller's bug, not the GenServer's; we surface a
  # plain error tuple instead of crashing the runtime.
  @spec fetch_events_limit(keyword()) ::
          {:ok, non_neg_integer() | nil}
          | {:error, {:invalid_option, {:limit, term()}}}
  defp fetch_events_limit(opts) do
    case Keyword.fetch(opts, :limit) do
      :error -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      {:ok, n} when is_integer(n) and n >= 0 -> {:ok, n}
      {:ok, other} -> {:error, {:invalid_option, {:limit, other}}}
    end
  end

  @spec call_timeout(keyword()) :: timeout()
  defp call_timeout(opts) do
    case Keyword.get(opts, :timeout, @default_request_timeout) do
      :infinity -> :infinity
      timeout when is_integer(timeout) and timeout >= 0 -> timeout + 5_000
    end
  end

  @spec prompt_call_timeout(keyword()) :: timeout()
  defp prompt_call_timeout(opts) do
    case Keyword.get(opts, :timeout, @default_prompt_timeout) do
      :infinity -> :infinity
      timeout when is_integer(timeout) and timeout >= 0 -> timeout + 30_000
    end
  end

  # Reply to a pending prompt if one exists, then clean up.
  @spec reply_pending_prompt(t(), term()) :: t()
  defp reply_pending_prompt(%{pending_prompt: nil} = state, _result), do: state

  defp reply_pending_prompt(%{pending_prompt: from} = state, result) when not is_nil(from) do
    GenServer.reply(from, result)

    if state.prompt_task_ref do
      Process.demonitor(state.prompt_task_ref, [:flush])
    end

    %{state | pending_prompt: nil, prompt_task_ref: nil}
  end

  # Clean up prompt state after a successful result reply.
  @spec cleanup_prompt(t()) :: {:noreply, t()}
  defp cleanup_prompt(state) do
    if state.prompt_task_ref do
      Process.demonitor(state.prompt_task_ref, [:flush])
    end

    {:noreply, %{state | pending_prompt: nil, prompt_task_ref: nil}}
  end

  # -- Telemetry ------------------------------------------------------------

  @spec emit_prompt_telemetry(:start | :stop, String.t() | nil) :: :ok
  defp emit_prompt_telemetry(:start, session_id) do
    Telemetry.execute(
      Telemetry.event(:acp, :prompt, :start),
      %{system_time: System.system_time()},
      %{session_id: session_id}
    )
  end

  defp emit_prompt_telemetry(:stop, session_id) do
    Telemetry.execute(
      Telemetry.event(:acp, :prompt, :stop),
      %{duration: 0},
      %{session_id: session_id}
    )
  end

  # -- Best-effort EventStore persistence -----------------------------------

  # Persist the exact raw outbound JSON-RPC payload received from PortProcess
  # via {:acp_outbound, port_pid, payload}. The payload contains the true
  # assigned id, method, params, etc. — no reconstruction needed.
  #
  # This replaces the old synthetic persist_outbound/3 which reconstructed
  # payloads with a fake `"id" => 0` because PortProcess owned request ids.
  #
  # When `persist_messages: false` (test/runtime option; production default is
  # `true`), raw EventStore persistence is skipped for testing/performance.
  # Bronze ACP capture is MANDATORY and persists regardless — it is NOT gated
  # on `persist_messages`. Failures are logged but never crash the session.
  #
  # See also: `persist_bronze_acp/3` which runs unconditionally.
  #
  # §kiro-buk: Bronze ACP capture is independent of persist_messages.
  @spec persist_raw_outbound(t(), map()) :: :ok
  defp persist_raw_outbound(%{persist_messages: false} = state, payload) do
    persist_bronze_acp(state, payload, :client_to_agent)
  end

  defp persist_raw_outbound(state, payload) when is_map(payload) do
    method = Map.get(payload, "method")

    # Raw ACP row (EventStore)
    try do
      EventStore.record_acp_message("client_to_agent", payload, session_id: state.session_id)
    rescue
      e ->
        Logger.warning(fn ->
          "KiroSession failed to persist outbound ACP message" <>
            " (#{method}): #{Exception.message(e)}"
        end)
    end

    # Bronze ACP event with session/agent/plan correlation (§35 Phase 3)
    persist_bronze_acp(state, payload, :client_to_agent)

    :ok
  end

  # Inbound request: reconstruct a JSON-RPC request envelope (with id)
  # so EventStore classifies it as "request" and preserves rpc_id.
  # §kiro-buk: Bronze ACP capture is independent of persist_messages.
  @spec persist_inbound(t(), map()) :: :ok
  defp persist_inbound(%{persist_messages: false} = state, msg) do
    persist_bronze_acp(state, msg, :agent_to_client)
  end

  defp persist_inbound(state, %{id: id, method: method, params: params})
       when not is_nil(id) do
    payload = %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}

    # Raw ACP row (EventStore)
    try do
      EventStore.record_acp_message("agent_to_client", payload, session_id: state.session_id)
    rescue
      e ->
        Logger.warning(fn ->
          "KiroSession failed to persist inbound ACP request" <>
            " (#{method}, id=#{inspect(id)}): #{Exception.message(e)}"
        end)
    end

    # Bronze ACP event with session/agent/plan correlation (§35 Phase 3)
    persist_bronze_acp(state, payload, :agent_to_client)

    :ok
  end

  # Inbound notifications: reconstruct a JSON-RPC notification envelope (no id).
  defp persist_inbound(state, %{method: method, params: params}) do
    payload = %{"jsonrpc" => "2.0", "method" => method, "params" => params}

    # Raw ACP row (EventStore)
    try do
      EventStore.record_acp_message("agent_to_client", payload, session_id: state.session_id)
    rescue
      e ->
        Logger.warning(fn ->
          "KiroSession failed to persist inbound ACP notification" <>
            " (#{method}): #{Exception.message(e)}"
        end)
    end

    # Bronze ACP event with session/agent/plan correlation (§35 Phase 3)
    persist_bronze_acp(state, payload, :agent_to_client)

    :ok
  end

  defp persist_inbound(_state, _msg), do: :ok

  # Persist inbound JSON-RPC response/error from PortProcess.notify_inbound_response.
  # These are responses to KiroSession-originated requests (e.g. session/prompt
  # results). PortProcess has already resolved the pending caller via
  # resolve_pending/3; this function records the raw ACP and Bronze rows.
  # §kiro-buk: Bronze ACP capture is independent of persist_messages.
  @spec persist_inbound_response(t(), map()) :: :ok
  defp persist_inbound_response(%{persist_messages: false} = state, payload) do
    persist_bronze_acp(state, payload, :agent_to_client)
  end

  defp persist_inbound_response(state, payload) when is_map(payload) do
    # Raw ACP row (EventStore) — direction is agent_to_client for inbound responses
    try do
      EventStore.record_acp_message("agent_to_client", payload, session_id: state.session_id)
    rescue
      e ->
        Logger.warning(fn ->
          "KiroSession failed to persist inbound ACP response" <>
            " (id=#{inspect(Map.get(payload, "id"))}): #{Exception.message(e)}"
        end)
    end

    # Bronze ACP event with session/agent/plan correlation (§35 Phase 3)
    persist_bronze_acp(state, payload, :agent_to_client)

    :ok
  end

  defp persist_inbound_response(_state, _payload), do: :ok

  # -- Bronze ACP capture — MANDATORY, independent of persist_messages ------
  #
  # Per kiro-3nr / §kiro-buk, Bronze ACP capture is MANDATORY and runs
  # UNCONDITIONALLY regardless of `persist_messages`. The env flag
  # `:bronze_acp_capture_enabled` exists for test/reporting only and is
  # NOT consulted here. Raw EventStore persistence is gated by
  # `persist_messages` (see `persist_raw_outbound/2`, `persist_inbound/2`,
  # `persist_inbound_response/2`), but Bronze ACP always persists.
  #
  # Persistence failures are rescued to :ok (never crash the session) and
  # logged with full context for operational visibility.

  # Classify JSON-RPC payload shape and call the appropriate BronzeAcp
  # record function. Includes session_id, agent_id, and plan/task
  # correlation where available from KiroSession state.
  defp persist_bronze_acp(state, payload, direction) do
    do_persist_bronze_acp(state, payload, direction)
  end

  # Classify direction + message_type into Bronze ACP event kind.
  # Response and error message types both map to :response for Bronze capture.
  @spec classify_bronze_acp_event(atom(), String.t()) ::
          {:ok, :request | :response | :notification} | :unknown
  defp classify_bronze_acp_event(dir, msg_type)
       when dir in [:client_to_agent, :agent_to_client] do
    case msg_type do
      "request" -> {:ok, :request}
      mt when mt in ["response", "error"] -> {:ok, :response}
      "notification" -> {:ok, :notification}
      _ -> :unknown
    end
  end

  defp classify_bronze_acp_event(_dir, _msg_type), do: :unknown

  defp do_persist_bronze_acp(state, payload, direction) do
    session_id = state.session_id
    agent_id = state.swarm_agent_id
    plan_id = state.swarm_plan_id

    base_opts =
      [
        plan_id: plan_id,
        direction: direction
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    message_type = EventStore.classify_message_type(payload)
    method = EventStore.extract_method(payload)
    rpc_id = EventStore.normalize_rpc_id(payload)

    opts = Keyword.merge(base_opts, method: method, rpc_id: rpc_id)

    case classify_bronze_acp_event(direction, message_type) do
      {:ok, :request} ->
        DataPipeline.record_acp_request(session_id, agent_id, payload, opts)

      {:ok, :response} ->
        DataPipeline.record_acp_response(session_id, agent_id, payload, opts)

      {:ok, :notification} ->
        DataPipeline.record_acp_notification(session_id, agent_id, payload, opts)

      :unknown ->
        # "unknown" or unclassifiable — record as generic acp_update
        DataPipeline.record_acp_update(%{
          session_id: session_id,
          agent_id: agent_id,
          payload: payload,
          event_type: "acp_update",
          direction: direction
        })
    end

    :ok
  rescue
    exception ->
      # kiro-3nr: Persistence failures are rescued to :ok (never crash the
      # session) but logged with full context for operational visibility.
      # The BronzeAcp/BronzeAction modules also emit telemetry internally.
      Logger.warning(fn ->
        "KiroSession Bronze ACP persistence failed" <>
          " (session_id=#{inspect(state.session_id)}" <>
          ", agent_id=#{inspect(state.swarm_agent_id)}" <>
          ", direction=#{inspect(direction)}" <>
          "): #{Exception.message(exception)}"
      end)

      :ok
  end

  # -- Crash dump (§12.9) --------------------------------------------------

  @spec abnormal?(term()) :: boolean()
  defp abnormal?(:normal), do: false
  defp abnormal?(:shutdown), do: false
  defp abnormal?({:shutdown, _}), do: false
  defp abnormal?(_), do: true

  @spec dump_crash(term(), t()) :: :ok
  defp dump_crash(reason, state) do
    Logger.error(fn ->
      "KiroSession abnormal terminate: " <>
        inspect(
          %{
            reason: reason,
            session_id: state.session_id,
            phase: state.phase,
            turn_id: state.turn_id,
            turn_status: state.turn_status,
            last_stop_reason: state.last_stop_reason,
            pending_prompt: state.pending_prompt != nil,
            stream_sequence: state.stream_sequence,
            stream_buffer_size: state.stream_buffer_size,
            stream_dropped_count: state.stream_dropped_count,
            port_process: state.port_process
          },
          limit: :infinity,
          printable_limit: 4_096
        )
    end)

    :ok
  end
end
