defmodule KiroCockpit.Test.Acp.FakeLongTurnAgent do
  @moduledoc """
  Fake ACP agent for kiro-011 long-turn regression test.

  This agent deliberately **withholds** the `turn_end` session/update
  notification until the test sends a `test/emit_turn_end` trigger via
  `KiroSession.notify/3`. This makes the race between prompt RPC result
  and `turn_end` fully deterministic — no sleeps, no timing games.

  ## Session/prompt flow

    1. Emits a `session/update` `agent_message_chunk` (proves streaming works).
    2. Responds to `session/prompt` with `stopReason: "end_turn"` — this
       unblocks `KiroSession.prompt/3` on the caller side.
    3. **Blocks** reading stdin until a `test/emit_turn_end` notification
       arrives.
    4. On trigger, emits a `session/update` `turn_end` notification — this
       is the **only** signal that completes the turn in `KiroSession`.

  The test can therefore:

    * `Task.await` the prompt task (RPC result returned)
    * Assert `turn_status == :running` (the headline invariant)
    * Assert a second prompt returns `{:error, :turn_in_progress}`
    * Send `test/emit_turn_end` via `KiroSession.notify/3`
    * Receive the `:turn_end` stream event
    * Assert `turn_status == :complete`

  ## Why a separate module

  The shared `FakeAgent` (kiro-x0q) already has a `:long_turn` scenario, but
  it emits all actions in one `emit_actions` batch — there's no way for the
  test to observe the intermediate state where the prompt result has returned
  but `turn_end` hasn't arrived yet. Editing `FakeAgent` to add blocking
  behaviour would risk conflicts with kiro-x0q. A dedicated module keeps this
  regression test self-contained.

  ## Wire protocol

  Newline-delimited JSON-RPC 2.0 over stdio. Each message is a single JSON
  object terminated by `\\n`.
  """

  @fake_session_id "sess_long_turn_001"

  # -- Public entry point ----------------------------------------------------

  @doc """
  Entry point for the subprocess. Reads stdin line-by-line and dispatches.
  """
  @spec main() :: :ok
  def main do
    loop()
  end

  # -- Loop ------------------------------------------------------------------

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

  # -- Decode ----------------------------------------------------------------

  @spec decode(binary()) :: {:ok, map()} | :skip
  defp decode(data) do
    trimmed =
      data
      |> String.trim_trailing("\n")
      |> String.trim_trailing("\r")

    case trimmed do
      "" ->
        :skip

      _ ->
        case Jason.decode(trimmed) do
          {:ok, map} when is_map(map) -> {:ok, map}
          _ -> :skip
        end
    end
  end

  # -- Dispatch --------------------------------------------------------------

  # Request (has id + method)
  defp handle(%{"id" => id, "method" => method} = msg) do
    params = Map.get(msg, "params", %{})
    handle_request(id, method, params)
  end

  # Response to a request WE sent (has id, no method) — silently consumed
  defp handle(%{"id" => _id} = _msg) do
    :ok
  end

  # Bare notification — silently consumed (including test/emit_turn_end
  # when received outside the blocking wait in session/prompt).
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
        "agentInfo" => %{"name" => "fake-long-turn", "version" => "0.0.1-kiro011"},
        "authMethods" => []
      }
    })
  end

  defp handle_request(id, "session/new", _params) do
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
        "configOptions" => []
      }
    })
  end

  defp handle_request(id, "session/prompt", %{"sessionId" => session_id}) do
    # 1. Emit initial chunk — proves streaming works and gives the test a
    #    signal that the prompt has been received by the agent.
    write(%{
      "jsonrpc" => "2.0",
      "method" => "session/update",
      "params" => %{
        "sessionId" => session_id,
        "update" => %{
          "sessionUpdate" => "agent_message_chunk",
          "content" => [%{"type" => "text", "text" => "Working..."}]
        }
      }
    })

    # 2. Send prompt result — this unblocks KiroSession.prompt/3 on the
    #    caller side. The turn is NOT complete yet.
    write(%{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{"stopReason" => "end_turn"}
    })

    # 3. Block until the test sends `test/emit_turn_end` via
    #    KiroSession.notify/3. This makes the gap between prompt RPC result
    #    and turn_end fully deterministic — no races, no sleeps.
    wait_for_trigger()

    # 4. Emit turn_end — the ONLY signal that completes the turn.
    write(%{
      "jsonrpc" => "2.0",
      "method" => "session/update",
      "params" => %{
        "sessionId" => session_id,
        "update" => %{
          "sessionUpdate" => "turn_end",
          "reason" => "end_turn"
        }
      }
    })
  end

  defp handle_request(id, "session/prompt", _params) do
    # Prompt without sessionId — still respond for robustness, but no
    # blocking or turn_end emission.
    write(%{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{"stopReason" => "end_turn"}
    })
  end

  defp handle_request(id, _method, _params) do
    write(%{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => -32_601, "message" => "Method not found"}
    })
  end

  # -- Trigger waiting --------------------------------------------------------

  # Reads stdin until a `test/emit_turn_end` notification arrives.
  # Other inbound messages are silently consumed — this agent exists
  # solely for the kiro-011 regression test.
  @spec wait_for_trigger() :: :ok | :eof
  defp wait_for_trigger do
    case IO.read(:stdio, :line) do
      :eof ->
        :eof

      {:error, _} ->
        :eof

      data when is_binary(data) ->
        case decode(data) do
          {:ok, %{"method" => "test/emit_turn_end"}} ->
            :ok

          _other ->
            wait_for_trigger()
        end
    end
  end

  # -- IO --------------------------------------------------------------------

  @spec write(map()) :: :ok
  defp write(map) do
    line = Jason.encode!(map) <> "\n"
    IO.binwrite(:standard_io, line)
    :ok
  end
end
