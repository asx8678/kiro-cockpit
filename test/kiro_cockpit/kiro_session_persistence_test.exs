defmodule KiroCockpit.KiroSessionPersistenceTest do
  @moduledoc """
  Integration tests verifying that KiroSession correctly persists inbound
  and outbound ACP messages to EventStore when `persist_messages: true,
          auto_callbacks: false`.

  These tests exercise the full session lifecycle against a real subprocess
  (FakeLifecycleAgent for inbound flows; FakeAgent in `cancel` scenario
  for outbound notification persistence) and then query EventStore to
  verify `message_type` and `rpc_id` are recorded correctly.
  """

  use KiroCockpit.DataCase, async: false

  alias KiroCockpit.EventStore
  alias KiroCockpit.KiroSession
  alias KiroCockpit.KiroSession.StreamEvent

  @fake_agent_entry ~s|KiroCockpit.Test.Acp.FakeLifecycleAgent.main()|
  @fake_acp_agent_entry ~s|KiroCockpit.Test.Acp.FakeAgent.main()|

  setup do
    elixir_path = System.find_executable("elixir") || flunk("elixir not on PATH")

    ebin_dirs =
      Path.wildcard(Path.expand("_build/#{Mix.env()}/lib/*/ebin", File.cwd!()))

    args = Enum.flat_map(ebin_dirs, fn dir -> ["-pa", dir] end) ++ ["-e", @fake_agent_entry]

    cancel_args =
      Enum.flat_map(ebin_dirs, fn dir -> ["-pa", dir] end) ++
        ["-e", @fake_acp_agent_entry]

    {:ok, %{elixir: elixir_path, args: args, cancel_args: cancel_args}}
  end

  describe "inbound request persistence" do
    setup %{elixir: elixir, args: args} do
      {:ok, session} =
        KiroSession.start_link(
          executable: elixir,
          args: args,
          subscriber: self(),
          persist_messages: true,
          auto_callbacks: false,
          test_bypass: true
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

  # -- Cancel notification persistence (kiro-1rd Shepherd MUST fix) --------

  describe "outbound cancel persistence" do
    setup %{elixir: elixir, cancel_args: cancel_args} do
      {:ok, session} =
        KiroSession.start_link(
          executable: elixir,
          args: cancel_args,
          env: [{"FAKE_ACP_SCENARIO", "cancel"}],
          subscriber: self(),
          persist_messages: true,
          auto_callbacks: false,
          test_bypass: true
        )

      assert {:ok, _} = KiroSession.initialize(session)

      cwd = File.cwd!()
      assert {:ok, result} = KiroSession.new_session(session, cwd)
      session_id = result["sessionId"]

      on_exit(fn -> safe_stop(session) end)
      {:ok, %{session: session, session_id: session_id}}
    end

    test "persisted session/cancel is message_type \"notification\" with nil rpc_id",
         %{session: session, session_id: session_id} do
      # Issue a prompt; the cancel scenario emits one chunk and then
      # blocks reading stdin until session/cancel arrives.
      task = Task.async(fn -> KiroSession.prompt(session, "long-running") end)

      # Wait for the initial chunk so the agent is in its blocking read.
      assert_receive {:kiro_stream_event, ^session, %StreamEvent{kind: :agent_message_chunk}},
                     2_000

      # Trigger the cancel — this is what we're persisting.
      assert :ok = KiroSession.cancel(session)

      # Let the prompt complete so the session shuts down cleanly.
      assert {:ok, %{"stopReason" => "cancelled"}} = Task.await(task, 5_000)

      # Query the persisted outbound cancel.
      cancels =
        EventStore.list_acp_messages(session_id,
          direction: "client_to_agent",
          method: "session/cancel"
        )

      assert length(cancels) == 1, "expected exactly one persisted cancel"
      cancel = hd(cancels)

      # The MUST fix: notifications must be persisted as notifications,
      # not as requests with a synthetic rpc_id.
      assert cancel.message_type == "notification",
             "session/cancel must be persisted as notification (got: #{inspect(cancel.message_type)})"

      assert cancel.rpc_id == nil,
             "notification rpc_id must be nil (got: #{inspect(cancel.rpc_id)})"

      assert cancel.method == "session/cancel"
      assert cancel.direction == "client_to_agent"

      # The persisted envelope itself must be a JSON-RPC notification
      # (no `id`).
      payload = cancel.raw_payload
      assert payload["jsonrpc"] == "2.0"
      assert payload["method"] == "session/cancel"
      assert payload["params"]["sessionId"] == session_id

      refute Map.has_key?(payload, "id"),
             "notification envelope must not have an `id` (got: #{inspect(payload)})"
    end
  end

  defp safe_stop(pid) do
    if Process.alive?(pid), do: KiroSession.stop(pid)
  catch
    :exit, _ -> :ok
  end

  # -- Outbound request persistence with real IDs (MUST FIX 1) ---------------

  describe "outbound request persistence with real assigned IDs" do
    setup %{elixir: elixir, args: args} do
      {:ok, session} =
        KiroSession.start_link(
          executable: elixir,
          args: args,
          subscriber: self(),
          persist_messages: true,
          auto_callbacks: false,
          test_bypass: true
        )

      assert {:ok, _} = KiroSession.initialize(session)
      # Flush pending {:acp_outbound} messages so they get persisted
      # before we query EventStore. KiroSession.state/1 is a GenServer.call
      # that forces the session to process its entire mailbox first.
      _ = KiroSession.state(session)

      cwd = File.cwd!()
      assert {:ok, result} = KiroSession.new_session(session, cwd)
      _ = KiroSession.state(session)

      session_id = result["sessionId"]

      # Drain session/update from session/new
      assert_receive {:acp_notification, ^session, _}, 2_000

      on_exit(fn -> safe_stop(session) end)
      {:ok, %{session: session, session_id: session_id}}
    end

    test "persisted outbound initialize request has real rpc_id (not \"0\")" do
      # Initialize happens before session creation, so session_id is nil.
      # Query without session_id filter for initialize messages.
      requests =
        EventStore.list_acp_messages(nil,
          direction: "client_to_agent",
          message_type: "request",
          method: "initialize"
        )

      assert length(requests) >= 1, "Expected at least one persisted outbound initialize"

      request = hd(requests)
      assert request.message_type == "request"
      assert request.method == "initialize"
      assert request.direction == "client_to_agent"

      # The rpc_id must NOT be "0" — it must be the real assigned id
      refute request.rpc_id == "0",
             "outbound initialize rpc_id must not be placeholder 0 (got: #{inspect(request.rpc_id)})"

      assert request.rpc_id != nil

      # The raw_payload must have the real id
      payload = request.raw_payload
      assert payload["jsonrpc"] == "2.0"
      assert Map.has_key?(payload, "id")
      real_id = payload["id"]
      assert is_integer(real_id) and real_id > 0
    end

    test "persisted outbound session/new request has real rpc_id",
         %{session_id: session_id} do
      requests =
        EventStore.list_acp_messages(session_id,
          direction: "client_to_agent",
          message_type: "request",
          method: "session/new"
        )

      assert length(requests) >= 1
      request = hd(requests)
      refute request.rpc_id == "0"
      assert request.rpc_id != nil
    end
  end
end
