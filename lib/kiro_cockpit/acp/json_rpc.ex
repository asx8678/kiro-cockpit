defmodule KiroCockpit.Acp.JsonRpc do
  @moduledoc """
  JSON-RPC 2.0 message construction and classification.

  This module is the **semantics boundary**: it knows the four shapes a wire
  message may take and produces / parses them. It does not perform I/O, framing,
  or correlation. That's `KiroCockpit.Acp.LineCodec` (framing) and
  `KiroCockpit.Acp.PortProcess` (correlation), respectively.

  ## Message shapes (per JSON-RPC 2.0)

    1. **Request**         — `%{jsonrpc, id, method, params?}`
    2. **Notification**    — `%{jsonrpc, method, params?}` (no `id`)
    3. **Success response**— `%{jsonrpc, id, result}` (no `method`, no `error`)
    4. **Error response**  — `%{jsonrpc, id, error: %{code, message, data?}}`

  IDs may be integers or strings per spec §3 — `classify/1` preserves the id
  exactly so callers can echo it back to whoever sent it.
  """

  @jsonrpc_version "2.0"

  @typedoc "A JSON-RPC message id: integer or string."
  @type id :: integer() | binary()

  @typedoc """
  Classified incoming message.

    * `{:request, id, method, params}` — peer wants a reply
    * `{:notification, method, params}` — peer expects no reply
    * `{:response, id, {:ok, result}}` — success answer to one of our requests
    * `{:response, id, {:error, error_obj}}` — failure answer
    * `{:invalid, reason, raw}` — malformed shape; `raw` is the original map
  """
  @type classified ::
          {:request, id(), binary(), map() | list() | nil}
          | {:notification, binary(), map() | list() | nil}
          | {:response, id(), {:ok, term()} | {:error, error_object()}}
          | {:invalid, term(), term()}

  @typedoc "JSON-RPC error object."
  @type error_object :: %{
          required(:code) => integer(),
          required(:message) => binary(),
          optional(:data) => term()
        }

  # -- Builders -------------------------------------------------------------

  @doc """
  Build a JSON-RPC 2.0 request map. `params` defaults to `%{}`.
  """
  @spec request(id(), binary(), map() | list() | nil) :: map()
  def request(id, method, params \\ %{})
      when (is_integer(id) or is_binary(id)) and is_binary(method) do
    %{"jsonrpc" => @jsonrpc_version, "id" => id, "method" => method, "params" => params || %{}}
  end

  @doc """
  Build a JSON-RPC 2.0 notification map (no id).
  """
  @spec notification(binary(), map() | list() | nil) :: map()
  def notification(method, params \\ %{}) when is_binary(method) do
    %{"jsonrpc" => @jsonrpc_version, "method" => method, "params" => params || %{}}
  end

  @doc """
  Build a JSON-RPC 2.0 success response.
  """
  @spec success_response(id(), term()) :: map()
  def success_response(id, result) when is_integer(id) or is_binary(id) do
    %{"jsonrpc" => @jsonrpc_version, "id" => id, "result" => result}
  end

  @doc """
  Build a JSON-RPC 2.0 error response.

  `data` is omitted from the wire payload when nil. ACP and most JSON-RPC peers
  treat presence/absence of `data` as semantically distinct.
  """
  @spec error_response(id(), integer(), binary(), term() | nil) :: map()
  def error_response(id, code, message, data \\ nil)
      when (is_integer(id) or is_binary(id)) and is_integer(code) and is_binary(message) do
    error =
      %{"code" => code, "message" => message}
      |> maybe_put("data", data)

    %{"jsonrpc" => @jsonrpc_version, "id" => id, "error" => error}
  end

  # -- Classifier -----------------------------------------------------------

  @doc """
  Classify an already-decoded JSON-RPC map into one of the four shapes.

  Tolerates a missing `"jsonrpc"` field (some agents are sloppy) but expects it
  to be `"2.0"` if present. IDs may be integer OR string — both are preserved
  exactly. `params` defaults to `%{}` if absent.
  """
  @spec classify(term()) :: classified()
  def classify(%{} = msg) do
    case version_ok?(msg) do
      true -> classify_shape(msg)
      false -> {:invalid, :bad_jsonrpc_version, msg}
    end
  end

  def classify(other), do: {:invalid, :not_a_map, other}

  # -- Internals ------------------------------------------------------------

  @spec version_ok?(map()) :: boolean()
  defp version_ok?(%{"jsonrpc" => v}), do: v == @jsonrpc_version
  # Tolerate missing version — some agents omit it. Reject only when present and wrong.
  defp version_ok?(_), do: true

  @spec classify_shape(map()) :: classified()
  defp classify_shape(msg) do
    do_classify(Map.get(msg, "id"), Map.get(msg, "method"), msg)
  end

  # Request: id + method, both well-typed.
  defp do_classify(id, method, msg)
       when (is_integer(id) or is_binary(id)) and is_binary(method) do
    {:request, id, method, Map.get(msg, "params", %{})}
  end

  # Notification: no id, has method.
  defp do_classify(nil, method, msg) when is_binary(method) do
    {:notification, method, Map.get(msg, "params", %{})}
  end

  # Response (success or error): well-typed id, no method.
  defp do_classify(id, nil, msg) when is_integer(id) or is_binary(id) do
    classify_response(id, msg)
  end

  defp do_classify(_id, _method, msg), do: {:invalid, :unrecognized_shape, msg}

  # Success — `result` present, `error` absent.
  defp classify_response(id, %{"result" => result} = msg)
       when not is_map_key(msg, "error") do
    {:response, id, {:ok, result}}
  end

  # Error — `error` present, `result` absent.
  defp classify_response(id, %{"error" => raw_error} = msg)
       when not is_map_key(msg, "result") do
    case normalize_error(raw_error) do
      {:ok, err} -> {:response, id, {:error, err}}
      {:error, reason} -> {:invalid, reason, msg}
    end
  end

  # Both fields present, or neither — invalid.
  defp classify_response(_id, msg), do: {:invalid, :unrecognized_shape, msg}

  @spec normalize_error(term()) :: {:ok, error_object()} | {:error, term()}
  defp normalize_error(%{"code" => code, "message" => message} = err)
       when is_integer(code) and is_binary(message) do
    base = %{code: code, message: message}

    case Map.fetch(err, "data") do
      {:ok, data} -> {:ok, Map.put(base, :data, data)}
      :error -> {:ok, base}
    end
  end

  defp normalize_error(other), do: {:error, {:malformed_error, other}}

  @spec maybe_put(map(), binary(), term() | nil) :: map()
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
