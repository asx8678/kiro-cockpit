defmodule KiroCockpit.Acp.PortProcess do
  @moduledoc """
  GenServer wrapping an external ACP agent over stdio via an Erlang Port.

  This is the **transport boundary**. It speaks JSON-RPC 2.0 over newline-
  delimited stdio (ACP §13). It owns nothing about ACP lifecycle semantics
  (`initialize`, `session/new`, etc.) — that lives one layer up.

  ## Process model

      ┌────────────────────────────────────────────┐
      │ Caller / Owner pid                         │
      │                                            │
      │  call request/4 ──▶┐                       │
      │  cast notify/3 ───▶│                       │
      │  cast respond/3 ──▶│                       │
      └────────────────────┼───────────────────────┘
                           │ GenServer.call/cast
                           ▼
      ┌────────────────────────────────────────────┐
      │ KiroCockpit.Acp.PortProcess (GenServer)    │
      │ - owns the Port                            │
      │ - serializes writes (single owner)         │
      │ - correlates responses by id               │
      │ - timer per pending request                │
      │ - traps exits for graceful terminate/2     │
      │ - monitors `owner` pid                     │
      └────────────────────┬───────────────────────┘
                           │ Port.command / port msgs
                           ▼
      ┌────────────────────────────────────────────┐
      │ Erlang Port  ({:line, max})                │
      └────────────────────┬───────────────────────┘
                           │ stdin/stdout pipes
                           ▼
      ┌────────────────────────────────────────────┐
      │ External agent process (e.g. kiro-cli acp) │
      └────────────────────────────────────────────┘

  ## Owner-bound message protocol

  When the agent initiates traffic, the GenServer forwards structured tuples
  to the configured `:owner` pid. The owner replies — when applicable —
  via `respond/3` or `respond_error/3`.

      {:acp_request, port_pid, %{id: id, method: method, params: params}}
      {:acp_notification, port_pid, %{method: method, params: params}}
      {:acp_protocol_error, port_pid, reason, raw}
      {:acp_exit, port_pid, status}

  ## Restart strategy guidance (for callers)

  This module only provides `start_link/1`. When you mount it under a
  supervisor:

    * `restart: :transient` is the right default — we want restarts on
      abnormal exit (the agent died, the port driver hiccupped) but NOT on a
      clean `:normal` shutdown initiated by the session above.
    * `restart: :temporary` is correct if a higher layer is responsible for
      detecting the death and explicitly re-spawning (per-turn workers, etc.).
    * `restart: :permanent` is almost certainly wrong — agents don't have
      "must always be alive for the node to function" semantics.

  Strategy on the parent supervisor: `one_for_one`. Each port is independent;
  losing one doesn't taint its siblings. If you find yourself reaching for
  `one_for_all` here, you've coupled things you shouldn't have.
  """

  use GenServer

  require Logger

  alias KiroCockpit.Acp.{JsonRpc, LineCodec}

  @default_max_line_bytes 4 * 1024 * 1024
  @default_request_timeout 5_000

  # -- Types ----------------------------------------------------------------

  @typedoc "Options accepted by `start_link/1`."
  @type start_opt ::
          {:executable, Path.t()}
          | {:args, [String.t()]}
          | {:owner, pid()}
          | {:cd, Path.t()}
          | {:env, [{String.t() | charlist(), String.t() | charlist()}]}
          | {:max_line_bytes, pos_integer()}
          | {:name, GenServer.name()}

  @typedoc false
  @type state :: %{
          port: port() | nil,
          owner: pid(),
          owner_ref: reference(),
          executable: Path.t(),
          args: [String.t()],
          max_line_bytes: pos_integer(),
          pending: %{optional(integer()) => {GenServer.from(), reference()}},
          next_id: integer(),
          overflow: boolean(),
          closed: boolean()
        }

  # -- Public API -----------------------------------------------------------

  @doc """
  Start the transport.

  ## Options

    * `:executable` (required) — absolute path to the executable.
    * `:args` — argv list (default `[]`).
    * `:owner` — pid that receives agent-initiated requests/notifications and
      port lifecycle events. Defaults to the calling process.
    * `:cd` — working directory for the child.
    * `:env` — environment variables (`[{name, value} | ...]`).
    * `:max_line_bytes` — line length limit (default 4 MiB).
    * `:name` — GenServer registration name.

  ## Owner default

  The owner pid is captured **here**, in the caller's process, via
  `Keyword.put_new/3`. If we deferred the default to `init/1`, `self()` would
  resolve to the GenServer itself — which is precisely the foot-gun this guard
  exists to prevent.
  """
  @spec start_link([start_opt()]) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    opts = Keyword.put_new(opts, :owner, self())
    {gen_opts, server_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, server_opts, gen_opts)
  end

  @doc """
  Send a JSON-RPC request and wait for the response.

  Returns `{:ok, result}` on success, `{:error, reason}` on failure.

  Reasons:
    * `:timeout` — no response within `timeout` ms
    * `:transport_closed` — the GenServer is shutting down
    * `{:port_exited, status}` — the agent exited before responding
    * `{:rpc_error, %{code, message, data?}}` — agent returned a JSON-RPC error

  `timeout` accepts a non-negative integer (milliseconds) or `:infinity`. When
  `:infinity` is given, no per-request timer is armed and the call only
  resolves when the agent replies, the port exits, or the GenServer stops.
  """
  @spec request(GenServer.server(), String.t(), map() | list() | nil, timeout()) ::
          {:ok, term()} | {:error, term()}
  def request(server, method, params \\ %{}, timeout \\ @default_request_timeout)
      when is_binary(method) and (timeout == :infinity or (is_integer(timeout) and timeout >= 0)) do
    GenServer.call(server, {:request, method, params, timeout}, call_timeout(timeout))
  end

  @doc """
  Fire-and-forget JSON-RPC notification (no id, no response).
  """
  @spec notify(GenServer.server(), String.t(), map() | list() | nil) :: :ok
  def notify(server, method, params \\ %{}) when is_binary(method) do
    GenServer.cast(server, {:notify, method, params})
  end

  @doc """
  Reply to an inbound agent→client request with a success result.

  The `request_id` MUST be the id from the original `{:acp_request, _, %{id: id, ...}}`
  message. The id is preserved exactly (integer or string).
  """
  @spec respond(GenServer.server(), JsonRpc.id(), term()) :: :ok
  def respond(server, request_id, result)
      when is_integer(request_id) or is_binary(request_id) do
    GenServer.cast(server, {:respond, request_id, result})
  end

  @doc """
  Reply to an inbound agent→client request with a JSON-RPC error.
  """
  @spec respond_error(GenServer.server(), JsonRpc.id(), integer(), String.t(), term() | nil) ::
          :ok
  def respond_error(server, request_id, code, message, data \\ nil)
      when (is_integer(request_id) or is_binary(request_id)) and is_integer(code) and
             is_binary(message) do
    GenServer.cast(server, {:respond_error, request_id, code, message, data})
  end

  @doc """
  Stop the transport gracefully.
  """
  @spec stop(GenServer.server(), term(), timeout()) :: :ok
  def stop(server, reason \\ :normal, timeout \\ 5_000) do
    GenServer.stop(server, reason, timeout)
  end

  # -- GenServer callbacks --------------------------------------------------

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    with {:ok, executable} <- fetch_executable(opts),
         {:ok, owner} <- fetch_owner(opts),
         args <- Keyword.get(opts, :args, []),
         max_line_bytes <-
           Keyword.get(opts, :max_line_bytes, @default_max_line_bytes),
         port_opts <- build_port_opts(args, max_line_bytes, opts),
         {:ok, port} <- safe_open_port(executable, port_opts) do
      ref = Process.monitor(owner)

      state = %{
        port: port,
        owner: owner,
        owner_ref: ref,
        executable: executable,
        args: args,
        max_line_bytes: max_line_bytes,
        pending: %{},
        next_id: 1,
        overflow: false,
        closed: false
      }

      {:ok, state}
    end
  end

  @impl GenServer
  def handle_call({:request, method, params, timeout}, from, %{closed: false} = state) do
    id = state.next_id
    msg = JsonRpc.request(id, method, params)

    case write_line(state, msg) do
      :ok ->
        timer_ref = arm_request_timer(id, timeout)
        pending = Map.put(state.pending, id, {from, timer_ref})
        {:noreply, %{state | next_id: id + 1, pending: pending}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:request, _method, _params, _timeout}, _from, %{closed: true} = state) do
    {:reply, {:error, :transport_closed}, state}
  end

  @impl GenServer
  def handle_cast({:notify, method, params}, state) do
    msg = JsonRpc.notification(method, params)
    _ = write_line(state, msg)
    {:noreply, state}
  end

  def handle_cast({:respond, id, result}, state) do
    msg = JsonRpc.success_response(id, result)
    _ = write_line(state, msg)
    {:noreply, state}
  end

  def handle_cast({:respond_error, id, code, message, data}, state) do
    msg = JsonRpc.error_response(id, code, message, data)
    _ = write_line(state, msg)
    {:noreply, state}
  end

  # -- Port messages --------------------------------------------------------

  @impl GenServer
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state)
      when is_port(port) do
    state =
      if state.overflow do
        # discard the tail of the oversized line; resync on next eol
        %{state | overflow: false}
      else
        handle_line(line, state)
      end

    {:noreply, state}
  end

  def handle_info({port, {:data, {:noeol, _chunk}}}, %{port: port} = state)
      when is_port(port) do
    unless state.overflow do
      send(state.owner, {:acp_protocol_error, self(), :line_too_long, nil})
    end

    {:noreply, %{state | overflow: true}}
  end

  # Clean exit (status 0): stop :normal so a transient supervisor doesn't
  # restart us. The session above asked the agent to exit; honor that.
  def handle_info({port, {:exit_status, 0}}, %{port: port} = state) when is_port(port) do
    send(state.owner, {:acp_exit, self(), 0})
    state = fail_all_pending(state, {:port_exited, 0})
    {:stop, :normal, %{state | port: nil, closed: true}}
  end

  # Non-zero exit: surface as an abnormal stop so a `:transient` supervisor
  # restarts us. Stopping `:normal` here would silently swallow agent crashes.
  def handle_info({port, {:exit_status, status}}, %{port: port} = state)
      when is_port(port) and is_integer(status) do
    send(state.owner, {:acp_exit, self(), status})
    state = fail_all_pending(state, {:port_exited, status})
    {:stop, {:port_exited, status}, %{state | port: nil, closed: true}}
  end

  # Trapped exit from the port itself (rare — usually exit_status arrives first).
  # `:normal` from the port driver maps to a normal GenServer stop; anything
  # else is abnormal and propagates upward as `{:port_exited, reason}`.
  def handle_info({:EXIT, port, :normal}, %{port: port} = state) when is_port(port) do
    send(state.owner, {:acp_exit, self(), :normal})
    state = fail_all_pending(state, {:port_exited, :normal})
    {:stop, :normal, %{state | port: nil, closed: true}}
  end

  def handle_info({:EXIT, port, reason}, %{port: port} = state) when is_port(port) do
    send(state.owner, {:acp_exit, self(), reason})
    state = fail_all_pending(state, {:port_exited, reason})
    {:stop, {:port_exited, reason}, %{state | port: nil, closed: true}}
  end

  # -- Per-request timeout --------------------------------------------------

  def handle_info({:request_timeout, id}, state) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        {:noreply, state}

      {{from, _timer_ref}, pending} ->
        # Timer fired ⇒ no need to cancel it.
        GenServer.reply(from, {:error, :timeout})
        {:noreply, %{state | pending: pending}}
    end
  end

  # -- Owner DOWN -----------------------------------------------------------

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state) do
    {:stop, :normal, state}
  end

  # Other monitors / stray messages — log and continue.
  def handle_info(msg, state) do
    Logger.debug(fn -> "#{inspect(__MODULE__)} ignoring: #{inspect(msg)}" end)
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    state = fail_all_pending(state, :transport_closed)

    if is_port(state.port) and not state.closed do
      try do
        Port.close(state.port)
      rescue
        ArgumentError -> :ok
      catch
        :error, :badarg -> :ok
      end
    end

    :ok
  end

  # -- Internals ------------------------------------------------------------

  @spec fetch_executable(keyword()) :: {:ok, Path.t()} | {:stop, {:invalid_option, term()}}
  defp fetch_executable(opts) do
    case Keyword.fetch(opts, :executable) do
      {:ok, path} when is_binary(path) and byte_size(path) > 0 -> {:ok, path}
      _ -> {:stop, {:invalid_option, :executable}}
    end
  end

  @spec build_port_opts([String.t()], pos_integer(), keyword()) :: list()
  defp build_port_opts(args, max_line_bytes, opts) do
    base = [
      :binary,
      :exit_status,
      :use_stdio,
      :hide,
      {:line, max_line_bytes},
      {:args, args}
    ]

    base
    |> maybe_put_opt(:cd, Keyword.get(opts, :cd))
    |> maybe_put_opt(:env, build_env(Keyword.get(opts, :env)))
  end

  @spec maybe_put_opt(list(), atom(), term() | nil) :: list()
  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: opts ++ [{key, value}]

  @spec build_env(nil | [{any(), any()}]) :: nil | [{charlist(), charlist()}]
  defp build_env(nil), do: nil

  defp build_env(env) when is_list(env) do
    Enum.map(env, fn {k, v} -> {to_charlist(to_string(k)), to_charlist(to_string(v))} end)
  end

  @spec safe_open_port(Path.t(), list()) ::
          {:ok, port()} | {:stop, {:port_open_failed, term()}}
  defp safe_open_port(executable, port_opts) do
    port = Port.open({:spawn_executable, executable}, port_opts)
    {:ok, port}
  rescue
    e -> {:stop, {:port_open_failed, Exception.message(e)}}
  end

  @spec write_line(state(), map()) :: :ok | {:error, term()}
  defp write_line(%{port: port} = _state, msg) when is_port(port) do
    case LineCodec.encode(msg) do
      {:ok, line} ->
        try do
          true = Port.command(port, line)
          :ok
        rescue
          ArgumentError -> {:error, :transport_closed}
        catch
          :error, :badarg -> {:error, :transport_closed}
        end

      {:error, reason} ->
        {:error, {:encode_failed, reason}}
    end
  end

  defp write_line(_state, _msg), do: {:error, :transport_closed}

  @spec handle_line(binary(), state()) :: state()
  defp handle_line(line, state) do
    case LineCodec.decode(line) do
      {:ok, decoded} ->
        dispatch_decoded(decoded, state)

      {:error, :blank} ->
        state

      {:error, reason} ->
        Logger.warning(fn ->
          "#{inspect(__MODULE__)} dropping malformed line: #{inspect(reason)}"
        end)

        send(state.owner, {:acp_protocol_error, self(), reason, line})
        state
    end
  end

  @spec dispatch_decoded(term(), state()) :: state()
  defp dispatch_decoded(msg, state) do
    case JsonRpc.classify(msg) do
      {:request, id, method, params} ->
        send(state.owner, {:acp_request, self(), %{id: id, method: method, params: params}})
        state

      {:notification, method, params} ->
        send(state.owner, {:acp_notification, self(), %{method: method, params: params}})
        state

      {:response, id, outcome} ->
        resolve_pending(id, outcome, state)

      {:invalid, reason, raw} ->
        Logger.warning(fn ->
          "#{inspect(__MODULE__)} unrecognized JSON-RPC shape: #{inspect(reason)}"
        end)

        send(state.owner, {:acp_protocol_error, self(), reason, raw})
        state
    end
  end

  @spec resolve_pending(JsonRpc.id(), {:ok, term()} | {:error, JsonRpc.error_object()}, state()) ::
          state()
  defp resolve_pending(id, outcome, state) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        Logger.debug(fn ->
          "#{inspect(__MODULE__)} response for unknown id=#{inspect(id)}; ignoring"
        end)

        state

      {{from, timer_ref}, pending} ->
        cancel_timer(timer_ref)
        reply = format_response(outcome)
        GenServer.reply(from, reply)
        %{state | pending: pending}
    end
  end

  defp format_response({:ok, result}), do: {:ok, result}
  defp format_response({:error, err}), do: {:error, {:rpc_error, err}}

  @spec fail_all_pending(state(), term()) :: state()
  defp fail_all_pending(state, reason) do
    Enum.each(state.pending, fn {_id, {from, timer_ref}} ->
      cancel_timer(timer_ref)
      GenServer.reply(from, {:error, reason})
    end)

    %{state | pending: %{}}
  end

  # Pending entries created with `:infinity` carry a nil timer ref. Treat that
  # as a no-op rather than letting `Process.cancel_timer/2` pattern-match crash.
  @spec cancel_timer(reference() | nil) :: :ok
  defp cancel_timer(nil), do: :ok

  defp cancel_timer(ref) when is_reference(ref) do
    _ = Process.cancel_timer(ref, async: true, info: false)
    :ok
  end

  # `Process.send_after/3` rejects `:infinity`. We support :infinity by simply
  # not arming a timer — the call resolves only on response, port exit, or
  # GenServer stop. The `nil` ref is handled by `cancel_timer/1`.
  @spec arm_request_timer(integer(), timeout()) :: reference() | nil
  defp arm_request_timer(_id, :infinity), do: nil

  defp arm_request_timer(id, timeout) when is_integer(timeout) and timeout >= 0 do
    Process.send_after(self(), {:request_timeout, id}, timeout)
  end

  # Owner is captured in `start_link/1` from the caller's process. If somebody
  # bypasses `start_link/1` and calls `init/1` directly without supplying an
  # owner, fail loudly rather than letting `self()` silently make the GenServer
  # its own owner.
  @spec fetch_owner(keyword()) :: {:ok, pid()} | {:stop, {:invalid_option, :owner}}
  defp fetch_owner(opts) do
    case Keyword.fetch(opts, :owner) do
      {:ok, pid} when is_pid(pid) -> {:ok, pid}
      _ -> {:stop, {:invalid_option, :owner}}
    end
  end

  # Add a small buffer so the GenServer always has a chance to reply with
  # `{:error, :timeout}` BEFORE the outer GenServer.call exits the caller.
  @spec call_timeout(timeout()) :: timeout()
  defp call_timeout(:infinity), do: :infinity
  defp call_timeout(timeout) when is_integer(timeout) and timeout >= 0, do: timeout + 1_000
end
