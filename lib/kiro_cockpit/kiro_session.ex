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

  Streaming normalization, back-pressure, and cancellation (kiro-1rd) and
  client callback handling for `fs/*` / `terminal/*` (kiro-4ff) are
  explicitly out of scope. This module preserves and forwards raw inbound
  messages; the subscriber is responsible for responding to agent requests
  via `KiroCockpit.Acp.PortProcess.respond/3`.

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

  alias KiroCockpit.Acp.PortProcess
  alias KiroCockpit.EventStore
  alias KiroCockpit.Telemetry

  # ACP protocol defaults per kiro-acp-instructions.md
  @default_protocol_version 1
  @default_client_name "kiro-cockpit"
  @default_client_title "Kiro Cockpit"
  @default_client_version "0.1.0"
  @default_client_capabilities %{
    "fs" => %{"readTextFile" => true, "writeTextFile" => true},
    "terminal" => true
  }
  @default_executable_args ["acp"]
  @default_request_timeout 30_000
  @default_prompt_timeout 300_000

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
          protocol_version: pos_integer() | nil
        }

  # Internal state
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
            persist_messages: true

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

  Useful for `session/cancel` and other notification methods. The
  actual cancellation logic is kiro-1rd's concern; this is just plumbing.
  """
  @spec notify(GenServer.server(), String.t(), map() | list() | nil) :: :ok
  def notify(session, method, params \\ %{}) when is_binary(method) do
    GenServer.cast(session, {:notify, method, params})
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
         {:ok, subscriber} <- fetch_required(opts, :subscriber) do
      args = Keyword.get(opts, :args, @default_executable_args)

      port_opts =
        [executable: executable, args: args, owner: self()] ++ extra_port_opts(opts)

      case PortProcess.start_link(port_opts) do
        {:ok, port_pid} ->
          port_ref = Process.monitor(port_pid)
          sub_ref = Process.monitor(subscriber)

          state = %__MODULE__{
            port_process: port_pid,
            port_ref: port_ref,
            subscriber: subscriber,
            subscriber_ref: sub_ref,
            executable: executable,
            args: args,
            persist_messages: Keyword.get(opts, :persist_messages, true)
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
    client_capabilities = Keyword.get(opts, :client_capabilities, @default_client_capabilities)
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

        persist_outbound(state, "initialize", params)
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

        persist_outbound(state, "session/new", params)
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

        persist_outbound(state, "session/load", params)
        {:reply, {:ok, nil}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:load_session, _session_id, _cwd, _opts}, _from, state) do
    {:reply, {:error, {:invalid_phase, state.phase}}, state}
  end

  # -- session/prompt (async) -----------------------------------------------

  @impl GenServer
  def handle_call(
        {:prompt, prompt_or_blocks, opts},
        from,
        %{phase: :session_active, pending_prompt: nil} = state
      ) do
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

    persist_outbound(state, "session/prompt", params)

    state = %{state | pending_prompt: from, prompt_task_ref: task_ref}
    {:noreply, state}
  end

  def handle_call({:prompt, _prompt_or_blocks, _opts}, _from, %{pending_prompt: pp} = state)
      when not is_nil(pp) do
    {:reply, {:error, :prompt_in_progress}, state}
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
      protocol_version: state.protocol_version
    }

    {:reply, summary, state}
  end

  # -- respond / respond_error / notify -------------------------------------

  @impl GenServer
  def handle_call({:respond, request_id, result}, _from, %{port_process: port_pid} = state)
      when is_pid(port_pid) do
    :ok = PortProcess.respond(port_pid, request_id, result)
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
    :ok = PortProcess.respond_error(port_pid, request_id, code, message, data)
    {:reply, :ok, state}
  end

  def handle_call({:respond_error, _request_id, _code, _message, _data}, _from, state) do
    {:reply, {:error, :transport_closed}, state}
  end

  @impl GenServer
  def handle_cast({:notify, method, params}, %{port_process: port_pid} = state)
      when is_pid(port_pid) do
    :ok = PortProcess.notify(port_pid, method, params)
    {:noreply, state}
  end

  def handle_cast({:notify, _method, _params}, state) do
    {:noreply, state}
  end

  # -- Inbound message forwarding -------------------------------------------

  @impl GenServer
  def handle_info({:acp_notification, port_pid, msg}, %{port_process: port_pid} = state) do
    send(state.subscriber, {:acp_notification, self(), msg})
    persist_inbound(state, msg)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:acp_request, port_pid, msg}, %{port_process: port_pid} = state) do
    send(state.subscriber, {:acp_request, self(), msg})
    persist_inbound(state, msg)
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
  def terminate(_reason, state) do
    state = reply_pending_prompt(state, {:error, :session_terminated})

    if is_pid(state.port_process) and Process.alive?(state.port_process) do
      PortProcess.stop(state.port_process, :normal, 2_000)
    end

    :ok
  end

  # -- Internals ------------------------------------------------------------

  @spec fetch_required(keyword(), atom()) :: {:ok, term()} | {:stop, term()}
  defp fetch_required(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:stop, {:invalid_option, key}}
    end
  end

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

  # Outbound: reconstruct a JSON-RPC request envelope for the raw_payload
  # so EventStore classification works correctly. The id is a placeholder
  # since we don't know what PortProcess assigned internally.
  @spec persist_outbound(t(), String.t(), map()) :: :ok
  defp persist_outbound(%{persist_messages: false}, _method, _params), do: :ok

  defp persist_outbound(state, method, params) do
    payload = %{"jsonrpc" => "2.0", "id" => 0, "method" => method, "params" => params}

    try do
      EventStore.record_acp_message("client_to_agent", payload, session_id: state.session_id)
    rescue
      e ->
        Logger.warning(fn ->
          "KiroSession failed to persist outbound ACP message" <>
            " (#{method}): #{Exception.message(e)}"
        end)
    end

    :ok
  end

  # Inbound request: reconstruct a JSON-RPC request envelope (with id)
  # so EventStore classifies it as "request" and preserves rpc_id.
  @spec persist_inbound(t(), map()) :: :ok
  defp persist_inbound(%{persist_messages: false}, _msg), do: :ok

  defp persist_inbound(state, %{id: id, method: method, params: params})
       when not is_nil(id) do
    payload = %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}

    try do
      EventStore.record_acp_message("agent_to_client", payload, session_id: state.session_id)
    rescue
      e ->
        Logger.warning(fn ->
          "KiroSession failed to persist inbound ACP request" <>
            " (#{method}, id=#{inspect(id)}): #{Exception.message(e)}"
        end)
    end

    :ok
  end

  # Inbound notifications: reconstruct a JSON-RPC notification envelope (no id).
  defp persist_inbound(state, %{method: method, params: params}) do
    payload = %{"jsonrpc" => "2.0", "method" => method, "params" => params}

    try do
      EventStore.record_acp_message("agent_to_client", payload, session_id: state.session_id)
    rescue
      e ->
        Logger.warning(fn ->
          "KiroSession failed to persist inbound ACP notification" <>
            " (#{method}): #{Exception.message(e)}"
        end)
    end

    :ok
  end

  defp persist_inbound(_state, _msg), do: :ok
end
