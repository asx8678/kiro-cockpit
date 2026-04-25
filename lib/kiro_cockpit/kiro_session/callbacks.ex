defmodule KiroCockpit.KiroSession.Callbacks do
  @moduledoc """
  ACP client callback handlers for `fs/*` and `terminal/*` methods.

  Implements automatic handling of agent→client requests per
  kiro-acp-instructions.md §9. This module is the dispatch boundary:
  it validates parameters, executes file operations directly, and delegates
  terminal operations to `TerminalManager`.

  ## Error codes

  JSON-RPC error codes used:

    * `-32602` — Invalid params (missing/invalid path, non-absolute path, etc.)
    * `-32000` — Operation error (file not found, read error, terminal not found, etc.)

  ## Integration

  `KiroSession` calls `handle_request/3` when `auto_callbacks` is enabled.
  The subscriber still receives the raw `{:acp_request, ...}` for observability
  but does NOT need to call `respond/3` for handled methods.

  Terminal operations are dispatched to `TerminalManager` and may be
  called from a Task to avoid blocking the KiroSession GenServer.
  """

  alias KiroCockpit.KiroSession.TerminalManager

  # -- Error codes (JSON-RPC standard + custom range) -------------------------

  @error_invalid_params -32_602
  @error_operation -32_000
  @error_method_not_allowed -32_000

  # -- Known methods ----------------------------------------------------------

  @known_method_list [
    "fs/read_text_file",
    "fs/write_text_file",
    "terminal/create",
    "terminal/output",
    "terminal/wait_for_exit",
    "terminal/kill",
    "terminal/release"
  ]

  @known_methods MapSet.new(@known_method_list)

  # -- Mutating methods (denied under :read_only policy) ----------------------

  @mutating_methods MapSet.new([
                      "fs/write_text_file",
                      "terminal/create",
                      "terminal/output",
                      "terminal/wait_for_exit",
                      "terminal/kill",
                      "terminal/release"
                    ])

  # -- Callback policy --------------------------------------------------------

  @typedoc """
  Callback policy controlling which ACP client methods are auto-handled.

    * `:read_only` — only `fs/read_text_file` is allowed and auto-handled.
      Mutating methods (`fs/write_text_file`, `terminal/*`) are denied
      with a JSON-RPC error response. This is the safe default.
    * `:all` / `:trusted` — all known methods are allowed and auto-handled.
      Use for trusted/approved execution contexts.
  """
  @type callback_policy :: :read_only | :all | :trusted

  @doc """
  Check if a method is auto-handled by this module.
  """
  @spec known_method?(String.t()) :: boolean()
  def known_method?(method) when is_binary(method) do
    MapSet.member?(@known_methods, method)
  end

  @doc """
  Check if a method is a mutating (write/terminal) callback.

  Mutating methods are denied under the `:read_only` callback policy.
  """
  @spec mutating_method?(String.t()) :: boolean()
  def mutating_method?(method) when is_binary(method) do
    MapSet.member?(@mutating_methods, method)
  end

  @doc """
  Check if a method is allowed under the given callback policy.

    * `:read_only` — only `fs/read_text_file` is allowed.
    * `:all` / `:trusted` — all known methods are allowed.
  """
  @spec allowed_by_policy?(String.t(), callback_policy()) :: boolean()
  def allowed_by_policy?(method, policy) when is_binary(method) do
    case policy do
      :read_only -> method == "fs/read_text_file"
      :all -> known_method?(method)
      :trusted -> known_method?(method)
    end
  end

  @doc """
  Returns the client capabilities map for a given callback policy.

  These are advertised to the agent during `initialize`.
  """
  @spec capabilities_for_policy(callback_policy()) :: map()
  def capabilities_for_policy(:read_only) do
    %{"fs" => %{"readTextFile" => true, "writeTextFile" => false}, "terminal" => false}
  end

  def capabilities_for_policy(:all) do
    %{"fs" => %{"readTextFile" => true, "writeTextFile" => true}, "terminal" => true}
  end

  def capabilities_for_policy(:trusted) do
    %{"fs" => %{"readTextFile" => true, "writeTextFile" => true}, "terminal" => true}
  end

  @doc """
  Clamp caller-supplied client capabilities so they cannot exceed policy.

  Atom-keyed caller maps are normalized to canonical JSON/string keys before
  clamping so the encoded `initialize` payload cannot contain duplicate or
  parser-dependent capability keys. Under `:read_only`, callers may further
  reduce capabilities (for example disable fs read) but cannot advertise write
  or terminal support. Trusted policies preserve requested values after key
  normalization.
  """
  @spec clamp_capabilities_for_policy(map(), callback_policy()) :: map()
  def clamp_capabilities_for_policy(capabilities, :read_only) when is_map(capabilities) do
    capabilities = normalize_capability_keys(capabilities)

    fs =
      capabilities
      |> Map.get("fs", %{})
      |> case do
        fs when is_map(fs) -> fs
        _other -> %{}
      end
      |> Map.put("writeTextFile", false)

    capabilities
    |> Map.put("fs", fs)
    |> Map.put("terminal", false)
  end

  def clamp_capabilities_for_policy(capabilities, policy)
      when is_map(capabilities) and policy in [:all, :trusted],
      do: normalize_capability_keys(capabilities)

  defp normalize_capability_keys(value) when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _value} -> key_precedence(key) end)
    |> Enum.reduce(%{}, fn {key, child}, normalized ->
      case normalize_capability_key(key) do
        nil -> normalized
        key -> Map.put(normalized, key, normalize_capability_keys(child))
      end
    end)
  end

  defp normalize_capability_keys(value), do: value

  defp normalize_capability_key(key) when is_binary(key), do: key
  defp normalize_capability_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_capability_key(_key), do: nil

  # Preserve explicit JSON/string keys over equivalent atom keys in mixed maps.
  defp key_precedence(key) when is_atom(key), do: {0, Atom.to_string(key)}
  defp key_precedence(key) when is_binary(key), do: {1, key}
  defp key_precedence(key), do: {2, inspect(key)}

  @doc """
  Returns a denied-method error tuple suitable for a JSON-RPC error response.

  Used when a known mutating callback is requested under a `:read_only` policy.
  """
  @spec denied_error(String.t()) :: {:error, integer(), String.t(), nil}
  def denied_error(method) do
    {:error, @error_method_not_allowed,
     "Callback method not allowed under current policy: #{method}", nil}
  end

  @doc """
  Dispatch an agent→client callback request and return the result.

  Returns `{:ok, result}` on success or `{:error, code, message, data}` on
  failure. The caller is responsible for sending the appropriate JSON-RPC
  response.

  The `terminal_manager` argument is required for `terminal/*` methods
  and ignored for `fs/*` methods.
  """
  @spec handle_request(String.t(), term(), GenServer.server() | nil) ::
          {:ok, term()} | {:error, integer(), String.t(), term()}
  def handle_request(method, params, terminal_manager \\ nil)

  # Top-level guard: all known callback methods require JSON object params.
  # ACP/JSON-RPC permits params to be omitted/null/array in general, but these
  # client callbacks are object-shaped. Reject invalid shapes before helper
  # functions call Map.fetch/Map.get and raise BadMapError.
  def handle_request(method, params, _terminal_manager)
      when is_binary(method) and not is_map(params) do
    if known_method?(method) do
      {:error, @error_invalid_params,
       "Invalid params: expected a JSON object (map), got #{inspect(params)}", nil}
    else
      {:error, -32_601, "Method not found: #{method}", nil}
    end
  end

  # -- fs/read_text_file ------------------------------------------------------

  def handle_request("fs/read_text_file", params, _terminal_manager) do
    with {:ok, path} <- require_absolute_path(params, "path"),
         {:ok, _line_val} <- validate_line_param(Map.get(params, "line")),
         {:ok, _limit_val} <- validate_limit_param(Map.get(params, "limit")),
         {:ok, content} <- read_file_content(path),
         {:ok, sliced} <- maybe_slice_lines_validated(content, params) do
      {:ok, %{"content" => sliced}}
    end
  end

  # -- fs/write_text_file -----------------------------------------------------

  def handle_request("fs/write_text_file", params, _terminal_manager) do
    with {:ok, path} <- require_absolute_path(params, "path"),
         {:ok, content} <- require_content(params) do
      case write_file(path, content) do
        :ok -> {:ok, nil}
        {:error, reason} -> {:error, @error_operation, "Write failed: #{reason}", nil}
      end
    end
  end

  # -- terminal/create --------------------------------------------------------

  def handle_request("terminal/create", params, terminal_manager) do
    with {:ok, command} <- require_param(params, "command", "string"),
         {:ok, args} <- validate_args(Map.get(params, "args", [])),
         {:ok, env} <- validate_env(Map.get(params, "env", [])),
         {:ok, output_byte_limit} <-
           validate_output_byte_limit(Map.get(params, "outputByteLimit", 1_048_576)),
         {:ok, cwd} <- validate_cwd_param(Map.get(params, "cwd")),
         {:ok, terminal_manager} <- require_terminal_manager(terminal_manager) do
      case TerminalManager.create(terminal_manager, command, args, cwd, env, output_byte_limit) do
        {:ok, term_id} -> {:ok, %{"terminalId" => term_id}}
        {:error, code, message, data} -> {:error, code, message, data}
      end
    end
  end

  # -- terminal/output --------------------------------------------------------

  def handle_request("terminal/output", params, terminal_manager) do
    with {:ok, term_id} <- require_terminal_id(params),
         {:ok, terminal_manager} <- require_terminal_manager(terminal_manager) do
      case TerminalManager.output(terminal_manager, term_id) do
        {:ok, result} -> {:ok, result}
        {:error, code, message, data} -> {:error, code, message, data}
      end
    end
  end

  # -- terminal/wait_for_exit -------------------------------------------------

  def handle_request("terminal/wait_for_exit", params, terminal_manager) do
    with {:ok, term_id} <- require_terminal_id(params),
         {:ok, terminal_manager} <- require_terminal_manager(terminal_manager) do
      case TerminalManager.wait_for_exit(terminal_manager, term_id) do
        {:ok, result} -> {:ok, result}
        {:error, code, message, data} -> {:error, code, message, data}
      end
    end
  end

  # -- terminal/kill ----------------------------------------------------------

  def handle_request("terminal/kill", params, terminal_manager) do
    with {:ok, term_id} <- require_terminal_id(params),
         {:ok, terminal_manager} <- require_terminal_manager(terminal_manager) do
      case TerminalManager.kill(terminal_manager, term_id) do
        {:ok, nil} -> {:ok, nil}
        {:error, code, message, data} -> {:error, code, message, data}
      end
    end
  end

  # -- terminal/release -------------------------------------------------------

  def handle_request("terminal/release", params, terminal_manager) do
    with {:ok, term_id} <- require_terminal_id(params),
         {:ok, terminal_manager} <- require_terminal_manager(terminal_manager) do
      case TerminalManager.release(terminal_manager, term_id) do
        {:ok, nil} -> {:ok, nil}
        {:error, code, message, data} -> {:error, code, message, data}
      end
    end
  end

  # -- Unknown method (should not be reached via KiroSession, but defensive) --

  def handle_request(method, _params, _terminal_manager) do
    {:error, -32_601, "Method not found: #{method}", nil}
  end

  # -- fs/* internals ---------------------------------------------------------

  @spec require_absolute_path(map(), String.t()) ::
          {:ok, String.t()} | {:error, integer(), String.t(), nil}
  defp require_absolute_path(params, key) do
    case Map.fetch(params, key) do
      {:ok, path} when is_binary(path) and byte_size(path) > 0 ->
        if Path.type(path) == :absolute do
          {:ok, path}
        else
          {:error, @error_invalid_params, "Path must be absolute: #{path}", nil}
        end

      _ ->
        {:error, @error_invalid_params, "Missing required parameter: #{key}", nil}
    end
  end

  @spec require_content(map()) ::
          {:ok, binary()} | {:error, integer(), String.t(), nil}
  defp require_content(params) do
    case Map.fetch(params, "content") do
      {:ok, content} when is_binary(content) -> {:ok, content}
      _ -> {:error, @error_invalid_params, "Missing required parameter: content", nil}
    end
  end

  @spec require_param(map(), String.t(), String.t()) ::
          {:ok, term()} | {:error, integer(), String.t(), nil}
  defp require_param(params, key, type) do
    case Map.fetch(params, key) do
      {:ok, value} when type == "string" and is_binary(value) -> {:ok, value}
      {:ok, value} when type == "list" and is_list(value) -> {:ok, value}
      _ -> {:error, @error_invalid_params, "Missing or invalid parameter: #{key}", nil}
    end
  end

  @spec require_terminal_id(map()) ::
          {:ok, String.t()} | {:error, integer(), String.t(), nil}
  defp require_terminal_id(params) do
    case Map.fetch(params, "terminalId") do
      {:ok, id} when is_binary(id) and byte_size(id) > 0 -> {:ok, id}
      _ -> {:error, @error_invalid_params, "Missing required parameter: terminalId", nil}
    end
  end

  @spec require_terminal_manager(GenServer.server() | nil) ::
          {:ok, GenServer.server()} | {:error, integer(), String.t(), nil}
  defp require_terminal_manager(nil) do
    {:error, @error_operation, "Terminal not available (auto_callbacks disabled)", nil}
  end

  defp require_terminal_manager(pid) when is_pid(pid) do
    {:ok, pid}
  end

  defp require_terminal_manager(name) do
    {:ok, name}
  end

  # -- terminal/create parameter validation -----------------------------------

  @spec validate_args(term()) :: {:ok, [String.t()]} | {:error, integer(), String.t(), nil}
  defp validate_args(args) when is_list(args) do
    if Enum.all?(args, &is_binary/1) do
      {:ok, args}
    else
      {:error, @error_invalid_params, "Parameter 'args' must be a list of strings", nil}
    end
  end

  defp validate_args(_args) do
    {:error, @error_invalid_params, "Parameter 'args' must be a list of strings", nil}
  end

  @spec validate_env(term()) :: {:ok, [map()]} | {:error, integer(), String.t(), nil}
  defp validate_env(env) when is_list(env) do
    if Enum.all?(env, &valid_env_entry?/1) do
      {:ok, env}
    else
      {:error, @error_invalid_params,
       "Parameter 'env' must be a list of maps with binary 'name' and binary 'value'", nil}
    end
  end

  defp validate_env(_env) do
    {:error, @error_invalid_params,
     "Parameter 'env' must be a list of maps with binary 'name' and binary 'value'", nil}
  end

  @spec valid_env_entry?(term()) :: boolean()
  defp valid_env_entry?(%{"name" => name, "value" => value})
       when is_binary(name) and is_binary(value),
       do: true

  defp valid_env_entry?(_), do: false

  @spec validate_output_byte_limit(term()) ::
          {:ok, pos_integer()} | {:error, integer(), String.t(), nil}
  defp validate_output_byte_limit(limit) when is_integer(limit) and limit >= 1 do
    {:ok, limit}
  end

  defp validate_output_byte_limit(limit) do
    {:error, @error_invalid_params,
     "Parameter 'outputByteLimit' must be a positive integer, got: #{inspect(limit)}", nil}
  end

  @spec validate_cwd_param(term()) ::
          {:ok, String.t() | nil} | {:error, integer(), String.t(), nil}
  defp validate_cwd_param(nil), do: {:ok, nil}

  defp validate_cwd_param(cwd) when is_binary(cwd) and byte_size(cwd) > 0 do
    if Path.type(cwd) == :absolute do
      if File.dir?(cwd) do
        {:ok, cwd}
      else
        {:error, @error_invalid_params, "Parameter 'cwd' directory does not exist: #{cwd}", nil}
      end
    else
      {:error, @error_invalid_params, "Parameter 'cwd' must be an absolute path: #{cwd}", nil}
    end
  end

  defp validate_cwd_param(_cwd) do
    {:error, @error_invalid_params, "Parameter 'cwd' must be a non-empty absolute path", nil}
  end

  @spec read_file_content(Path.t()) ::
          {:ok, binary()} | {:error, integer(), String.t(), nil}
  defp read_file_content(path) do
    case File.read(path) do
      {:ok, raw} ->
        {:ok, decode_file_content(raw)}

      {:error, :enoent} ->
        {:error, @error_operation, "File not found: #{path}", nil}

      {:error, :eacces} ->
        {:error, @error_operation, "Permission denied: #{path}", nil}

      {:error, reason} ->
        {:error, @error_operation, "Read failed: #{inspect(reason)}", nil}
    end
  end

  @spec decode_file_content(binary()) :: binary()
  defp decode_file_content(raw) do
    if String.valid?(raw) do
      raw
    else
      # latin-1 is a lossless encoding for any byte sequence.
      # Convert the raw binary to a latin-1 string then to UTF-8.
      raw
      |> :binary.bin_to_list()
      |> Enum.map_join(fn
        byte when byte < 128 -> <<byte>>
        byte -> <<0xC2 + Bitwise.bsr(byte, 6), 0x80 + Bitwise.band(byte, 0x3F)>>
      end)
    end
  end

  # Variant that assumes line/limit have already been validated by the caller.
  # Avoids redundant validation when the `with` chain checks params early.
  @spec maybe_slice_lines_validated(binary(), map()) :: {:ok, binary()}
  defp maybe_slice_lines_validated(content, params) do
    line = Map.get(params, "line")
    limit = Map.get(params, "limit")

    if line == nil and limit == nil do
      {:ok, content}
    else
      line_val = if line != nil, do: line, else: 1
      slice_content(content, line_val, limit)
    end
  end

  @spec slice_content(binary(), pos_integer(), pos_integer() | nil) :: {:ok, binary()}
  defp slice_content(content, line_val, limit_val) do
    lines = split_lines(content)
    start_idx = line_val - 1
    end_idx = if limit_val != nil, do: start_idx + limit_val, else: length(lines)
    sliced = Enum.slice(lines, start_idx, end_idx - start_idx)
    {:ok, Enum.join(sliced, "\n")}
  end

  # Validate the `line` parameter: must be a positive integer (1-based).
  # Returns `{:ok, 1}` when nil (default: start from line 1).
  @spec validate_line_param(term()) :: {:ok, pos_integer()} | {:error, integer(), String.t(), nil}
  defp validate_line_param(nil), do: {:ok, 1}

  defp validate_line_param(line) when is_integer(line) and line >= 1 do
    {:ok, line}
  end

  defp validate_line_param(line) do
    {:error, @error_invalid_params,
     "Parameter 'line' must be a positive integer (1-based), got: #{inspect(line)}", nil}
  end

  # Validate the `limit` parameter: must be a positive integer when present.
  # Returns `{:ok, nil}` when nil (no limit — read to end of file).
  @spec validate_limit_param(term()) ::
          {:ok, pos_integer() | nil} | {:error, integer(), String.t(), nil}
  defp validate_limit_param(nil), do: {:ok, nil}

  defp validate_limit_param(limit) when is_integer(limit) and limit >= 1 do
    {:ok, limit}
  end

  defp validate_limit_param(limit) do
    {:error, @error_invalid_params,
     "Parameter 'limit' must be a positive integer, got: #{inspect(limit)}", nil}
  end

  # Split content on newlines, preserving empty lines between delimiters
  # (equivalent to `String.split(content, "\n", include_empties: true)`
  # but avoids a dialyzer contract warning on the `:include_empties` option).
  @spec split_lines(binary()) :: [binary()]
  defp split_lines(content) do
    String.split(content, "\n")
  end

  @spec write_file(Path.t(), binary()) :: :ok | {:error, String.t()}
  defp write_file(path, content) do
    # Create parent directories if they don't exist (per ACP spec:
    # "Create the file if it doesn't exist" — and parent creation is
    # reasonable and documented).
    parent = Path.dirname(path)

    with :ok <- File.mkdir_p(parent),
         :ok <- File.write(path, content) do
      :ok
    else
      {:error, reason} -> {:error, inspect(reason)}
    end
  end
end
