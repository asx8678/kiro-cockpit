defmodule KiroCockpit.Test.Acp.FakeAgent do
  @moduledoc """
  A scripted JSON-RPC 2.0 ACP agent for deterministic test scenarios.

  Reads newline-delimited JSON-RPC 2.0 messages on stdin and writes scripted
  replies to stdout. Lives inside the Elixir test runtime so we don't need a
  Python dependency.

  ## Entry point

      elixir -pa <ebin paths> -e "KiroCockpit.Test.Acp.FakeAgent.main()"

  ## Scenario selection

  The agent supports multiple canned scenarios. The active scenario is chosen
  via the `FAKE_ACP_SCENARIO` environment variable (defaults to `"normal"`).

  | Scenario     | Env value    | Behaviour                                                                      |
  | ------------ | ------------ | ------------------------------------------------------------------------------ |
  | `:normal`    | `"normal"`   | Full happy-path lifecycle: initialize → session/new → prompt with streaming updates → end_turn |
  | `:long_turn` | `"long_turn"`| Prompt returns `end_turn` *before* final `session/update` with turn_end (for kiro-011)        |
  | `:callback`  | `"callback"` | Prompt triggers `fs/read_text_file` callback to client, waits for reply, then completes        |
  | `:error`     | `"error"`    | Prompt returns a `refusal` stopReason                                          |

  The scenario is read once at startup and held for the process lifetime.
  Switching scenarios between runs is as simple as setting the env var.

  ## Transport-level commands (unchanged from v1)

  These are always available regardless of scenario:

    * `ping`    → reply `{"pong": true}`, emit `session/update`, send `fs/read`
                  request to client, wait for response, emit `session/done`.
    * `echo`    → reply with the same params.
    * `silent`  → consume the request, emit nothing (timeout test).
    * `boom`    → reply with RPC error -32000.
    * Any other → `-32601 Method not found`.

  ## ACP lifecycle commands

    * `initialize`              → returns protocolVersion, agentCapabilities, agentInfo, authMethods.
    * `session/new`             → returns sessionId, modes, configOptions.
    * `session/load`            → streams prior conversation via `session/update` notifications,
                                   then returns null result.
    * `session/prompt`          → behaviour depends on active scenario (see table above).
    * `session/set_mode`        → returns updated mode state.
    * `session/set_config_option` → returns updated config state.

  ## Wire protocol

  Newline-delimited JSON-RPC 2.0 over stdio. Each message is a single JSON
  object terminated by `\\n`. The BEAM's IO subsystem does not block-buffer
  pipe stdout the way C stdio does, so each `IO.binwrite` call surfaces to
  the parent's port driver immediately.

  ## Why a compiled module

  `elixirc_paths(:test)` already compiles `test/support/`, so `KiroCockpit`
  and its deps (notably `Jason`) are on the BEAM code path. The port test
  spawns this via `elixir -pa <ebin paths> -e "<entry>"` — no script parsing
  overhead, no Mix.install, no JSON micro-encoder.
  """

  # -- Scenario config -------------------------------------------------------

  @scenarios %{
    "normal" => :normal,
    "long_turn" => :long_turn,
    "callback" => :callback,
    "error" => :error
  }

  @default_scenario :normal

  # IDs for agent → client requests (high numbers to avoid collision with
  # client → agent request IDs which start at 1).
  @fs_read_id 9001
  @fs_read_text_file_id 9002

  @default_config_options [
    %{
      "id" => "model",
      "name" => "Model",
      "category" => "model",
      "type" => "select",
      "currentValue" => "claude-sonnet-4-6",
      "options" => [
        %{"value" => "claude-sonnet-4-6", "name" => "Sonnet 4.6", "description" => "Balanced"},
        %{"value" => "claude-opus-4-7", "name" => "Opus 4.7", "description" => "Most capable"}
      ]
    }
  ]

  # -- State carried across the loop -----------------------------------------

  defstruct scenario: @default_scenario,
            session_id: nil,
            current_mode: "code",
            config_options: @default_config_options,
            pending_prompt_id: nil

  # -- Public entry point ----------------------------------------------------

  @doc """
  Entry point for the subprocess. Reads stdin line-by-line and dispatches.

  Reads the `FAKE_ACP_SCENARIO` env var to select the canned behaviour.
  """
  @spec main() :: :ok
  def main do
    scenario = read_scenario()
    state = %__MODULE__{scenario: scenario}
    loop(state)
  end

  # -- Scenario reader -------------------------------------------------------

  defp read_scenario do
    env = System.get_env("FAKE_ACP_SCENARIO") || "normal"

    case Map.get(@scenarios, env) do
      nil -> @default_scenario
      scenario -> scenario
    end
  end

  # -- Loop ------------------------------------------------------------------

  defp loop(state) do
    case IO.read(:stdio, :line) do
      :eof ->
        :ok

      {:error, _} ->
        :ok

      data when is_binary(data) ->
        case decode(data) do
          {:ok, msg} ->
            {actions, state} = handle(msg, state)
            emit_actions(actions)
            loop(state)

          :skip ->
            loop(state)
        end
    end
  end

  # -- Decode ----------------------------------------------------------------

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

  # -- Handle / dispatch -----------------------------------------------------

  # Request (has id + method)
  defp handle(%{"id" => id, "method" => method} = msg, state) do
    params = Map.get(msg, "params", %{})
    handle_request(id, method, params, state)
  end

  # Response to a request WE sent (has id, no method, has result or error)
  defp handle(%{"id" => id} = msg, state)
       when is_integer(id) or is_binary(id) do
    handle_response(id, msg, state)
  end

  # Bare notification — ignored
  defp handle(%{"method" => _method}, state) do
    {[], state}
  end

  defp handle(_other, state) do
    {[], state}
  end

  # -- Responses to our agent→client requests --------------------------------

  # Ping scenario: got the client's reply to our `fs/read` request.
  # Emit a final session/done notification with the echoed contents.
  defp handle_response(@fs_read_id, msg, state) do
    contents =
      case msg do
        %{"result" => %{"contents" => c}} -> c
        %{"result" => %{"content" => c}} -> c
        _ -> nil
      end

    action = notify("session/done", %{"echoed" => contents})
    {[action], state}
  end

  # Callback scenario: got the client's reply to our `fs/read_text_file`
  # request during an active prompt. Emit tool_call_update, then finally
  # respond to the pending session/prompt request.
  defp handle_response(@fs_read_text_file_id, msg, state) do
    file_content =
      case msg do
        %{"result" => %{"content" => c}} -> c
        _ -> "unknown"
      end

    tool_update =
      notify("session/update", %{
        "sessionId" => state.session_id,
        "update" => %{
          "sessionUpdate" => "tool_call_update",
          "toolCallId" => "call_read_001",
          "status" => "completed",
          "content" => [
            %{"type" => "content", "content" => %{"type" => "text", "text" => file_content}}
          ]
        }
      })

    prompt_reply = success_response(state.pending_prompt_id, %{"stopReason" => "end_turn"})
    state = %{state | pending_prompt_id: nil}

    {[tool_update, prompt_reply], state}
  end

  defp handle_response(_id, _msg, state) do
    {[], state}
  end

  # -- Request handling (all handle_request/4 clauses grouped) ---------------

  # Transport-level commands (always available, scenario-independent)

  defp handle_request(id, "ping", _params, state) do
    actions = [
      success_response(id, %{"pong" => true}),
      notify("session/update", %{"phase" => "thinking"}),
      request(@fs_read_id, "fs/read", %{
        "sessionId" => state.session_id,
        "path" => "/tmp/kiro-fake.txt"
      })
    ]

    {actions, state}
  end

  defp handle_request(id, "echo", params, state) do
    {[success_response(id, params)], state}
  end

  defp handle_request(_id, "silent", _params, state) do
    {[], state}
  end

  defp handle_request(id, "boom", _params, state) do
    action = error_response(id, -32_000, "boom", %{"trace" => "synthetic"})
    {[action], state}
  end

  # ACP lifecycle: initialize

  defp handle_request(id, "initialize", _params, state) do
    result = %{
      "protocolVersion" => 1,
      "agentCapabilities" => %{
        "loadSession" => true,
        "promptCapabilities" => %{
          "image" => true,
          "audio" => true,
          "embeddedContext" => true
        },
        "mcpCapabilities" => %{
          "http" => true,
          "sse" => true
        }
      },
      "agentInfo" => %{
        "name" => "fake-kiro",
        "version" => "0.0.1-test"
      },
      "authMethods" => []
    }

    {[success_response(id, result)], state}
  end

  # ACP lifecycle: session/new

  defp handle_request(id, "session/new", _params, state) do
    session_id = "sess_fake_" <> random_suffix()

    result = %{
      "sessionId" => session_id,
      "modes" => %{
        "currentModeId" => state.current_mode,
        "availableModes" => [
          %{"id" => "ask", "name" => "Ask", "description" => "Ask before editing"},
          %{"id" => "code", "name" => "Code", "description" => "Write/modify with full tools"}
        ]
      },
      "configOptions" => state.config_options
    }

    state = %{state | session_id: session_id}

    {[success_response(id, result)], state}
  end

  # ACP lifecycle: session/load

  defp handle_request(id, "session/load", params, state) do
    # Stream prior conversation via session/update notifications, then
    # return null result. Per ACP spec §5, session/load result is null but
    # the agent streams the prior conversation back first.
    session_id = Map.get(params, "sessionId", state.session_id)

    notifications = [
      notify("session/update", %{
        "sessionId" => session_id,
        "update" => %{
          "sessionUpdate" => "user_message_chunk",
          "content" => [%{"type" => "text", "text" => "previous user message"}]
        }
      }),
      notify("session/update", %{
        "sessionId" => session_id,
        "update" => %{
          "sessionUpdate" => "agent_message_chunk",
          "content" => [%{"type" => "text", "text" => "previous assistant reply"}]
        }
      })
    ]

    response = success_response(id, nil)
    state = %{state | session_id: session_id}

    {notifications ++ [response], state}
  end

  # ACP lifecycle: session/prompt (dispatches to scenario helpers)

  defp handle_request(id, "session/prompt", params, state) do
    session_id = Map.get(params, "sessionId", state.session_id)

    case state.scenario do
      :normal -> handle_prompt_normal(id, session_id, state)
      :long_turn -> handle_prompt_long_turn(id, session_id, state)
      :callback -> handle_prompt_callback(id, session_id, state)
      :error -> handle_prompt_error(id, session_id, state)
    end
  end

  # ACP lifecycle: session/set_mode

  defp handle_request(id, "session/set_mode", params, state) do
    mode_id = Map.get(params, "modeId", "code")
    state = %{state | current_mode: mode_id}

    result = %{
      "currentModeId" => mode_id,
      "availableModes" => [
        %{"id" => "ask", "name" => "Ask", "description" => "Ask before editing"},
        %{"id" => "code", "name" => "Code", "description" => "Write/modify with full tools"}
      ]
    }

    {[success_response(id, result)], state}
  end

  # ACP lifecycle: session/set_config_option

  defp handle_request(id, "session/set_config_option", params, state) do
    config_id = Map.get(params, "configId", "model")
    value = Map.get(params, "value")

    config_options =
      Enum.map(state.config_options, fn opt ->
        if opt["id"] == config_id do
          %{opt | "currentValue" => value}
        else
          opt
        end
      end)

    state = %{state | config_options: config_options}
    {[success_response(id, %{"configOptions" => config_options})], state}
  end

  # Catch-all: unknown method → -32601
  # Must be the LAST handle_request/4 clause.
  defp handle_request(id, _method, _params, state) do
    {[error_response(id, -32_601, "Method not found")], state}
  end

  # -- Prompt scenario helpers (separate from handle_request/4 group) ---------

  # Normal: stream some updates, then end_turn
  defp handle_prompt_normal(id, session_id, state) do
    actions = [
      notify("session/update", %{
        "sessionId" => session_id,
        "update" => %{
          "sessionUpdate" => "agent_message_chunk",
          "content" => [%{"type" => "text", "text" => "Hello from fake agent!"}]
        }
      }),
      notify("session/update", %{
        "sessionId" => session_id,
        "update" => %{
          "sessionUpdate" => "agent_thought_chunk",
          "content" => [%{"type" => "text", "text" => "thinking..."}]
        }
      }),
      notify("session/update", %{
        "sessionId" => session_id,
        "update" => %{
          "sessionUpdate" => "agent_message_chunk",
          "content" => [%{"type" => "text", "text" => " Here is my answer."}]
        }
      }),
      success_response(id, %{"stopReason" => "end_turn"})
    ]

    {actions, state}
  end

  # Long turn: the session/prompt response arrives BEFORE the final turn_end
  # session/update. This exercises the case where the prompt result does NOT
  # mean the turn is fully complete — the client must wait for turn_end.
  # See kiro-011 / plan2.md §1026: "session/prompt response != turn complete".
  defp handle_prompt_long_turn(id, session_id, state) do
    actions = [
      notify("session/update", %{
        "sessionId" => session_id,
        "update" => %{
          "sessionUpdate" => "agent_message_chunk",
          "content" => [%{"type" => "text", "text" => "Working on it..."}]
        }
      }),
      # The prompt result comes early — the turn is NOT over yet.
      success_response(id, %{"stopReason" => "end_turn"}),
      # But the turn_end update arrives AFTER the prompt response.
      # A well-behaved client must not mark the turn complete until it
      # sees this update.
      notify("session/update", %{
        "sessionId" => session_id,
        "update" => %{
          "sessionUpdate" => "agent_message_chunk",
          "content" => [%{"type" => "text", "text" => " One more thing."}]
        }
      }),
      notify("session/update", %{
        "sessionId" => session_id,
        "update" => %{
          "sessionUpdate" => "turn_end",
          "reason" => "end_turn"
        }
      })
    ]

    {actions, state}
  end

  # Callback: the agent requests fs/read_text_file from the client during a
  # prompt. The prompt response is deferred until the agent receives the
  # client's response. This tests the bidirectional callback path during
  # active prompting — the session/prompt request is "in flight" and the
  # agent issues a callback before replying.
  defp handle_prompt_callback(id, session_id, state) do
    actions = [
      # Announce a tool call
      notify("session/update", %{
        "sessionId" => session_id,
        "update" => %{
          "sessionUpdate" => "tool_call",
          "toolCallId" => "call_read_001",
          "title" => "Read file",
          "kind" => "read",
          "status" => "pending"
        }
      }),
      # Update to in_progress
      notify("session/update", %{
        "sessionId" => session_id,
        "update" => %{
          "sessionUpdate" => "tool_call_update",
          "toolCallId" => "call_read_001",
          "status" => "in_progress"
        }
      }),
      # Send the fs/read_text_file request to the client.
      # We DON'T send the prompt response yet — it's deferred.
      # When the client replies, our handle_response/3 for
      # @fs_read_text_file_id fires and sends the prompt result.
      request(@fs_read_text_file_id, "fs/read_text_file", %{
        "sessionId" => session_id,
        "path" => "/tmp/kiro-fake.txt"
      })
    ]

    state = %{state | pending_prompt_id: id}

    {actions, state}
  end

  # Error/refusal: the agent refuses to complete the prompt.
  defp handle_prompt_error(id, session_id, state) do
    actions = [
      notify("session/update", %{
        "sessionId" => session_id,
        "update" => %{
          "sessionUpdate" => "agent_message_chunk",
          "content" => [%{"type" => "text", "text" => "I cannot comply with that request."}]
        }
      }),
      success_response(id, %{"stopReason" => "refusal"})
    ]

    {actions, state}
  end

  # -- Action helpers --------------------------------------------------------

  defp success_response(id, result) do
    %{"jsonrpc" => "2.0", "id" => id, "result" => result}
  end

  defp error_response(id, code, message, data \\ nil) do
    error =
      case data do
        nil -> %{"code" => code, "message" => message}
        _ -> %{"code" => code, "message" => message, "data" => data}
      end

    %{"jsonrpc" => "2.0", "id" => id, "error" => error}
  end

  defp notify(method, params) do
    %{"jsonrpc" => "2.0", "method" => method, "params" => params}
  end

  defp request(id, method, params) do
    %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
  end

  # -- IO --------------------------------------------------------------------

  @spec emit_actions([map()]) :: :ok
  defp emit_actions(actions) do
    Enum.each(actions, &write/1)
  end

  @spec write(map()) :: :ok
  defp write(map) do
    line = Jason.encode!(map) <> "\n"
    IO.binwrite(:standard_io, line)
    :ok
  end

  # -- Misc ------------------------------------------------------------------

  defp random_suffix do
    :crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)
  end
end
