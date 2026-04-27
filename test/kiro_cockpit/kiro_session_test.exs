defmodule KiroCockpit.KiroSessionTest do
  @moduledoc """
  Integration tests for `KiroCockpit.KiroSession`.

  Spawns a real `elixir` subprocess running `FakeLifecycleAgent.main/0`
  and exercises the full ACP lifecycle:

    1. initialize
    2. session/new OR session/load
    3. session/prompt

  Tests verify request params, state transitions, prompt text normalization,
  session storage, and inbound notification/request forwarding.
  """

  use ExUnit.Case, async: false

  alias KiroCockpit.KiroSession

  @fake_agent_entry ~s|KiroCockpit.Test.Acp.FakeLifecycleAgent.main()|

  setup do
    elixir_path = System.find_executable("elixir") || flunk("elixir not on PATH")

    ebin_dirs =
      Path.wildcard(Path.expand("_build/#{Mix.env()}/lib/*/ebin", File.cwd!()))

    args = Enum.flat_map(ebin_dirs, fn dir -> ["-pa", dir] end) ++ ["-e", @fake_agent_entry]

    {:ok, %{elixir: elixir_path, args: args}}
  end

  # -- start / stop ---------------------------------------------------------

  describe "start_link/1" do
    test "rejects missing :executable option" do
      Process.flag(:trap_exit, true)
      assert {:error, {:invalid_option, :executable}} = KiroSession.start_link([])
    end

    test "starts and stops cleanly", %{elixir: elixir, args: args} do
      {:ok, session} =
        KiroSession.start_link(
          executable: elixir,
          args: args,
          subscriber: self(),
          persist_messages: false,
          auto_callbacks: false,
          test_bypass: true
        )

      assert Process.alive?(session)

      state = KiroSession.state(session)
      assert state.phase == :uninitialized

      :ok = KiroSession.stop(session)
      refute Process.alive?(session)
    end

    test "uses subscriber default to caller pid", %{elixir: elixir, args: args} do
      {:ok, session} =
        KiroSession.start_link(
          executable: elixir,
          args: args,
          persist_messages: false,
          auto_callbacks: false,
          test_bypass: true
        )

      on_exit(fn -> safe_stop(session) end)

      # Initialize and create a session — the fake agent emits a
      # session/update notification after session/new, which should
      # arrive in the caller's mailbox (since we're the subscriber).
      assert {:ok, _} = KiroSession.initialize(session)
      assert {:ok, _} = KiroSession.new_session(session, File.cwd!())
      assert_receive {:acp_notification, ^session, _}, 2_000
    end
  end

  # -- initialize -----------------------------------------------------------

  describe "initialize/2" do
    setup %{elixir: elixir, args: args} do
      {:ok, session} =
        KiroSession.start_link(
          executable: elixir,
          args: args,
          subscriber: self(),
          persist_messages: false,
          auto_callbacks: false,
          test_bypass: true
        )

      on_exit(fn -> safe_stop(session) end)
      {:ok, %{session: session}}
    end

    test "sends correct params and transitions to :initialized", %{session: session} do
      assert {:ok, result} = KiroSession.initialize(session)

      assert result["protocolVersion"] == 1
      assert %{"name" => "kiro-fake", "version" => "0.0.1-test"} = result["agentInfo"]
      assert result["authMethods"] == []

      state = KiroSession.state(session)
      assert state.phase == :initialized
      assert state.protocol_version == 1
      assert state.agent_info["name"] == "kiro-fake"
      assert state.auth_methods == []
    end

    test "stores agent capabilities from response", %{session: session} do
      assert {:ok, result} = KiroSession.initialize(session)

      state = KiroSession.state(session)
      assert state.agent_capabilities == Map.get(result, "agentCapabilities")
      assert state.agent_capabilities["loadSession"] == true
    end

    test "rejects double initialize", %{session: session} do
      assert {:ok, _} = KiroSession.initialize(session)

      assert {:error, {:invalid_phase, :initialized}} = KiroSession.initialize(session)
    end

    test "rejects initialize with wrong protocol version", %{elixir: elixir, args: args} do
      {:ok, session} =
        KiroSession.start_link(
          executable: elixir,
          args: args,
          subscriber: self(),
          persist_messages: false,
          auto_callbacks: false,
          test_bypass: true
        )

      on_exit(fn -> safe_stop(session) end)

      # The fake agent always returns protocolVersion=1.
      # Requesting version 99 should fail.
      assert {:error, {:protocol_version_mismatch, expected: 99, got: 1}} =
               KiroSession.initialize(session, protocol_version: 99)
    end

    test "accepts custom client_info and capabilities", %{session: session} do
      custom_info = %{"name" => "test-client", "title" => "Test", "version" => "9.9.9"}

      custom_caps = %{
        "fs" => %{"readTextFile" => true, "writeTextFile" => false},
        "terminal" => false
      }

      assert {:ok, _} =
               KiroSession.initialize(session,
                 client_info: custom_info,
                 client_capabilities: custom_caps
               )

      state = KiroSession.state(session)
      # State doesn't expose client_info/client_capabilities in the summary,
      # but the fact that initialize succeeded means they were accepted.
      assert state.phase == :initialized
    end

    test "rejects new_session before initialize", %{session: session} do
      assert {:error, {:invalid_phase, :uninitialized}} =
               KiroSession.new_session(session, "/tmp")
    end

    test "rejects prompt before initialize", %{session: session} do
      assert {:error, {:invalid_phase, :uninitialized}} =
               KiroSession.prompt(session, "hello")
    end
  end

  # -- session/new ----------------------------------------------------------

  describe "new_session/3" do
    setup %{elixir: elixir, args: args} do
      {:ok, session} =
        KiroSession.start_link(
          executable: elixir,
          args: args,
          subscriber: self(),
          persist_messages: false,
          auto_callbacks: false,
          test_bypass: true
        )

      assert {:ok, _} = KiroSession.initialize(session)

      on_exit(fn -> safe_stop(session) end)
      {:ok, %{session: session}}
    end

    test "creates a session and transitions to :session_active", %{session: session} do
      cwd = File.cwd!()
      assert {:ok, result} = KiroSession.new_session(session, cwd)

      assert result["sessionId"] == "sess_fake_001"

      state = KiroSession.state(session)
      assert state.phase == :session_active
      assert state.session_id == "sess_fake_001"
      assert state.cwd == cwd
    end

    test "stores modes and config_options from result", %{session: session} do
      cwd = File.cwd!()
      assert {:ok, result} = KiroSession.new_session(session, cwd)

      state = KiroSession.state(session)
      assert state.modes == Map.get(result, "modes")
      assert state.config_options == Map.get(result, "configOptions")
      assert state.modes["currentModeId"] == "code"
      assert length(state.config_options) == 1
    end

    test "forwards session/update notification from agent", %{session: session} do
      cwd = File.cwd!()
      assert {:ok, _} = KiroSession.new_session(session, cwd)

      assert_receive {:acp_notification, ^session,
                      %{method: "session/update", params: %{"sessionId" => "sess_fake_001"}}},
                     2_000
    end

    test "rejects new_session when already session_active", %{session: session} do
      cwd = File.cwd!()
      assert {:ok, _} = KiroSession.new_session(session, cwd)
      # Drain notification
      assert_receive {:acp_notification, ^session, _}, 2_000

      assert {:error, {:invalid_phase, :session_active}} =
               KiroSession.new_session(session, "/tmp")
    end

    test "rejects new_session from :uninitialized", %{elixir: elixir, args: args} do
      {:ok, session2} =
        KiroSession.start_link(
          executable: elixir,
          args: args,
          subscriber: self(),
          persist_messages: false,
          auto_callbacks: false,
          test_bypass: true
        )

      on_exit(fn -> safe_stop(session2) end)

      assert {:error, {:invalid_phase, :uninitialized}} =
               KiroSession.new_session(session2, "/tmp")
    end
  end

  # -- session/load ---------------------------------------------------------

  describe "load_session/4" do
    setup %{elixir: elixir, args: args} do
      {:ok, session} =
        KiroSession.start_link(
          executable: elixir,
          args: args,
          subscriber: self(),
          persist_messages: false,
          auto_callbacks: false,
          test_bypass: true
        )

      assert {:ok, _} = KiroSession.initialize(session)

      on_exit(fn -> safe_stop(session) end)
      {:ok, %{session: session}}
    end

    test "loads a session and transitions to :session_active", %{session: session} do
      cwd = File.cwd!()
      session_id = "sess_existing_999"

      assert {:ok, nil} = KiroSession.load_session(session, session_id, cwd)

      state = KiroSession.state(session)
      assert state.phase == :session_active
      assert state.session_id == session_id
      assert state.cwd == cwd
    end

    test "forwards session/update notification during load", %{session: session} do
      cwd = File.cwd!()

      assert {:ok, nil} = KiroSession.load_session(session, "sess_existing_999", cwd)

      # Fake agent emits a session/update during load
      assert_receive {:acp_notification, ^session,
                      %{method: "session/update", params: %{"sessionId" => "sess_existing_999"}}},
                     2_000
    end

    test "rejects load_session from :uninitialized", %{elixir: elixir, args: args} do
      {:ok, session2} =
        KiroSession.start_link(
          executable: elixir,
          args: args,
          subscriber: self(),
          persist_messages: false,
          auto_callbacks: false,
          test_bypass: true
        )

      on_exit(fn -> safe_stop(session2) end)

      assert {:error, {:invalid_phase, :uninitialized}} =
               KiroSession.load_session(session2, "sess_x", "/tmp")
    end

    test "rejects load_session when already session_active", %{session: session} do
      cwd = File.cwd!()
      assert {:ok, nil} = KiroSession.load_session(session, "sess_1", cwd)
      # Drain notification
      assert_receive {:acp_notification, ^session, _}, 2_000

      assert {:error, {:invalid_phase, :session_active}} =
               KiroSession.load_session(session, "sess_2", cwd)
    end
  end

  # -- session/prompt -------------------------------------------------------

  describe "prompt/3" do
    setup %{elixir: elixir, args: args} do
      {:ok, session} =
        KiroSession.start_link(
          executable: elixir,
          args: args,
          subscriber: self(),
          persist_messages: false,
          auto_callbacks: false,
          test_bypass: true
        )

      assert {:ok, _} = KiroSession.initialize(session)

      cwd = File.cwd!()
      assert {:ok, _} = KiroSession.new_session(session, cwd)
      # Drain the session/update notification from session/new
      assert_receive {:acp_notification, ^session, _}, 2_000

      on_exit(fn -> safe_stop(session) end)
      {:ok, %{session: session}}
    end

    test "normalizes plain text to a content block list", %{session: session} do
      # The fake agent will respond with stopReason: "end_turn"
      task =
        Task.async(fn ->
          KiroSession.prompt(session, "Explain main.py")
        end)

      # Receive forwarded notification
      assert_receive {:acp_notification, ^session, %{method: "session/update", params: _}},
                     2_000

      # The fake agent also sends an fs/read_text_file request
      assert_receive {:acp_request, ^session,
                      %{id: req_id, method: "fs/read_text_file", params: params}},
                     2_000

      # Verify the request params from the agent
      assert params["path"] == "/tmp/kiro-lifecycle-test.txt"

      # Respond to the agent's request so it can proceed
      :ok = KiroSession.respond(session, req_id, %{"content" => "file contents here"})

      # Await the prompt result
      assert {:ok, %{"stopReason" => "end_turn"}} = Task.await(task, 5_000)
    end

    test "passes through pre-formed content blocks unchanged", %{session: session} do
      blocks = [
        %{"type" => "text", "text" => "Look at this file"},
        %{
          "type" => "resource_link",
          "resourceLink" => %{"uri" => "file:///tmp/main.py", "mimeType" => "text/x-python"}
        }
      ]

      task =
        Task.async(fn ->
          KiroSession.prompt(session, blocks)
        end)

      # Drain notifications
      assert_receive {:acp_notification, ^session, _}, 2_000
      assert_receive {:acp_request, ^session, %{id: req_id}}, 2_000
      :ok = KiroSession.respond(session, req_id, %{"content" => "ok"})

      assert {:ok, %{"stopReason" => "end_turn"}} = Task.await(task, 5_000)
    end

    test "rejects prompt from :initialized phase", %{elixir: elixir, args: args} do
      {:ok, session2} =
        KiroSession.start_link(
          executable: elixir,
          args: args,
          subscriber: self(),
          persist_messages: false,
          auto_callbacks: false,
          test_bypass: true
        )

      on_exit(fn -> safe_stop(session2) end)
      assert {:ok, _} = KiroSession.initialize(session2)

      assert {:error, {:invalid_phase, :initialized}} = KiroSession.prompt(session2, "hello")
    end

    test "rejects prompt from :uninitialized phase", %{elixir: elixir, args: args} do
      {:ok, session2} =
        KiroSession.start_link(
          executable: elixir,
          args: args,
          subscriber: self(),
          persist_messages: false,
          auto_callbacks: false,
          test_bypass: true
        )

      on_exit(fn -> safe_stop(session2) end)

      assert {:error, {:invalid_phase, :uninitialized}} = KiroSession.prompt(session2, "hello")
    end

    test "rejects concurrent prompts", %{session: session} do
      # Start a prompt in a background task
      task =
        Task.async(fn ->
          KiroSession.prompt(session, "First prompt", timeout: :infinity)
        end)

      # Wait for the first session/update notification — that's a precise
      # signal that the prompt RPC has landed in `pending_prompt` (no
      # fixed sleep).
      assert_receive {:acp_notification, ^session, _}, 2_000

      # A second prompt should be rejected
      assert {:error, :prompt_in_progress} = KiroSession.prompt(session, "Second prompt")

      # Clean up: drain the request from the first prompt, then respond
      # so the agent can complete.
      assert_receive {:acp_request, ^session, %{id: req_id}}, 2_000
      :ok = KiroSession.respond(session, req_id, %{"content" => "x"})

      assert {:ok, _} = Task.await(task, 10_000)
    end
  end

  # -- Inbound message forwarding -------------------------------------------

  describe "inbound message forwarding" do
    setup %{elixir: elixir, args: args} do
      {:ok, session} =
        KiroSession.start_link(
          executable: elixir,
          args: args,
          subscriber: self(),
          persist_messages: false,
          auto_callbacks: false,
          test_bypass: true
        )

      assert {:ok, _} = KiroSession.initialize(session)
      cwd = File.cwd!()
      assert {:ok, _} = KiroSession.new_session(session, cwd)

      # Drain session/update from session/new
      assert_receive {:acp_notification, ^session, _}, 2_000

      on_exit(fn -> safe_stop(session) end)
      {:ok, %{session: session}}
    end

    test "forwards session/update notifications with correct shape", %{session: session} do
      task =
        Task.async(fn ->
          KiroSession.prompt(session, "test notification shape")
        end)

      assert_receive {:acp_notification, ^session,
                      %{method: "session/update", params: %{"sessionId" => _, "update" => _}}},
                     2_000

      # Drain the fs request and respond
      assert_receive {:acp_request, ^session, %{id: req_id}}, 2_000
      :ok = KiroSession.respond(session, req_id, %{"content" => "ok"})

      assert {:ok, _} = Task.await(task, 5_000)
    end

    test "forwards agent requests with correct shape including id", %{session: session} do
      task =
        Task.async(fn ->
          KiroSession.prompt(session, "test request forwarding")
        end)

      assert_receive {:acp_request, ^session,
                      %{id: req_id, method: "fs/read_text_file", params: params}},
                     2_000

      assert is_integer(req_id) or is_binary(req_id)
      assert params["path"] != nil
      assert params["sessionId"] != nil

      :ok = KiroSession.respond(session, req_id, %{"content" => "response content"})

      assert {:ok, _} = Task.await(task, 5_000)
    end

    test "respond_error sends error to agent without crashing", %{session: session} do
      task =
        Task.async(fn ->
          KiroSession.prompt(session, "test error response")
        end)

      assert_receive {:acp_request, ^session, %{id: req_id, method: "fs/read_text_file"}}, 2_000

      :ok =
        KiroSession.respond_error(session, req_id, -32_001, "Permission denied", %{
          "reason" => "policy"
        })

      # The fake agent doesn't crash on error responses; the prompt should still complete.
      # The fake agent will still respond to the prompt after its sleep.
      assert {:ok, _} = Task.await(task, 5_000)
    end
  end

  # -- session/load + prompt -------------------------------------------------

  describe "full lifecycle via session/load" do
    setup %{elixir: elixir, args: args} do
      {:ok, session} =
        KiroSession.start_link(
          executable: elixir,
          args: args,
          subscriber: self(),
          persist_messages: false,
          auto_callbacks: false,
          test_bypass: true
        )

      assert {:ok, _} = KiroSession.initialize(session)

      session_id = "sess_loaded_42"
      cwd = File.cwd!()
      assert {:ok, nil} = KiroSession.load_session(session, session_id, cwd)

      # Drain session/update from load
      assert_receive {:acp_notification, ^session, _}, 2_000

      on_exit(fn -> safe_stop(session) end)
      {:ok, %{session: session, session_id: session_id}}
    end

    test "prompt works after session/load", %{session: session, session_id: session_id} do
      task =
        Task.async(fn ->
          KiroSession.prompt(session, "Resume work")
        end)

      # Receive forwarded notification and request
      assert_receive {:acp_notification, ^session, _}, 2_000
      assert_receive {:acp_request, ^session, %{id: req_id}}, 2_000
      :ok = KiroSession.respond(session, req_id, %{"content" => "file data"})

      assert {:ok, %{"stopReason" => "end_turn"}} = Task.await(task, 5_000)

      # Session state preserved
      state = KiroSession.state(session)
      assert state.phase == :session_active
      assert state.session_id == session_id
    end
  end

  # -- notify ---------------------------------------------------------------

  describe "notify/3" do
    setup %{elixir: elixir, args: args} do
      {:ok, session} =
        KiroSession.start_link(
          executable: elixir,
          args: args,
          subscriber: self(),
          persist_messages: false,
          auto_callbacks: false,
          test_bypass: true
        )

      on_exit(fn -> safe_stop(session) end)
      {:ok, %{session: session}}
    end

    test "sends notification without crashing", %{session: session} do
      # This is fire-and-forget; we just verify the GenServer stays alive.
      :ok = KiroSession.notify(session, "session/cancel", %{"sessionId" => "test"})
      Process.sleep(50)
      assert Process.alive?(session)
    end
  end

  # -- Port exit handling ---------------------------------------------------

  describe "port exit" do
    test "clean exit transitions to :transport_closed and forwards to subscriber" do
      true_path = System.find_executable("true") || flunk("`true` not on PATH")

      {:ok, session} =
        KiroSession.start_link(
          executable: true_path,
          args: [],
          subscriber: self(),
          persist_messages: false,
          auto_callbacks: false,
          test_bypass: true
        )

      on_exit(fn -> safe_stop(session) end)

      # The `true` command exits immediately with status 0.
      # KiroSession should receive the exit and forward it to subscriber.
      assert_receive {:acp_exit, ^session, 0}, 3_000

      state = KiroSession.state(session)
      assert state.phase == :transport_closed
    end

    test "lifecycle calls after port exit return {:error, :transport_closed} instead of crashing" do
      # Regression: after acp_exit, calling initialize/2 must not crash
      # via GenServer.call(nil, ...) — it should return a clean error.
      true_path = System.find_executable("true") || flunk("`true` not on PATH")

      {:ok, session} =
        KiroSession.start_link(
          executable: true_path,
          args: [],
          subscriber: self(),
          persist_messages: false,
          auto_callbacks: false,
          test_bypass: true
        )

      on_exit(fn -> safe_stop(session) end)

      # Wait for the port to exit
      assert_receive {:acp_exit, ^session, 0}, 3_000

      # All lifecycle calls must return {:error, :transport_closed}, not crash
      assert {:error, :transport_closed} = KiroSession.initialize(session)
      assert {:error, :transport_closed} = KiroSession.new_session(session, "/tmp")
      assert {:error, :transport_closed} = KiroSession.load_session(session, "sess_x", "/tmp")
      assert {:error, :transport_closed} = KiroSession.prompt(session, "hello")
    end

    test "non-lifecycle calls after port exit still work" do
      true_path = System.find_executable("true") || flunk("`true` not on PATH")

      {:ok, session} =
        KiroSession.start_link(
          executable: true_path,
          args: [],
          subscriber: self(),
          persist_messages: false,
          auto_callbacks: false,
          test_bypass: true
        )

      on_exit(fn -> safe_stop(session) end)

      assert_receive {:acp_exit, ^session, 0}, 3_000

      # state/1 should still work — the session stays alive for introspection
      state = KiroSession.state(session)
      assert state.phase == :transport_closed

      # respond/3 should return {:error, :transport_closed} cleanly
      assert {:error, :transport_closed} = KiroSession.respond(session, 1, %{})

      # respond_error/4 should return {:error, :transport_closed} cleanly
      assert {:error, :transport_closed} =
               KiroSession.respond_error(session, 1, -32_000, "err", nil)

      # notify/3 should not crash (it's a cast, returns :ok immediately)
      :ok = KiroSession.notify(session, "session/cancel", %{"sessionId" => "x"})
    end
  end

  # -- kiro-egn: non-bypassable action boundary (KiroSession-level tests) ----

  describe "kiro-egn: non-bypassable action boundary" do
    setup %{elixir: elixir, args: args} do
      {:ok, session} =
        KiroSession.start_link(
          executable: elixir,
          args: args,
          subscriber: self(),
          persist_messages: false,
          auto_callbacks: false,
          # Explicitly disable hooks, no test_bypass
          swarm_hooks: false,
          test_bypass: false
        )

      assert {:ok, _} = KiroSession.initialize(session)

      cwd = File.cwd!()
      assert {:ok, _} = KiroSession.new_session(session, cwd)
      # Drain session/update notification
      assert_receive {:acp_notification, ^session, _}, 2_000

      on_exit(fn -> safe_stop(session) end)
      {:ok, %{session: session}}
    end

    test "prompt fails closed when swarm_hooks disabled and no test_bypass", %{session: session} do
      assert {:error, {:swarm_boundary_disabled, :kiro_session_prompt}} =
               KiroSession.prompt(session, "should be blocked")

      # Session stays alive — no GenServer crash
      assert Process.alive?(session)
    end
  end

  describe "kiro-egn: callback handles boundary-disabled tuple defensively" do
    setup %{elixir: elixir, args: args} do
      # Use a mock boundary that allows prompts but returns
      # {:error, {:swarm_boundary_disabled, action}} for callback actions.
      # This tests the defensive handling in run_callback_with_boundary/5.
      {:ok, session} =
        KiroSession.start_link(
          executable: elixir,
          args: args,
          subscriber: self(),
          persist_messages: false,
          auto_callbacks: true,
          swarm_hooks: true,
          swarm_hooks_module: KiroCockpit.Test.KiroEgnMockBoundary,
          test_bypass: true
        )

      assert {:ok, _} = KiroSession.initialize(session)

      cwd = File.cwd!()
      assert {:ok, _} = KiroSession.new_session(session, cwd)
      assert_receive {:acp_notification, ^session, _}, 2_000

      # Ensure the test file exists for the fake agent's read
      File.write!("/tmp/kiro-fake.txt", "callback boundary test content")

      on_exit(fn ->
        File.rm("/tmp/kiro-fake.txt")
        safe_stop(session)
      end)

      {:ok, %{session: session}}
    end

    test "callback sends respond_error on boundary-disabled tuple, no crash", %{
      session: session
    } do
      # The mock boundary allows the prompt but returns disabled for
      # callback actions (fs_read_requested). The session should NOT crash —
      # the defensive clause in run_callback_with_boundary sends
      # respond_error instead.
      task =
        Task.async(fn ->
          KiroSession.prompt(session, "Read a file")
        end)

      # The subscriber still receives the forwarded request for observability
      assert_receive {:acp_request, ^session,
                      %{id: _id, method: "fs/read_text_file", params: _params}},
                     5_000

      # The prompt should complete (the agent got an error response from
      # the boundary disabled handler and continued or ended the turn).
      result = Task.await(task, 10_000)

      # Session is still alive — no GenServer crash from unhandled clause
      assert Process.alive?(session)

      # Result may be {:ok, _} or {:error, _} depending on agent behavior
      # after receiving the boundary-disabled error; the key invariant is
      # no crash.
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  describe "kiro-egn: explicit swarm_hooks=true with app config false" do
    setup %{elixir: elixir, args: args} do
      # Save and override app config to false (already false in test.exs,
      # but be explicit for clarity)
      original = Application.get_env(:kiro_cockpit, :swarm_action_hooks_enabled)
      Application.put_env(:kiro_cockpit, :swarm_action_hooks_enabled, false)

      {:ok, session} =
        KiroSession.start_link(
          executable: elixir,
          args: args,
          subscriber: self(),
          persist_messages: false,
          auto_callbacks: false,
          # Explicitly enable hooks at session level, overriding app config
          swarm_hooks: true,
          test_bypass: true
        )

      assert {:ok, _} = KiroSession.initialize(session)

      cwd = File.cwd!()
      assert {:ok, _} = KiroSession.new_session(session, cwd)
      assert_receive {:acp_notification, ^session, _}, 2_000

      on_exit(fn ->
        Application.put_env(:kiro_cockpit, :swarm_action_hooks_enabled, original)
        safe_stop(session)
      end)

      {:ok, %{session: session}}
    end

    test "prompt routes through boundary / does not disabled-crash when swarm_hooks=true overrides app config",
         %{
           session: session
         } do
      # With swarm_hooks: true and app config false, the boundary should
      # run (enabled: true in opts overrides app config). The boundary may
      # block the prompt (e.g. TaskEnforcementHook with no active task),
      # but it must NOT return {:error, {:swarm_boundary_disabled, ...}}.
      result = KiroSession.prompt(session, "test boundary routing")

      # Key assertion: NOT the disabled-crash error. The boundary either
      # blocks with {:swarm_blocked, ...} (hooks running) or some other
      # result, but never {:swarm_boundary_disabled, ...}.
      refute match?({:error, {:swarm_boundary_disabled, _}}, result)

      # Session is still alive — no GenServer crash
      assert Process.alive?(session)
    end
  end

  # -- Helpers --------------------------------------------------------------

  defp safe_stop(pid) do
    if Process.alive?(pid), do: KiroSession.stop(pid)
  catch
    :exit, _ -> :ok
  end
end
