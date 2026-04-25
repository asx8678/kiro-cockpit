defmodule KiroCockpit.KiroSession.TerminalManager do
  @moduledoc """
  Manages terminal subprocess lifecycle for ACP `terminal/*` callbacks.

  Each terminal is an OS process spawned via an Erlang Port. The TerminalManager
  owns these ports, buffers their combined stdout+stderr output (with a
  configurable byte limit), tracks exit status, and provides the full terminal
  lifecycle per kiro-acp-instructions.md §9:

    * `create/6`  — start a command, return terminal ID immediately
    * `output/2`  — non-blocking snapshot of buffered output + exit status
    * `wait_for_exit/3` — block until the process exits (bounded timeout)
    * `kill/2`    — send SIGKILL if still running, return nil
    * `release/2` — kill if running, free resources, return nil

  Terminal IDs are stable strings (`"term_000001"`, etc.) suitable for embedding
  in `tool_call_update` messages.

  ## Design notes

    * Each terminal's stdout/stderr is captured via its owning Port and buffered
      in memory. A byte limit (default 1 MiB, overridable per-create via
      `outputByteLimit`) prevents unbounded growth.
    * `wait_for_exit/3` uses a deferred-reply pattern: if the process hasn't
      exited yet, the GenServer stores the caller's `from` and replies when
      the port's exit status arrives (or on timeout).
    * On `terminate/2`, all running terminals are killed and their ports closed.

  ## Stage-1 constraints

  No DynamicSupervisor or per-terminal GenServer. All terminals live in a
  single GenServer's state. This is simple, deterministic, and sufficient for
  the current ACP use case.
  """

  use GenServer

  require Logger

  @default_output_byte_limit 1_048_576
  @default_wait_timeout 30_000

  # -- Types ------------------------------------------------------------------

  @typedoc "Terminal ID — a stable string like `\"term_000001\"`."
  @type terminal_id :: String.t()

  @typedoc """
  Terminal process state tracked by the manager.

  * `:port`          — the Erlang port owning the OS process
  * `:os_pid`        — OS-level PID captured at creation time
  * `:buffer`        — accumulated stdout/stderr as a binary
  * `:output_byte_limit` — byte limit for the buffer
  * `:truncated`     — whether output was truncated at the byte limit
  * `:exit_status`   — `nil` while running, integer exit code when exited
  * `:waiter`        — deferred `GenServer.from` for `wait_for_exit`
  * `:wait_timer`    — timer reference for the wait timeout
  """
  @type terminal :: %{
          port: port() | nil,
          os_pid: integer() | nil,
          buffer: binary(),
          output_byte_limit: pos_integer(),
          truncated: boolean(),
          exit_status: integer() | nil,
          waiter: GenServer.from() | nil,
          wait_timer: reference() | nil
        }

  defstruct terminals: %{},
            next_id: 1

  @type t :: %__MODULE__{
          terminals: %{optional(terminal_id()) => terminal()},
          next_id: pos_integer()
        }

  # -- Public API -------------------------------------------------------------

  @doc """
  Start the TerminalManager linked to the calling process.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Start a terminal subprocess and return its ID immediately.

  ## Parameters

    * `command` — the executable name or absolute path
    * `args` — list of string arguments (default `[]`)
    * `cwd` — absolute working directory, or `nil` to inherit
    * `env` — list of `%{"name" => ..., "value" => ...}` maps to merge
    * `output_byte_limit` — max bytes to buffer (default 1 MiB)

  Returns `{:ok, terminal_id}` or `{:error, code, message, data}`.
  """
  @spec create(
          GenServer.server(),
          String.t(),
          [String.t()],
          String.t() | nil,
          [map()],
          pos_integer()
        ) ::
          {:ok, terminal_id()} | {:error, integer(), String.t(), term()}
  def create(
        server,
        command,
        args \\ [],
        cwd \\ nil,
        env \\ [],
        output_byte_limit \\ @default_output_byte_limit
      ) do
    GenServer.call(server, {:create, command, args, cwd, env, output_byte_limit}, 5_000)
  end

  @doc """
  Return a non-blocking snapshot of the terminal's buffered output.

  Returns `{:ok, %{"output" => binary, "truncated" => boolean, "exitStatus" => map | nil}}`
  or `{:error, code, message, data}` if the terminal ID is unknown.
  """
  @spec output(GenServer.server(), terminal_id()) ::
          {:ok, map()} | {:error, integer(), String.t(), term()}
  def output(server, terminal_id) do
    GenServer.call(server, {:output, terminal_id}, 5_000)
  end

  @doc """
  Wait for the terminal process to exit, with a bounded timeout.

  Returns `{:ok, %{"exitCode" => integer, "signal" => integer | nil}}`
  or `{:error, code, message, data}` on timeout / unknown terminal.

  Uses a deferred-reply pattern so the GenServer stays responsive while waiting.
  """
  @spec wait_for_exit(GenServer.server(), terminal_id(), timeout()) ::
          {:ok, map()} | {:error, integer(), String.t(), term()}
  def wait_for_exit(server, terminal_id, timeout \\ @default_wait_timeout) do
    # Add buffer to the GenServer.call timeout so it's always >= the wait timeout.
    call_timeout = if timeout == :infinity, do: :infinity, else: timeout + 5_000
    GenServer.call(server, {:wait_for_exit, terminal_id, timeout}, call_timeout)
  end

  @doc """
  Send SIGKILL to the terminal process if it is still running.

  Returns `{:ok, nil}` always (per ACP spec, kill returns null on success).
  If the terminal is already dead, this is a no-op.
  If the terminal ID is unknown, returns an error.
  """
  @spec kill(GenServer.server(), terminal_id()) ::
          {:ok, nil} | {:error, integer(), String.t(), term()}
  def kill(server, terminal_id) do
    GenServer.call(server, {:kill, terminal_id}, 5_000)
  end

  @doc """
  Kill the terminal if still running, close its port, and free the terminal ID.

  Returns `{:ok, nil}` always (per ACP spec, release returns null).
  If the terminal ID is unknown, returns an error.
  """
  @spec release(GenServer.server(), terminal_id()) ::
          {:ok, nil} | {:error, integer(), String.t(), term()}
  def release(server, terminal_id) do
    GenServer.call(server, {:release, terminal_id}, 5_000)
  end

  @doc """
  Stop the TerminalManager gracefully.
  """
  @spec stop(GenServer.server()) :: :ok
  def stop(server) do
    GenServer.stop(server, :normal, 5_000)
  end

  # -- GenServer callbacks ----------------------------------------------------

  @impl GenServer
  def init(_opts) do
    Process.flag(:trap_exit, true)
    {:ok, %__MODULE__{}}
  end

  @impl GenServer
  def handle_call({:create, command, args, cwd, env, output_byte_limit}, _from, state) do
    with {:ok, resolved_cmd} <- resolve_command(command),
         {:ok, port_opts} <- build_port_opts(args, cwd, env),
         {:ok, port} <- safe_open_port(resolved_cmd, port_opts) do
      os_pid = get_os_pid(port)
      term_id = generate_id(state.next_id)

      terminal = %{
        port: port,
        os_pid: os_pid,
        buffer: <<>>,
        output_byte_limit: output_byte_limit,
        truncated: false,
        exit_status: nil,
        waiter: nil,
        wait_timer: nil
      }

      state = %{
        state
        | terminals: Map.put(state.terminals, term_id, terminal),
          next_id: state.next_id + 1
      }

      {:reply, {:ok, term_id}, state}
    else
      {:error, code, message, data} ->
        {:reply, {:error, code, message, data}, state}
    end
  end

  def handle_call({:output, terminal_id}, _from, state) do
    case Map.fetch(state.terminals, terminal_id) do
      {:ok, terminal} ->
        exit_status = format_exit_status(terminal)

        # Ports deliver arbitrary bytes; JSON-RPC responses must be valid
        # UTF-8 for Jason encoding. In particular, outputByteLimit can cut a
        # multi-byte codepoint in half. Sanitize at response time while keeping
        # the raw bounded buffer internally.
        output = ensure_valid_utf8(terminal.buffer)
        result = %{"output" => output, "truncated" => terminal.truncated}

        result =
          if exit_status != nil do
            Map.put(result, "exitStatus", exit_status)
          else
            result
          end

        {:reply, {:ok, result}, state}

      :error ->
        {:reply, {:error, -32_000, "Unknown terminal: #{terminal_id}", nil}, state}
    end
  end

  def handle_call({:wait_for_exit, terminal_id, timeout}, from, state) do
    case Map.fetch(state.terminals, terminal_id) do
      {:ok, %{exit_status: exit_status} = _terminal} when is_integer(exit_status) ->
        # Already exited — reply immediately.
        result = format_exit_info(exit_status)
        {:reply, {:ok, result}, state}

      {:ok, %{waiter: existing_waiter} = _terminal} when existing_waiter != nil ->
        # A waiter already exists — reject to avoid overwriting and hanging the first caller.
        {:reply,
         {:error, -32_000, "A wait_for_exit call is already pending for this terminal", nil},
         state}

      {:ok, terminal} ->
        # Still running — defer reply until exit_status arrives or timeout.
        wait_timer =
          if timeout != :infinity do
            Process.send_after(self(), {:wait_timeout, terminal_id}, timeout)
          end

        terminal = %{terminal | waiter: from, wait_timer: wait_timer}
        state = %{state | terminals: Map.put(state.terminals, terminal_id, terminal)}
        {:noreply, state}

      :error ->
        {:reply, {:error, -32_000, "Unknown terminal: #{terminal_id}", nil}, state}
    end
  end

  def handle_call({:kill, terminal_id}, _from, state) do
    case Map.fetch(state.terminals, terminal_id) do
      {:ok, terminal} ->
        if terminal.exit_status == nil do
          send_sigkill(terminal)
        end

        {:reply, {:ok, nil}, state}

      :error ->
        {:reply, {:error, -32_000, "Unknown terminal: #{terminal_id}", nil}, state}
    end
  end

  def handle_call({:release, terminal_id}, _from, state) do
    case Map.pop(state.terminals, terminal_id) do
      {nil, _remaining} ->
        {:reply, {:error, -32_000, "Unknown terminal: #{terminal_id}", nil}, state}

      {terminal, remaining_terminals} ->
        # Kill if still running
        if terminal.exit_status == nil do
          send_sigkill(terminal)
        end

        # Close the port if still open
        if terminal.port != nil do
          safe_close_port(terminal.port)
        end

        # Reply to any pending waiter with an error (terminal released)
        # The terminal is already removed from state (popped), so we
        # reply directly without updating state.
        if terminal.waiter != nil do
          cancel_wait_timer(terminal)
          GenServer.reply(terminal.waiter, {:error, -32_000, "Terminal released", nil})
        end

        state = %{state | terminals: remaining_terminals}
        {:reply, {:ok, nil}, state}
    end
  end

  # -- Port messages ----------------------------------------------------------

  @impl GenServer
  def handle_info({port, {:data, data}}, state) when is_port(port) do
    case find_terminal_by_port(state, port) do
      {term_id, terminal} ->
        {buffer, truncated} = append_to_buffer(terminal.buffer, data, terminal.output_byte_limit)
        terminal = %{terminal | buffer: buffer, truncated: truncated || terminal.truncated}
        state = %{state | terminals: Map.put(state.terminals, term_id, terminal)}
        {:noreply, state}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({port, {:exit_status, status}}, state) when is_port(port) do
    case find_terminal_by_port(state, port) do
      {term_id, terminal} ->
        terminal = %{terminal | exit_status: status}
        state = %{state | terminals: Map.put(state.terminals, term_id, terminal)}

        # Reply to any pending waiter
        state =
          if terminal.waiter != nil do
            cancel_wait_timer(terminal)
            result = format_exit_info(status)
            GenServer.reply(terminal.waiter, {:ok, result})
            terminal = %{terminal | waiter: nil, wait_timer: nil}
            %{state | terminals: Map.put(state.terminals, term_id, terminal)}
          else
            state
          end

        {:noreply, state}

      nil ->
        {:noreply, state}
    end
  end

  # Trapped EXIT from a port — may arrive after exit_status.
  def handle_info({:EXIT, port, _reason}, state) when is_port(port) do
    # Already handled via exit_status; just ignore the EXIT signal.
    {:noreply, state}
  end

  # Wait timeout — the process didn't exit in time.
  def handle_info({:wait_timeout, terminal_id}, state) do
    case Map.fetch(state.terminals, terminal_id) do
      {:ok, %{waiter: waiter} = terminal} when waiter != nil ->
        GenServer.reply(waiter, {:error, -32_000, "Wait for exit timed out", nil})
        terminal = %{terminal | waiter: nil, wait_timer: nil}
        state = %{state | terminals: Map.put(state.terminals, terminal_id, terminal)}
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  # Ignore unknown messages.
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    # Kill all running terminals and close their ports.
    terminals = Map.get(state, :terminals, %{})

    Enum.each(terminals, fn {_term_id, terminal} ->
      if terminal.exit_status == nil do
        send_sigkill(terminal)
      end

      if terminal.port != nil do
        safe_close_port(terminal.port)
      end
    end)

    :ok
  end

  # -- Internals --------------------------------------------------------------

  @spec resolve_command(String.t()) :: {:ok, String.t()} | {:error, integer(), String.t(), nil}
  defp resolve_command(command) when is_binary(command) do
    if Path.type(command) == :absolute do
      if File.exists?(command) do
        {:ok, command}
      else
        {:error, -32_000, "Command not found: #{command}", nil}
      end
    else
      case System.find_executable(command) do
        nil -> {:error, -32_000, "Command not found: #{command}", nil}
        path -> {:ok, path}
      end
    end
  end

  @spec build_port_opts([String.t()], String.t() | nil, [map()]) ::
          {:ok, list()} | {:error, integer(), String.t(), nil}
  defp build_port_opts(args, cwd, env) do
    with :ok <- validate_cwd(cwd) do
      base = [
        :binary,
        :exit_status,
        :use_stdio,
        :hide,
        :stderr_to_stdout,
        {:args, args || []}
      ]

      opts =
        base
        |> maybe_put_opt(:cd, cwd && String.to_charlist(cwd))
        |> maybe_put_opt(:env, build_env_list(env))

      {:ok, opts}
    end
  end

  @spec validate_cwd(String.t() | nil) :: :ok | {:error, integer(), String.t(), nil}
  defp validate_cwd(nil), do: :ok

  defp validate_cwd(cwd) when is_binary(cwd) do
    if Path.type(cwd) == :absolute do
      :ok
    else
      {:error, -32_602, "cwd must be an absolute path: #{cwd}", nil}
    end
  end

  @spec build_env_list([map()]) :: list()
  defp build_env_list([]), do: build_isolated_env()

  defp build_env_list(env) when is_list(env) do
    base_env = build_isolated_env()

    overrides =
      Enum.map(env, fn entry ->
        name = Map.get(entry, "name") || Map.get(entry, :name, "")
        value = Map.get(entry, "value") || Map.get(entry, :value, "")
        {String.to_charlist(to_string(name)), String.to_charlist(to_string(value))}
      end)

    # Overrides replace existing entries; new entries are appended.
    # Build a map for deduplication, then convert back to list.
    merged =
      Enum.reduce(overrides, Map.new(base_env), fn {k, v}, acc ->
        Map.put(acc, k, v)
      end)

    Map.to_list(merged)
  end

  # Build an isolated environment for the subprocess:
  # - Allowlisted host env vars are inherited with their values
  # - All other host env vars are explicitly unset (set to `false`)
  #   because Erlang's Port :env option MERGES with the parent env,
  #   not replaces it. Without explicit unset, non-allowlisted vars
  #   like DATABASE_URL or API keys would leak into the subprocess.
  #
  # See Erlang docs: "If Name is set as the atom false, the environment
  # variable is removed."
  @host_env_allowlist ~w(PATH TMPDIR TMP TEMP LANG HOME USER SHELL TERM LC_ALL LC_CTYPE LC_MESSAGES LC_TIME LC_COLLATE LC_NUMERIC LC_MONETARY)

  @spec build_isolated_env() :: [{charlist(), charlist() | false}]
  defp build_isolated_env do
    # 1. Collect allowlisted vars with their values
    allowed =
      @host_env_allowlist
      |> Enum.filter(fn name -> System.get_env(name) != nil end)
      |> Enum.map(fn name ->
        {String.to_charlist(name), String.to_charlist(System.get_env(name))}
      end)

    allowed_names = MapSet.new(@host_env_allowlist)

    # 2. Explicitly unset all non-allowlisted host vars to prevent leakage
    unset =
      System.get_env()
      |> Enum.filter(fn {k, _v} -> k not in allowed_names end)
      |> Enum.map(fn {k, _v} -> {String.to_charlist(k), false} end)

    allowed ++ unset
  end

  @spec safe_open_port(String.t(), list()) ::
          {:ok, port()} | {:error, integer(), String.t(), nil}
  defp safe_open_port(cmd, opts) do
    port = Port.open({:spawn_executable, String.to_charlist(cmd)}, opts)
    {:ok, port}
  rescue
    e -> {:error, -32_000, "Failed to spawn process: #{Exception.message(e)}", nil}
  end

  @spec maybe_put_opt(list(), atom(), term()) :: list()
  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: opts ++ [{key, value}]

  @spec generate_id(pos_integer()) :: terminal_id()
  defp generate_id(n) do
    "term_" <> String.pad_leading(Integer.to_string(n), 6, "0")
  end

  @spec get_os_pid(port()) :: integer() | nil
  defp get_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> pid
      _ -> nil
    end
  end

  @spec find_terminal_by_port(t(), port()) :: {terminal_id(), terminal()} | nil
  defp find_terminal_by_port(state, port) do
    Enum.find(state.terminals, fn {_id, terminal} -> terminal.port == port end)
  end

  @spec append_to_buffer(binary(), binary(), pos_integer()) ::
          {binary(), boolean()}
  defp append_to_buffer(buffer, data, limit) do
    combined = buffer <> data

    if byte_size(combined) > limit do
      # Truncate to limit and mark as truncated.
      # We still consume the data to prevent pipe back-pressure,
      # but only keep up to the limit.
      truncated_bin = binary_part(combined, 0, limit)
      {truncated_bin, true}
    else
      {combined, false}
    end
  end

  @replacement_character "�"

  @spec ensure_valid_utf8(binary()) :: String.t()
  defp ensure_valid_utf8(buffer) do
    if String.valid?(buffer) do
      buffer
    else
      replace_invalid_utf8(buffer, [])
    end
  end

  defp replace_invalid_utf8(<<>>, acc) do
    acc
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  defp replace_invalid_utf8(buffer, acc) do
    case :unicode.characters_to_binary(buffer, :utf8, :utf8) do
      converted when is_binary(converted) ->
        [converted | acc]
        |> Enum.reverse()
        |> IO.iodata_to_binary()

      {:error, valid_prefix, rest} ->
        # Drop exactly one invalid byte, preserve any valid prefix, and insert
        # U+FFFD so callers can see where lossy decoding happened.
        <<_bad_byte, tail::binary>> = rest
        replace_invalid_utf8(tail, [@replacement_character, valid_prefix | acc])

      {:incomplete, valid_prefix, _rest} ->
        # A trailing partial UTF-8 sequence (commonly caused by byte-limit
        # truncation) cannot be encoded as JSON. Preserve the valid prefix and
        # mark the incomplete codepoint with U+FFFD.
        [@replacement_character, valid_prefix | acc]
        |> Enum.reverse()
        |> IO.iodata_to_binary()
    end
  end

  @spec send_sigkill(terminal()) :: :ok
  defp send_sigkill(%{os_pid: os_pid}) when is_integer(os_pid) do
    try do
      System.cmd("kill", ["-9", Integer.to_string(os_pid)], stderr_to_stdout: true)
    catch
      :error, _ -> :ok
    end

    :ok
  end

  defp send_sigkill(%{port: port}) when is_port(port) do
    # Fallback: close the port (sends SIGTERM then SIGKILL on Unix).
    safe_close_port(port)
    :ok
  end

  defp send_sigkill(_), do: :ok

  @spec safe_close_port(port()) :: :ok
  defp safe_close_port(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  catch
    :error, :badarg -> :ok
  end

  @spec format_exit_info(integer()) :: map()
  defp format_exit_info(exit_status) when is_integer(exit_status) do
    if exit_status > 128 do
      # On Unix, exit code > 128 means killed by signal.
      # The signal number is exit_code - 128.
      signal = exit_status - 128
      %{"exitCode" => exit_status, "signal" => signal}
    else
      %{"exitCode" => exit_status, "signal" => nil}
    end
  end

  @spec format_exit_status(terminal()) :: map() | nil
  defp format_exit_status(%{exit_status: nil}), do: nil

  defp format_exit_status(%{exit_status: exit_status}) do
    format_exit_info(exit_status)
  end

  @spec cancel_wait_timer(terminal()) :: :ok
  defp cancel_wait_timer(%{wait_timer: nil}), do: :ok

  defp cancel_wait_timer(%{wait_timer: ref}) when is_reference(ref) do
    _ = Process.cancel_timer(ref, async: true, info: false)
    :ok
  end
end
