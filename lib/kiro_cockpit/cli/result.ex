defmodule KiroCockpit.CLI.Result do
  @moduledoc """
  Tiny, deterministic helper for building CLI command result payloads.

  All CLI commands return either `{:ok, payload}` or `{:error,
  payload}` where:

    * the `:ok` payload contains a stable `:kind` atom plus arbitrary
      data,
    * the `:error` payload contains a stable `:code` atom, a
      `:message` string, and optional metadata.

  These helpers exist so command modules don't repeat the same
  three-line map literal at every return point and so the contract
  stays uniform for downstream consumers (REPL, web bridge, tests).
  """

  @type ok_payload :: %{required(:kind) => atom(), optional(atom()) => term()}
  @type error_payload :: %{
          required(:code) => atom(),
          required(:message) => String.t(),
          optional(atom()) => term()
        }

  @doc "Wraps a successful command result with a stable `:kind` atom."
  @spec ok(atom(), map()) :: {:ok, ok_payload()}
  def ok(kind, payload) when is_atom(kind) and is_map(payload) do
    {:ok, Map.put(payload, :kind, kind)}
  end

  @doc "Wraps an error with a stable `:code` atom, a message, and optional metadata."
  @spec error(atom(), String.t(), keyword() | map()) :: {:error, error_payload()}
  def error(code, message, extras \\ [])

  def error(code, message, extras)
      when is_atom(code) and is_binary(message) and is_list(extras) do
    error(code, message, Map.new(extras))
  end

  def error(code, message, extras) when is_atom(code) and is_binary(message) and is_map(extras) do
    {:error, extras |> Map.put(:code, code) |> Map.put(:message, message)}
  end
end
