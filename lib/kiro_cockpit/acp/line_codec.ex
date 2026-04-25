defmodule KiroCockpit.Acp.LineCodec do
  @moduledoc """
  Newline-delimited JSON framing for ACP stdio transport.

  ACP §13: one JSON object per line, no `Content-Length` headers, no embedded
  newlines inside a payload. This module is the **framing boundary**: bytes on
  one side, parsed maps on the other. It owns no state; it does no I/O.

  ## Encoding

  `encode!/1` and `encode/1` serialize an Elixir term to a single line of JSON
  with a trailing `\\n`. The encoder defends against the "embedded raw newline"
  hazard — Jason escapes string-internal newlines as `\\n`, but we still verify
  the encoded payload contains no raw `\\n` before appending the framing byte.
  If a future encoder change ever broke that invariant, we'd rather crash than
  silently desync the stream.

  ## Decoding

  `decode/1` accepts a single line (with or without a trailing CRLF/LF), trims
  the line ending, rejects:

    - blank lines (`{:error, :blank}`)
    - lines containing an embedded raw `\\n` outside the trailing delimiter
      (`{:error, :embedded_newline}`)
    - lines whose payload is not valid JSON (`{:error, {:invalid_json, _}}`)

  On success it returns `{:ok, term}` where `term` is the decoded JSON value.

  ## Why this lives outside `PortProcess`

  Pure stateless framing is trivially testable, deterministic, and reusable for
  any future transport (sockets, named pipes, in-memory). Putting it in a
  GenServer would be a mailbox detour for no benefit.
  """

  @typedoc "A decoded JSON value (object, array, string, number, bool, nil)."
  @type json_value ::
          map()
          | list()
          | binary()
          | number()
          | boolean()
          | nil

  @typedoc "Reasons `decode/1` may reject a line."
  @type decode_error ::
          :blank
          | :embedded_newline
          | {:invalid_json, term()}
          | {:not_binary, term()}

  @doc """
  Encode `term` as a single line of JSON with a trailing `\\n`.

  Raises if `term` is not JSON-encodable, or if the encoded payload contains a
  raw newline (which would break framing).
  """
  @spec encode!(term()) :: binary()
  def encode!(term) do
    payload = Jason.encode!(term)
    guard_no_embedded_newline!(payload)
    payload <> "\n"
  end

  @doc """
  Encode `term` as a single line of JSON with a trailing `\\n`.

  Returns `{:ok, line}` or `{:error, reason}`.
  """
  @spec encode(term()) :: {:ok, binary()} | {:error, term()}
  def encode(term) do
    with {:ok, payload} <- Jason.encode(term),
         :ok <- check_no_embedded_newline(payload) do
      {:ok, payload <> "\n"}
    end
  end

  @doc """
  Decode a single line into a JSON term.

  Accepts an optional trailing `\\n` or `\\r\\n` and trims it. Lines with raw
  newlines anywhere except at the very end are rejected.

  ## Examples

      iex> KiroCockpit.Acp.LineCodec.decode(~s({"a":1}\\n))
      {:ok, %{"a" => 1}}

      iex> KiroCockpit.Acp.LineCodec.decode("")
      {:error, :blank}

      iex> KiroCockpit.Acp.LineCodec.decode("not json\\n")
      {:error, {:invalid_json, _}} = KiroCockpit.Acp.LineCodec.decode("not json\\n")
  """
  @spec decode(binary()) :: {:ok, json_value()} | {:error, decode_error()}
  def decode(line) when is_binary(line) do
    trimmed = strip_trailing_newline(line)

    cond do
      trimmed == "" ->
        {:error, :blank}

      String.contains?(trimmed, "\n") ->
        {:error, :embedded_newline}

      true ->
        case Jason.decode(trimmed) do
          {:ok, value} -> {:ok, value}
          {:error, err} -> {:error, {:invalid_json, err}}
        end
    end
  end

  def decode(other), do: {:error, {:not_binary, other}}

  # -- Internals ------------------------------------------------------------

  @spec strip_trailing_newline(binary()) :: binary()
  defp strip_trailing_newline(line) do
    cond do
      String.ends_with?(line, "\r\n") -> binary_part(line, 0, byte_size(line) - 2)
      String.ends_with?(line, "\n") -> binary_part(line, 0, byte_size(line) - 1)
      true -> line
    end
  end

  @spec guard_no_embedded_newline!(binary()) :: :ok
  defp guard_no_embedded_newline!(payload) do
    case check_no_embedded_newline(payload) do
      :ok -> :ok
      {:error, :embedded_newline} -> raise ArgumentError, "encoded JSON contains a raw newline"
    end
  end

  @spec check_no_embedded_newline(binary()) :: :ok | {:error, :embedded_newline}
  defp check_no_embedded_newline(payload) do
    if String.contains?(payload, "\n"), do: {:error, :embedded_newline}, else: :ok
  end
end
