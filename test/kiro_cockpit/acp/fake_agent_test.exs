defmodule KiroCockpit.Test.Acp.FakeAgentTest do
  @moduledoc """
  Tests for KiroCockpit.Test.Acp.FakeAgent's canned ACP lifecycle scenarios.

  Spawns the FakeAgent as an external port process (same mechanism as
  PortProcessTest) and exercises each scenario:
    - normal: initialize → session/new → prompt with streaming → end_turn
    - long_turn: prompt response before turn_end update
    - callback: prompt triggers fs/read_text_file callback
    - error: prompt returns refusal stopReason

  Also tests session/load and session/set_config_option round-trips.

  Each test starts a fresh FakeAgent subprocess to avoid cross-test state
  contamination. The `FAKE_ACP_SCENARIO` env var is used to select scenarios.
  """

  use ExUnit.Case, async: false

  alias KiroCockpit.Acp.PortProcess

  @fake_agent_entry ~s|KiroCockpit.Test.Acp.FakeAgent.main()|

  # -- Helpers ---------------------------------------------------------------

  defp start_fake_agent(scenario \\ "normal") do
    elixir_path =
      System.find_executable("elixir") || flunk("elixir not on PATH; cannot run port test")

    ebin_dirs =
      Path.wildcard(Path.expand("_build/#{Mix.env()}/lib/*/ebin", File.cwd!()))

    args =
      Enum.flat_map(ebin_dirs, fn dir -> ["-pa", dir] end) ++
        ["-e", @fake_agent_entry]

    env = [{"FAKE_ACP_SCENARIO", scenario}]

    {:ok, pid} =
      PortProcess.start_link(executable: elixir_path, args: args, env: env, owner: self())

    on_exit(fn -> safe_stop(pid) end)
    pid
  end

  defp safe_stop(pid) do
    if Process.alive?(pid), do: PortProcess.stop(pid, :normal, 2_000)
  catch
    :exit, _ -> :ok
  end

  # Drain all pending notifications/requests from the agent after a request
  # that may produce side-effects. Returns the list of received messages.
  defp drain_inbox(pid, timeout \\ 500) do
    drain_inbox_acc(pid, timeout, [])
  end

  defp drain_inbox_acc(pid, timeout, acc) do
    receive do
      {:acp_notification, ^pid, msg} ->
        drain_inbox_acc(pid, timeout, [{:notification, msg} | acc])

      {:acp_request, ^pid, msg} ->
        drain_inbox_acc(pid, timeout, [{:request, msg} | acc])
    after
      timeout -> Enum.reverse(acc)
    end
  end

  # -- Lifecycle: initialize --------------------------------------------------

  describe "initialize" do
    test "returns protocolVersion, agentCapabilities, agentInfo, authMethods" do
      pid = start_fake_agent()

      assert {:ok, result} =
               PortProcess.request(pid, "initialize", %{"protocolVersion" => 1}, 5_000)

      assert result["protocolVersion"] == 1
      assert result["agentCapabilities"]["loadSession"] == true
      assert result["agentCapabilities"]["promptCapabilities"]["image"] == true
      assert result["agentCapabilities"]["promptCapabilities"]["audio"] == true
      assert result["agentCapabilities"]["promptCapabilities"]["embeddedContext"] == true
      assert result["agentCapabilities"]["mcpCapabilities"]["http"] == true
      assert result["agentCapabilities"]["mcpCapabilities"]["sse"] == true
      assert result["agentInfo"]["name"] == "fake-kiro"
      assert result["agentInfo"]["version"] == "0.0.1-test"
      assert result["authMethods"] == []
    end
  end

  # -- Lifecycle: session/new ------------------------------------------------

  describe "session/new" do
    test "returns sessionId, modes, and configOptions" do
      pid = start_fake_agent()

      assert {:ok, result} =
               PortProcess.request(pid, "session/new", %{"cwd" => "/tmp"}, 5_000)

      assert String.starts_with?(result["sessionId"], "sess_fake_")
      assert result["modes"]["currentModeId"] == "code"
      assert length(result["modes"]["availableModes"]) == 2
      assert length(result["configOptions"]) == 1
      assert hd(result["configOptions"])["id"] == "model"
    end
  end

  # -- Lifecycle: session/load ------------------------------------------------

  describe "session/load" do
    test "streams prior conversation then returns null result" do
      pid = start_fake_agent()

      # First create a session to get a sessionId
      {:ok, sn_result} = PortProcess.request(pid, "session/new", %{"cwd" => "/tmp"}, 5_000)
      session_id = sn_result["sessionId"]

      # Now load the session
      assert {:ok, result} =
               PortProcess.request(
                 pid,
                 "session/load",
                 %{"sessionId" => session_id},
                 5_000
               )

      # Result should be nil (null in JSON)
      assert result == nil

      # Should have received session/update notifications
      notifications = drain_inbox(pid)

      updates =
        for {:notification, %{method: "session/update", params: p}} <- notifications,
            do: p["update"]["sessionUpdate"]

      assert "user_message_chunk" in updates
      assert "agent_message_chunk" in updates
    end
  end

  # -- Lifecycle: session/prompt — normal scenario ----------------------------

  describe "session/prompt — normal scenario" do
    test "streams updates then returns end_turn" do
      pid = start_fake_agent("normal")

      {:ok, _} = PortProcess.request(pid, "session/new", %{"cwd" => "/tmp"}, 5_000)

      assert {:ok, result} =
               PortProcess.request(
                 pid,
                 "session/prompt",
                 %{
                   "sessionId" => "test",
                   "prompt" => [%{"type" => "text", "text" => "hi"}]
                 },
                 5_000
               )

      assert result["stopReason"] == "end_turn"

      notifications = drain_inbox(pid)

      updates =
        for {:notification, %{method: "session/update", params: p}} <- notifications,
            do: p["update"]["sessionUpdate"]

      assert "agent_message_chunk" in updates
      assert "agent_thought_chunk" in updates
    end
  end

  # -- Lifecycle: session/prompt — long_turn scenario -------------------------

  describe "session/prompt — long_turn scenario" do
    test "returns end_turn before turn_end update" do
      pid = start_fake_agent("long_turn")

      {:ok, _} = PortProcess.request(pid, "session/new", %{"cwd" => "/tmp"}, 5_000)

      assert {:ok, result} =
               PortProcess.request(
                 pid,
                 "session/prompt",
                 %{
                   "sessionId" => "test",
                   "prompt" => [%{"type" => "text", "text" => "hi"}]
                 },
                 5_000
               )

      # The prompt result arrives first with end_turn...
      assert result["stopReason"] == "end_turn"

      # ...but the turn_end update arrives AFTER the prompt response.
      # A well-behaved client must not mark the turn complete until it sees this.
      notifications = drain_inbox(pid, 1_000)

      updates =
        for {:notification, %{method: "session/update", params: p}} <- notifications,
            do: p["update"]["sessionUpdate"]

      assert "agent_message_chunk" in updates
      assert "turn_end" in updates
    end
  end

  # -- Lifecycle: session/prompt — callback scenario --------------------------

  describe "session/prompt — callback scenario" do
    test "agent sends fs/read_text_file request and waits for response before completing prompt" do
      pid = start_fake_agent("callback")

      {:ok, _} = PortProcess.request(pid, "session/new", %{"cwd" => "/tmp"}, 5_000)

      # Send session/prompt. The agent will respond with notifications
      # and then send a fs/read_text_file request. The prompt response
      # is deferred until we answer the callback.
      task =
        Task.async(fn ->
          PortProcess.request(
            pid,
            "session/prompt",
            %{
              "sessionId" => "test",
              "prompt" => [%{"type" => "text", "text" => "read a file"}]
            },
            10_000
          )
        end)

      # Give the agent time to emit notifications and the callback request.
      Process.sleep(100)

      # We should have received tool_call notifications and an fs/read_text_file request.
      assert_receive {:acp_notification, ^pid,
                      %{
                        method: "session/update",
                        params: %{"update" => %{"sessionUpdate" => "tool_call"}}
                      }},
                     2_000

      assert_receive {:acp_notification, ^pid,
                      %{
                        method: "session/update",
                        params: %{"update" => %{"sessionUpdate" => "tool_call_update"}}
                      }},
                     2_000

      assert_receive {:acp_request, ^pid,
                      %{
                        id: req_id,
                        method: "fs/read_text_file",
                        params: %{"path" => "/tmp/kiro-fake.txt"}
                      }},
                     2_000

      # Reply to the callback — this unblocks the prompt.
      :ok = PortProcess.respond(pid, req_id, %{"content" => "file contents here"})

      # Now the prompt should resolve.
      assert {:ok, result} = Task.await(task, 5_000)
      assert result["stopReason"] == "end_turn"

      # Should also get the tool_call_update (completed) notification.
      assert_receive {:acp_notification, ^pid,
                      %{
                        method: "session/update",
                        params: %{"update" => %{"sessionUpdate" => "tool_call_update"}}
                      }},
                     2_000
    end
  end

  # -- Lifecycle: session/prompt — error scenario ----------------------------

  describe "session/prompt — error scenario" do
    test "returns refusal stopReason" do
      pid = start_fake_agent("error")

      {:ok, _} = PortProcess.request(pid, "session/new", %{"cwd" => "/tmp"}, 5_000)

      assert {:ok, result} =
               PortProcess.request(
                 pid,
                 "session/prompt",
                 %{
                   "sessionId" => "test",
                   "prompt" => [%{"type" => "text", "text" => "bad request"}]
                 },
                 5_000
               )

      assert result["stopReason"] == "refusal"

      notifications = drain_inbox(pid)

      updates =
        for {:notification, %{method: "session/update", params: p}} <- notifications,
            do: p["update"]["sessionUpdate"]

      assert "agent_message_chunk" in updates
    end
  end

  # -- session/set_config_option ----------------------------------------------

  describe "session/set_config_option" do
    test "updates config value and returns updated configOptions" do
      pid = start_fake_agent()

      assert {:ok, result} =
               PortProcess.request(
                 pid,
                 "session/set_config_option",
                 %{
                   "sessionId" => "test",
                   "configId" => "model",
                   "value" => "claude-opus-4-7"
                 },
                 5_000
               )

      assert length(result["configOptions"]) == 1
      assert hd(result["configOptions"])["currentValue"] == "claude-opus-4-7"
    end
  end

  # -- session/set_mode -------------------------------------------------------

  describe "session/set_mode" do
    test "returns updated mode" do
      pid = start_fake_agent()

      assert {:ok, result} =
               PortProcess.request(
                 pid,
                 "session/set_mode",
                 %{"sessionId" => "test", "modeId" => "ask"},
                 5_000
               )

      assert result["currentModeId"] == "ask"
    end
  end

  # -- Existing transport commands still work ---------------------------------

  describe "transport commands (backward compat)" do
    test "ping still works with lifecycle agent" do
      pid = start_fake_agent()

      assert {:ok, %{"pong" => true}} = PortProcess.request(pid, "ping", %{}, 5_000)

      # Drain the side effects from ping (notification + fs/read request).
      assert_receive {:acp_notification, ^pid, %{method: "session/update"}}, 2_000
      assert_receive {:acp_request, ^pid, %{id: req_id, method: "fs/read"}}, 2_000
      :ok = PortProcess.respond(pid, req_id, %{"contents" => "hello"})
      assert_receive {:acp_notification, ^pid, %{method: "session/done"}}, 2_000
    end

    test "echo still works" do
      pid = start_fake_agent()
      assert {:ok, %{"x" => 42}} = PortProcess.request(pid, "echo", %{"x" => 42}, 5_000)
    end

    test "boom still works" do
      pid = start_fake_agent()

      assert {:error, {:rpc_error, %{code: -32_000, message: "boom"}}} =
               PortProcess.request(pid, "boom", %{}, 5_000)
    end

    test "silent still works" do
      pid = start_fake_agent()
      assert {:error, :timeout} = PortProcess.request(pid, "silent", %{}, 100)
    end
  end
end
