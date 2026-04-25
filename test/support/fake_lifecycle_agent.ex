defmodule KiroCockpit.Test.Acp.FakeLifecycleAgent do
  @moduledoc """
  Scripted JSON-RPC agent for `KiroCockpit.KiroSessionTest`.

  Implements the ACP lifecycle: `initialize`, `session/new`, `session/load`,
  and `session/prompt`. Emits `session/update` notifications after session
  creation, session load, and during prompt handling. Also sends an
  `fs/read_text_file` request during prompt to exercise inbound request
  forwarding.

  This module is separate from `KiroCockpit.Test.Acp.FakeAgent` (owned by
  kiro-x0q) to avoid cross-branch conflicts.

  ## Wire protocol

    * `initialize` → standard ACP response with `protocolVersion`,
      `agentCapabilities`, `agentInfo`, `authMethods`.
    * `session/new` → response with `sessionId`, `modes`, `configOptions`;
      then emits a `session/update` notification.
    * `session/load` → emits `session/update` notifications; responds with
      `null` result.
    * `session/prompt` → emits a `session/update` notification, then sends
      an `fs/read_text_file` request and waits for the client's response,
      then responds with `{stopReason: "end_turn"}`.
    * Unknown methods → `-32601 Method not found`.
    * Notifications → silently consumed.
    * Responses to our outbound requests (e.g. `fs/read_text_file`) are
      handled and logged.

  ## Why a compiled module

  Same rationale as `KiroCockpit.Test.Acp.FakeAgent`: `elixirc_paths(:test)`
  compiles `test/support/`, so `Jason` and `KiroCockpit` are on the BEAM code
  path. The test spawns this via `elixir -pa <ebin paths> -e "<entry>"`.
  """

  @fake_session_id "sess_fake_001"
  @fs_read_id 8001

  @doc """
  Entry point for the subprocess. Reads stdin line-by-line and dispatches.
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
        case Jason.decode(trimmed) do
          {:ok, map} when is_map(map) -> {:ok, map}
          _ -> :skip
        end
    end
  end

  # -- Dispatch -------------------------------------------------------------

  defp handle(%{"id" => id, "method" => method} = msg) do
    handle_request(id, method, Map.get(msg, "params", %{}))
  end

  # Response to an outbound request we sent (e.g. fs/read_text_file)
  defp handle(%{"id" => @fs_read_id} = msg) when is_integer(@fs_read_id) do
    _contents =
      case msg do
        %{"result" => %{"content" => c}} -> c
        _ -> nil
      end

    # Just consume the response; the prompt handler will proceed.
    :ok
  end

  defp handle(%{"id" => id} = msg) when is_integer(id) or is_binary(id) do
    # Response to some other outbound request — ignore
    _ = msg
    :ok
  end

  # Bare notification — silently consumed
  defp handle(%{"method" => _method}) do
    :ok
  end

  defp handle(_other), do: :ok

  # -- Request handlers ------------------------------------------------------

  defp handle_request(id, "initialize", _params) do
    write(%{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "protocolVersion" => 1,
        "agentCapabilities" => %{
          "loadSession" => true,
          "promptCapabilities" => %{
            "image" => false,
            "audio" => false,
            "embeddedContext" => true
          },
          "mcpCapabilities" => %{"http" => true, "sse" => false}
        },
        "agentInfo" => %{"name" => "kiro-fake", "version" => "0.0.1-test"},
        "authMethods" => []
      }
    })
  end

  defp handle_request(id, "session/new", %{"cwd" => _cwd} = params) do
    _mcp_servers = Map.get(params, "mcpServers", [])

    # Respond with session details
    write(%{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "sessionId" => @fake_session_id,
        "modes" => %{
          "currentModeId" => "code",
          "availableModes" => [
            %{"id" => "ask", "name" => "Ask", "description" => "Ask before editing"},
            %{"id" => "code", "name" => "Code", "description" => "Write/modify with full tools"}
          ]
        },
        "configOptions" => [
          %{
            "id" => "model",
            "name" => "Model",
            "category" => "model",
            "type" => "select",
            "currentValue" => "fake-model-v1",
            "options" => [
              %{"value" => "fake-model-v1", "name" => "Fake V1", "description" => "Test model"}
            ]
          }
        ]
      }
    })

    # Emit a session/update notification after creating the session
    write(%{
      "jsonrpc" => "2.0",
      "method" => "session/update",
      "params" => %{
        "sessionId" => @fake_session_id,
        "update" => %{
          "sessionUpdate" => "current_mode_update",
          "modeId" => "code"
        }
      }
    })

    :ok
  end

  # session/load: the cwd is used to acknowledge; agent streams back history
  # via session/update notifications, then responds with null.
  defp handle_request(id, "session/load", %{"sessionId" => session_id, "cwd" => _cwd}) do
    # Emit a session/update notification (replaying prior conversation)
    write(%{
      "jsonrpc" => "2.0",
      "method" => "session/update",
      "params" => %{
        "sessionId" => session_id,
        "update" => %{
          "sessionUpdate" => "agent_message_chunk",
          "content" => [%{"type" => "text", "text" => "Loading session..."}]
        }
      }
    })

    # Respond with null per ACP spec
    write(%{"jsonrpc" => "2.0", "id" => id, "result" => nil})
    :ok
  end

  defp handle_request(id, "session/prompt", %{"sessionId" => session_id}) do
    # 1. Emit a session/update notification (thinking chunk)
    write(%{
      "jsonrpc" => "2.0",
      "method" => "session/update",
      "params" => %{
        "sessionId" => session_id,
        "update" => %{
          "sessionUpdate" => "agent_message_chunk",
          "content" => [%{"type" => "text", "text" => "Thinking..."}]
        }
      }
    })

    # 2. Send an fs/read_text_file request back to the client
    #    (exercises inbound request forwarding)
    write(%{
      "jsonrpc" => "2.0",
      "id" => @fs_read_id,
      "method" => "fs/read_text_file",
      "params" => %{
        "sessionId" => session_id,
        "path" => "/tmp/kiro-lifecycle-test.txt",
        "line" => 1,
        "limit" => 10
      }
    })

    # 3. Wait briefly for the client's response (non-blocking read)
    #    In a real agent, this would block. For the fake, we just proceed
    #    after a small delay to allow the client to respond.
    Process.sleep(100)

    # 4. Respond to the original prompt request
    write(%{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{"stopReason" => "end_turn"}
    })

    :ok
  end

  defp handle_request(id, "session/prompt", _params) do
    # Prompt without sessionId — still respond for robustness
    write(%{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{"stopReason" => "end_turn"}
    })

    :ok
  end

  defp handle_request(id, _method, _params) do
    write(%{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => -32_601, "message" => "Method not found"}
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
