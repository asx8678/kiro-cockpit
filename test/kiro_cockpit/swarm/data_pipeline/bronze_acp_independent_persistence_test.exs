defmodule KiroCockpit.Swarm.DataPipeline.BronzeAcpIndependentPersistenceTest do
  @moduledoc false

  # Proves Bronze ACP capture is MANDATORY and independent of persist_messages.
  #
  # Per kiro-buk, persist_messages: false must ONLY suppress raw EventStore
  # persistence (raw_acp_message rows). Bronze ACP events (acp_request,
  # acp_response, acp_notification) must be persisted UNCONDITIONALLY
  # regardless of the persist_messages flag.
  #
  # Semantics:
  #   persist_messages: true  -> raw ACP persisted, Bronze ACP persisted
  #   persist_messages: false -> raw ACP skipped,  Bronze ACP persisted
  #
  # The Bronze ACP path runs through KiroSession.persist_bronze_acp/3 which
  # calls into BronzeAcp.record_acp_request/4, record_acp_response/4, etc.
  # These are NOT gated on persist_messages in the session state.
  #
  # Raw ACP persistence (EventStore.record_acp_message/3) IS gated on
  # persist_messages and is intentionally skipped when the flag is false.

  use KiroCockpit.DataCase, async: false

  alias KiroCockpit.EventStore
  alias KiroCockpit.KiroSession
  alias KiroCockpit.Swarm.DataPipeline.BronzeAcp

  @fake_agent_entry ~s|KiroCockpit.Test.Acp.FakeAgent.main()|

  setup do
    elixir_path = System.find_executable("elixir") || flunk("elixir not on PATH; cannot run port test")

    ebin_dirs =
      Path.wildcard(Path.expand("_build/#{Mix.env()}/lib/*/ebin", File.cwd!()))

    args = Enum.flat_map(ebin_dirs, fn dir -> ["-pa", dir] end) ++ ["-e", @fake_agent_entry]

    {:ok, %{elixir: elixir_path, args: args}}
  end

  defp safe_stop(pid) do
    if Process.alive?(pid) do
      try do
        KiroSession.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end
  end

  # Exception-safe Application env mutation: uses fetch_env/delete_env to
  # correctly restore keys that were previously unset, avoiding env leaks.
  defp with_env(key, value, fun) do
    original = Application.fetch_env(:kiro_cockpit, key)
    Application.put_env(:kiro_cockpit, key, value)

    try do
      fun.()
    after
      case original do
        {:ok, orig_value} -> Application.put_env(:kiro_cockpit, key, orig_value)
        :error -> Application.delete_env(:kiro_cockpit, key)
      end
    end
  end

  describe "Bronze ACP persists when persist_messages: false (raw persistence disabled)" do
    setup %{elixir: elixir, args: args} do
      {:ok, session_pid} =
        KiroSession.start_link(
          executable: elixir,
          args: args,
          subscriber: self(),
          persist_messages: false,
          auto_callbacks: false,
          test_bypass: true
        )

      on_exit(fn -> safe_stop(session_pid) end)
      {:ok, %{session_pid: session_pid}}
    end

    test "raw ACP messages are NOT persisted when persist_messages: false",
         %{session_pid: session_pid} do
      assert {:ok, _} = KiroSession.initialize(session_pid, timeout: 10_000)
      tmp_dir = System.tmp_dir!()
      assert {:ok, _} = KiroSession.new_session(session_pid, tmp_dir, timeout: 10_000)

      state = KiroSession.state(session_pid)
      sid = state.session_id
      assert sid != nil

      Process.sleep(150)

      raw_msgs = EventStore.list_acp_messages(sid)
      assert raw_msgs == [],
             "Expected zero raw_acp_message rows when persist_messages: false, " <>
               "got #{length(raw_msgs)}: #{inspect(Enum.map(raw_msgs, & &1.method))}"
    end

    test "Bronze ACP events ARE persisted even when persist_messages: false",
         %{session_pid: session_pid} do
      assert {:ok, _} = KiroSession.initialize(session_pid, timeout: 10_000)
      tmp_dir = System.tmp_dir!()
      assert {:ok, _} = KiroSession.new_session(session_pid, tmp_dir, timeout: 10_000)

      state = KiroSession.state(session_pid)
      sid = state.session_id
      assert sid != nil

      Process.sleep(150)

      acp_events = BronzeAcp.list_acp_events(sid)
      assert length(acp_events) >= 1,
             "Expected at least one Bronze ACP event when persist_messages: false, " <>
               "got #{length(acp_events)}"

      request_events = Enum.filter(acp_events, &(&1.event_type == "acp_request"))
      assert Enum.any?(request_events, fn event ->
               event.hook_results["direction"] == "client_to_agent"
             end)

      response_events = Enum.filter(acp_events, &(&1.event_type == "acp_response"))
      assert Enum.any?(response_events, fn event ->
               event.hook_results["direction"] == "agent_to_client"
             end)
    end

    test "Bronze ACP events carry session_id and agent_id correlation when persist_messages: false",
         %{session_pid: session_pid} do
      assert {:ok, _} = KiroSession.initialize(session_pid, timeout: 10_000)
      tmp_dir = System.tmp_dir!()
      assert {:ok, _} = KiroSession.new_session(session_pid, tmp_dir, timeout: 10_000)

      state = KiroSession.state(session_pid)
      sid = state.session_id
      assert sid != nil

      Process.sleep(150)

      acp_events = BronzeAcp.list_acp_events(sid)

      for event <- acp_events do
        assert event.session_id == sid,
               "event #{event.id} has session_id #{inspect(event.session_id)}, expected #{sid}"

        assert is_binary(event.agent_id) and event.agent_id != "",
               "event #{event.id} has missing/invalid agent_id: #{inspect(event.agent_id)}"
      end
    end
  end

  describe "Bronze ACP also persists when persist_messages: true (dual path verification)" do
    setup %{elixir: elixir, args: args} do
      {:ok, session_pid} =
        KiroSession.start_link(
          executable: elixir,
          args: args,
          subscriber: self(),
          persist_messages: true,
          auto_callbacks: false,
          test_bypass: true
        )

      on_exit(fn -> safe_stop(session_pid) end)
      {:ok, %{session_pid: session_pid}}
    end

    test "both raw ACP and Bronze ACP are persisted when persist_messages: true",
         %{session_pid: session_pid} do
      assert {:ok, _} = KiroSession.initialize(session_pid, timeout: 10_000)
      tmp_dir = System.tmp_dir!()
      assert {:ok, _} = KiroSession.new_session(session_pid, tmp_dir, timeout: 10_000)

      state = KiroSession.state(session_pid)
      sid = state.session_id
      assert sid != nil

      Process.sleep(150)

      raw_msgs = EventStore.list_acp_messages(sid)
      assert length(raw_msgs) >= 1,
             "Expected raw_acp_message rows when persist_messages: true"

      acp_events = BronzeAcp.list_acp_events(sid)
      assert length(acp_events) >= 1,
             "Expected Bronze ACP events when persist_messages: true"
    end
  end

  describe "Bronze ACP still persists when both persist_messages: false and bronze_acp_capture_enabled: false" do
    setup %{elixir: elixir, args: args} do
      {:ok, session_pid} =
        KiroSession.start_link(
          executable: elixir,
          args: args,
          subscriber: self(),
          persist_messages: false,
          auto_callbacks: false,
          test_bypass: true
        )

      on_exit(fn -> safe_stop(session_pid) end)
      {:ok, %{session_pid: session_pid}}
    end

    test "Bronze ACP events persist even when BOTH persist_messages and bronze_acp_capture_enabled are false",
         %{session_pid: session_pid} do
      with_env(:bronze_acp_capture_enabled, false, fn ->
        refute KiroCockpit.Swarm.DataPipeline.acp_capture_enabled?()

        assert {:ok, _} = KiroSession.initialize(session_pid, timeout: 10_000)
        tmp_dir = System.tmp_dir!()
        assert {:ok, _} = KiroSession.new_session(session_pid, tmp_dir, timeout: 10_000)

        state = KiroSession.state(session_pid)
        sid = state.session_id
        assert sid != nil

        Process.sleep(150)

        refute KiroCockpit.Swarm.DataPipeline.acp_capture_enabled?()

        raw_msgs = EventStore.list_acp_messages(sid)
        assert raw_msgs == [],
               "Expected zero raw_acp_message rows when persist_messages: false"

        acp_events = BronzeAcp.list_acp_events(sid)
        assert length(acp_events) >= 1,
               "Expected Bronze ACP events even with both flags false"
      end)
    end
  end

  describe "unit-level: BronzeAcp functions persist independently of KiroSession state" do
    test "BronzeAcp.record_acp_request persists regardless of any session flag" do
      session_id = "sess_unit_indep_#{System.unique_integer([:positive])}"

      payload = %{
        "jsonrpc" => "2.0",
        "method" => "tools/call",
        "params" => %{"name" => "fs_read"},
        "id" => 42
      }

      assert :ok =
               BronzeAcp.record_acp_request(session_id, "kiro-agent", payload,
                 method: "tools/call",
                 direction: :client_to_agent
               )

      [event] = BronzeAcp.list_acp_events(session_id)
      assert event.event_type == "acp_request"
      assert event.hook_results["method"] == "tools/call"
      assert event.hook_results["direction"] == "client_to_agent"
    end

    test "BronzeAcp.record_acp_response persists regardless of any session flag" do
      session_id = "sess_unit_indep_resp_#{System.unique_integer([:positive])}"

      payload = %{
        "jsonrpc" => "2.0",
        "result" => %{"content" => "ok"},
        "id" => 42
      }

      assert :ok =
               BronzeAcp.record_acp_response(session_id, "kiro-agent", payload,
                 method: "tools/call"
               )

      [event] = BronzeAcp.list_acp_events(session_id)
      assert event.event_type == "acp_response"
    end
  end

  describe "documentation and semantics contract" do
    test "data_pipeline.acp_capture_enabled?/0 documents it is NOT a kill switch" do
      assert is_boolean(KiroCockpit.Swarm.DataPipeline.acp_capture_enabled?())
    end
  end
end
