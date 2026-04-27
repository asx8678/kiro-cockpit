defmodule KiroCockpit.Acp.InboundResponsePersistenceTest do
  @moduledoc """
  Runtime-level regression tests proving inbound JSON-RPC responses/errors
  are persisted as raw_acp_message and Bronze acp_response by KiroSession.

  These tests exercise the real PortProcess → KiroSession path:
    1. PortProcess resolves the pending request (existing behavior preserved)
    2. PortProcess notifies owner via {:acp_inbound_response, port_pid, raw_msg}
    3. KiroSession persists raw_acp_message (EventStore) and Bronze acp_response

  Covers Shepherd critic fix #2 for §35 Bronze ACP capture.
  """

  use KiroCockpit.DataCase, async: false

  alias KiroCockpit.Acp.PortProcess
  alias KiroCockpit.EventStore
  alias KiroCockpit.Swarm.DataPipeline.BronzeAcp

  @fake_agent_entry ~s|KiroCockpit.Test.Acp.FakeAgent.main()|

  setup do
    elixir_path =
      System.find_executable("elixir") || flunk("elixir not on PATH; cannot run port test")

    ebin_dirs =
      Path.wildcard(Path.expand("_build/#{Mix.env()}/lib/*/ebin", File.cwd!()))

    args = Enum.flat_map(ebin_dirs, fn dir -> ["-pa", dir] end) ++ ["-e", @fake_agent_entry]

    {:ok, %{elixir: elixir_path, args: args}}
  end

  defp safe_stop(pid) do
    if Process.alive?(pid) do
      try do
        PortProcess.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end
  end

  defp with_env(key, value, fun) do
    original = Application.get_env(:kiro_cockpit, key, value)
    Application.put_env(:kiro_cockpit, key, value)

    try do
      fun.()
    after
      Application.put_env(:kiro_cockpit, key, original)
    end
  end

  describe "PortProcess inbound response notification" do
    setup %{elixir: elixir, args: args} do
      {:ok, pid} = PortProcess.start_link(executable: elixir, args: args, owner: self())
      on_exit(fn -> safe_stop(pid) end)
      {:ok, %{pid: pid}}
    end

    test "owner receives {:acp_inbound_response, port_pid, raw_msg} on JSON-RPC response",
         %{pid: pid} do
      # Send a ping request; the fake agent responds with a JSON-RPC result
      assert {:ok, %{}} = PortProcess.request(pid, "ping", %{}, 5_000)

      # The owner must receive the raw inbound response message
      assert_receive {:acp_inbound_response, ^pid, raw_msg}, 2_000
      assert is_map(raw_msg)
      assert raw_msg["jsonrpc"] == "2.0"
      # Response has an id and result (or error)
      assert Map.has_key?(raw_msg, "id")
    end

    test "owner receives {:acp_inbound_response, port_pid, raw_msg} on JSON-RPC error response",
         %{pid: pid} do
      # Send a boom request; the fake agent responds with a JSON-RPC error
      assert {:error, {:rpc_error, _}} = PortProcess.request(pid, "boom", %{}, 5_000)

      # The owner must receive the raw inbound error response
      assert_receive {:acp_inbound_response, ^pid, raw_msg}, 2_000
      assert is_map(raw_msg)
      assert raw_msg["jsonrpc"] == "2.0"
      assert Map.has_key?(raw_msg, "error")
    end

    test "request resolution still works after inbound response notification", %{pid: pid} do
      # Verify the existing request/response flow is not broken
      assert {:ok, %{"pong" => true}} = PortProcess.request(pid, "ping", %{}, 5_000)
      assert {:ok, %{"x" => 1}} = PortProcess.request(pid, "echo", %{"x" => 1}, 5_000)

      # Both should have generated inbound_response messages
      assert_receive {:acp_inbound_response, ^pid, _}, 1_000
      assert_receive {:acp_inbound_response, ^pid, _}, 1_000
    end

    test "inbound response carries the exact raw JSON-RPC payload", %{pid: pid} do
      assert {:ok, %{"x" => 42}} = PortProcess.request(pid, "echo", %{"x" => 42}, 5_000)

      assert_receive {:acp_inbound_response, ^pid, raw_msg}, 2_000
      # The raw payload must contain the exact JSON-RPC id assigned by PortProcess
      assert is_integer(raw_msg["id"]) or is_binary(raw_msg["id"])
      assert Map.has_key?(raw_msg, "result")
    end
  end

  describe "KiroSession inbound response persistence (full runtime path)" do
    setup %{elixir: elixir, args: args} do
      # Start a KiroSession with persistence enabled
      session_id = "sess_inbound_persist_#{System.unique_integer([:positive])}"

      {:ok, session_pid} =
        KiroCockpit.KiroSession.start_link(
          executable: elixir,
          args: args,
          subscriber: self(),
          persist_messages: true
        )

      on_exit(fn ->
        if Process.alive?(session_pid) do
          try do
            KiroCockpit.KiroSession.stop(session_pid)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      {:ok, %{session_pid: session_pid, session_id: session_id}}
    end

    test "inbound JSON-RPC response is persisted as raw_acp_message and Bronze acp_response",
         %{session_pid: session_pid} do
      with_env(:bronze_acp_capture_enabled, true, fn ->
        # Full session lifecycle to get a real session_id
        assert {:ok, _} = KiroCockpit.KiroSession.initialize(session_pid, timeout: 10_000)

        tmp_dir = System.tmp_dir!()

        assert {:ok, _} =
                 KiroCockpit.KiroSession.new_session(session_pid, tmp_dir, timeout: 10_000)

        # Read the real session_id
        state = KiroCockpit.KiroSession.state(session_pid)
        sid = state.session_id
        assert sid != nil

        # Wait briefly for async persistence to complete
        Process.sleep(150)

        # There should be raw_acp_message rows for the session
        raw_msgs = EventStore.list_acp_messages(sid)
        assert [_ | _] = raw_msgs

        # At least one inbound response should exist (initialize, session/new, etc.)
        responses =
          Enum.filter(raw_msgs, fn m ->
            m.direction == "agent_to_client" and m.message_type in ["response", "error"]
          end)

        assert [_ | _] = responses

        # Bronze acp_request/acp_response events should also exist with wire directions preserved
        acp_events = BronzeAcp.list_acp_events(sid)

        request_events = Enum.filter(acp_events, &(&1.event_type == "acp_request"))

        assert Enum.any?(request_events, fn event ->
                 event.hook_results["direction"] == "client_to_agent"
               end)

        response_events = Enum.filter(acp_events, &(&1.event_type == "acp_response"))

        assert Enum.any?(response_events, fn event ->
                 event.hook_results["direction"] == "agent_to_client"
               end)
      end)
    end
  end

  # Regression test proving KiroSession persists Bronze ACP events even when
  # :bronze_acp_capture_enabled is false, as long as persist_messages is true.
  #
  # The flag is a reporting/test-compatibility toggle, NOT a runtime kill
  # switch. KiroSession.persist_bronze_acp/3 only checks persist_messages;
  # it deliberately does NOT consult DataPipeline.acp_capture_enabled?/0.
  # See KiroSession lines ~1721-1724 for the design rationale.
  describe "Bronze ACP persistence with flag disabled (kiro-3nr regression)" do

    setup %{elixir: elixir, args: args} do
      session_id = "sess_flag_disabled_#{System.unique_integer([:positive])}"

      {:ok, session_pid} =
        KiroCockpit.KiroSession.start_link(
          executable: elixir,
          args: args,
          subscriber: self(),
          persist_messages: true
        )

      on_exit(fn ->
        if Process.alive?(session_pid) do
          try do
            KiroCockpit.KiroSession.stop(session_pid)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      {:ok, %{session_pid: session_pid, session_id: session_id}}
    end

    test "Bronze ACP events are persisted even when :bronze_acp_capture_enabled is false",
         %{session_pid: session_pid} do
      with_env(:bronze_acp_capture_enabled, false, fn ->
        # The reporting flag must read as false
        refute KiroCockpit.Swarm.DataPipeline.acp_capture_enabled?()

        # Full session lifecycle
        assert {:ok, _} = KiroCockpit.KiroSession.initialize(session_pid, timeout: 10_000)

        tmp_dir = System.tmp_dir!()

        assert {:ok, _} =
                 KiroCockpit.KiroSession.new_session(session_pid, tmp_dir, timeout: 10_000)

        state = KiroCockpit.KiroSession.state(session_pid)
        sid = state.session_id
        assert sid != nil

        # Wait briefly for async persistence to complete
        Process.sleep(150)

        # Flag must still read false after session activity
        refute KiroCockpit.Swarm.DataPipeline.acp_capture_enabled?()

        # Raw ACP messages MUST still be persisted (persist_messages: true)
        raw_msgs = EventStore.list_acp_messages(sid)
        assert [_ | _] = raw_msgs

        # Inbound responses must exist despite flag being false
        responses =
          Enum.filter(raw_msgs, fn m ->
            m.direction == "agent_to_client" and m.message_type in ["response", "error"]
          end)

        assert [_ | _] = responses

        # Bronze ACP events MUST also be persisted — the flag is NOT a kill switch
        acp_events = BronzeAcp.list_acp_events(sid)
        assert [_ | _] = acp_events

        # Request events with correct direction
        request_events = Enum.filter(acp_events, &(&1.event_type == "acp_request"))

        assert Enum.any?(request_events, fn event ->
                 event.hook_results["direction"] == "client_to_agent"
               end)

        # Response events with correct direction
        response_events = Enum.filter(acp_events, &(&1.event_type == "acp_response"))

        assert Enum.any?(response_events, fn event ->
                 event.hook_results["direction"] == "agent_to_client"
               end)

        # Triple-check: flag never flipped during the test
        refute KiroCockpit.Swarm.DataPipeline.acp_capture_enabled?()
      end)
    end
  end
end
