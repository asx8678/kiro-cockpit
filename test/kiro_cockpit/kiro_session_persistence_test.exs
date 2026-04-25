defmodule KiroCockpit.KiroSessionPersistenceTest do
  @moduledoc """
  Integration tests verifying that KiroSession correctly persists inbound
  ACP messages to EventStore when `persist_messages: true`.

  These tests exercise the full session lifecycle against a real subprocess
  (FakeLifecycleAgent) and then query EventStore to verify message_type and
  rpc_id are recorded correctly.
  """

  use KiroCockpit.DataCase, async: false

  alias KiroCockpit.EventStore
  alias KiroCockpit.KiroSession

  @fake_agent_entry ~s|KiroCockpit.Test.Acp.FakeLifecycleAgent.main()|

  setup do
    elixir_path = System.find_executable("elixir") || flunk("elixir not on PATH")

    ebin_dirs =
      Path.wildcard(Path.expand("_build/#{Mix.env()}/lib/*/ebin", File.cwd!()))

    args = Enum.flat_map(ebin_dirs, fn dir -> ["-pa", dir] end) ++ ["-e", @fake_agent_entry]

    {:ok, %{elixir: elixir_path, args: args}}
  end

  describe "inbound request persistence" do
    setup %{elixir: elixir, args: args} do
      {:ok, session} =
        KiroSession.start_link(
          executable: elixir,
          args: args,
          subscriber: self(),
          persist_messages: true
        )

      assert {:ok, _} = KiroSession.initialize(session)

      cwd = File.cwd!()
      assert {:ok, result} = KiroSession.new_session(session, cwd)
      session_id = result["sessionId"]

      # Drain session/update from session/new
      assert_receive {:acp_notification, ^session, _}, 2_000

      on_exit(fn -> safe_stop(session) end)
      {:ok, %{session: session, session_id: session_id}}
    end

    test "inbound request is persisted as message_type \"request\" with rpc_id",
         %{session: session, session_id: session_id} do
      task =
        Task.async(fn ->
          KiroSession.prompt(session, "test request persistence")
        end)

      # Drain notification
      assert_receive {:acp_notification, ^session, _}, 2_000

      # Receive the fs/read_text_file request from the agent
      assert_receive {:acp_request, ^session, %{id: req_id, method: "fs/read_text_file"}}, 2_000

      # Respond so the agent can complete the prompt
      :ok = KiroSession.respond(session, req_id, %{"content" => "file contents"})

      assert {:ok, _} = Task.await(task, 5_000)

      # Query EventStore for the inbound request
      requests =
        EventStore.list_acp_messages(session_id,
          direction: "agent_to_client",
          message_type: "request",
          method: "fs/read_text_file"
        )

      assert length(requests) >= 1, "Expected at least one persisted inbound request"

      request = hd(requests)
      assert request.message_type == "request"
      assert request.method == "fs/read_text_file"
      assert request.rpc_id == to_string(req_id)
      assert request.direction == "agent_to_client"

      # The raw_payload must be a proper JSON-RPC request envelope with "id"
      payload = request.raw_payload
      assert payload["jsonrpc"] == "2.0"
      assert Map.has_key?(payload, "id")
      assert payload["method"] == "fs/read_text_file"
      assert Map.has_key?(payload, "params")
    end

    test "inbound notification is persisted as message_type \"notification\" without rpc_id",
         %{session: session, session_id: session_id} do
      task =
        Task.async(fn ->
          KiroSession.prompt(session, "test notification persistence")
        end)

      # Drain notification and request
      assert_receive {:acp_notification, ^session, %{method: "session/update"}}, 2_000
      assert_receive {:acp_request, ^session, %{id: req_id}}, 2_000
      :ok = KiroSession.respond(session, req_id, %{"content" => "ok"})

      assert {:ok, _} = Task.await(task, 5_000)

      # Query EventStore for the inbound notification
      notifications =
        EventStore.list_acp_messages(session_id,
          direction: "agent_to_client",
          message_type: "notification",
          method: "session/update"
        )

      assert length(notifications) >= 1, "Expected at least one persisted inbound notification"

      notification = hd(notifications)
      assert notification.message_type == "notification"
      assert notification.method == "session/update"
      assert notification.rpc_id == nil
      assert notification.direction == "agent_to_client"

      # The raw_payload must be a proper JSON-RPC notification envelope (no "id")
      payload = notification.raw_payload
      assert payload["jsonrpc"] == "2.0"
      assert Map.has_key?(payload, "method")
      refute Map.has_key?(payload, "id")
    end
  end

  defp safe_stop(pid) do
    if Process.alive?(pid), do: KiroSession.stop(pid)
  catch
    :exit, _ -> :ok
  end
end
