defmodule KiroCockpit.Test.Acp.FakeAgent do
  @moduledoc """
  A minimal scripted JSON-RPC agent used by `KiroCockpit.Acp.PortProcessTest`.

  Reads newline-delimited JSON-RPC 2.0 messages on stdin and writes scripted
  replies to stdout. Mirrors `kiro_acp/tests/fake_kiro.py` in spirit but lives
  inside the Elixir test runtime so we don't need a Python dependency.

  ## Wire script

    * Inbound `ping` request → reply `{"pong": true}`, then emit a
      `session/update` notification, then send a `fs/read` request to the
      client and wait for its response, then emit a `session/done`
      notification.
    * Inbound `silent` request → consume the request and emit nothing.
      Used by timeout regression tests. Because we still read stdin in the
      loop, closing the port (which closes our stdin) drives us to `:eof`
      and we exit cleanly — no orphaned child process.
    * Any other request → `-32601 Method not found`.
    * Notifications → silently consumed.

  ## Why a compiled module rather than an `.exs` script

  `elixirc_paths(:test)` already compiles `test/support/`, so `KiroCockpit` and
  its deps (notably `Jason`) are on the BEAM code path. The `port_process_test`
  spawns this via `elixir -pa <ebin paths> -e "<entry>"` — no script parsing
  overhead, no Mix.install, no JSON micro-encoder. Just a real module.

  ## Buffering

  We use `IO.binwrite/2` against `:standard_io`. The BEAM's IO subsystem does
  not block-buffer pipe stdout the way C stdio does, so each `IO.binwrite`
  call surfaces to the parent's port driver immediately. We don't need an
  explicit flush.
  """

  @doc """
  Entry point for the script. Reads stdin line-by-line and dispatches.
  """
  @spec main() :: :ok
  def main do
    loop()
  end

  # -- Loop -----------------------------------------------------------------

  defp loop do
    case IO.read(:stdio, :line) do
      :eof ->
        :ok

      {:error, _} ->
        :ok

      data when is_binary(data) ->
        case decode(data) do
          {:ok, msg} -> handle(msg)
          :skip -> :ok
        end

        loop()
    end
  end

  @spec decode(binary()) :: {:ok, map()} | :skip
  defp decode(data) do
    trimmed = String.trim_trailing(data, "\n") |> String.trim_trailing("\r")

    cond do
      trimmed == "" ->
        :skip

      true ->
        Jason.decode(trimmed)
        |> case do
          {:ok, map} when is_map(map) -> {:ok, map}
          _ -> :skip
        end
    end
  end

  # -- Dispatch -------------------------------------------------------------

  @spec handle(map()) :: :ok
  defp handle(%{"id" => id, "method" => method} = msg) do
    handle_request(id, method, Map.get(msg, "params", %{}))
  end

  defp handle(%{"id" => id} = msg) when is_integer(id) or is_binary(id) do
    # response to a request WE sent — used for the fs/read round-trip
    handle_response(id, msg)
  end

  defp handle(%{"method" => _method}) do
    # bare notification — ignored
    :ok
  end

  defp handle(_other), do: :ok

  # Responses to the fs/read request we send back to the client.
  @fs_read_id 9001

  defp handle_response(@fs_read_id, msg) do
    # Got the client's reply to our fs/read. Emit a final notification
    # confirming we received it (with the contents), so the test can assert
    # the round-trip succeeded.
    contents =
      case msg do
        %{"result" => %{"contents" => c}} -> c
        _ -> nil
      end

    write(%{
      "jsonrpc" => "2.0",
      "method" => "session/done",
      "params" => %{"echoed" => contents}
    })
  end

  defp handle_response(_id, _msg), do: :ok

  # -- Request handling -----------------------------------------------------

  defp handle_request(id, "ping", _params) do
    # 1. respond to the ping
    write(%{"jsonrpc" => "2.0", "id" => id, "result" => %{"pong" => true}})

    # 2. emit a notification
    write(%{
      "jsonrpc" => "2.0",
      "method" => "session/update",
      "params" => %{"phase" => "thinking"}
    })

    # 3. send a request BACK to the client (agent → client direction)
    write(%{
      "jsonrpc" => "2.0",
      "id" => @fs_read_id,
      "method" => "fs/read",
      "params" => %{"path" => "/tmp/kiro-fake.txt"}
    })

    :ok
  end

  defp handle_request(id, "echo", params) do
    write(%{"jsonrpc" => "2.0", "id" => id, "result" => params})
    :ok
  end

  # No reply on purpose. The client will hit its request timeout (or the
  # `:infinity` path will resolve only when stdin closes / the port exits).
  defp handle_request(_id, "silent", _params), do: :ok

  defp handle_request(id, "boom", _params) do
    write(%{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => -32000, "message" => "boom", "data" => %{"trace" => "synthetic"}}
    })

    :ok
  end

  defp handle_request(id, _other, _params) do
    write(%{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => -32601, "message" => "Method not found"}
    })

    :ok
  end

  # -- IO -------------------------------------------------------------------

  @spec write(map()) :: :ok
  defp write(map) do
    line = Jason.encode!(map) <> "\n"
    IO.binwrite(:standard_io, line)
    :ok
  end
end
