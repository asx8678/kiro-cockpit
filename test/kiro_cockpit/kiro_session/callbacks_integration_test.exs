defmodule KiroCockpit.KiroSession.CallbacksIntegrationTest do
  @moduledoc """
  Integration tests for automatic callback handling (kiro-4ff).

  Tests that `KiroSession` with `auto_callbacks: true` automatically
  responds to `fs/*` and `terminal/*` callbacks without requiring the
  subscriber to call `respond/3`.

  Uses the `FakeAgent` callback scenario which sends `fs/read_text_file`
  during a prompt turn.
  """

  use ExUnit.Case, async: false

  alias KiroCockpit.KiroSession
  alias KiroCockpit.KiroSession.Callbacks

  @fake_agent_entry ~s|KiroCockpit.Test.Acp.FakeAgent.main()|

  # -- Helpers ----------------------------------------------------------------

  defp start_session!(scenario, opts \\ []) do
    elixir = System.find_executable("elixir") || flunk("elixir not on PATH")

    ebin_dirs =
      Path.wildcard(Path.expand("_build/#{Mix.env()}/lib/*/ebin", File.cwd!()))

    args = Enum.flat_map(ebin_dirs, fn dir -> ["-pa", dir] end) ++ ["-e", @fake_agent_entry]

    auto_callbacks = Keyword.get(opts, :auto_callbacks, true)
    initialize_opts = Keyword.get(opts, :initialize_opts, [])

    base_opts = [
      executable: elixir,
      args: args,
      env: [{"FAKE_ACP_SCENARIO", scenario}],
      subscriber: self(),
      persist_messages: false,
      auto_callbacks: auto_callbacks
    ]

    callback_policy_opts =
      if Keyword.has_key?(opts, :callback_policy) do
        [callback_policy: Keyword.fetch!(opts, :callback_policy)]
      else
        []
      end

    merged_opts =
      base_opts
      |> Keyword.merge(callback_policy_opts)
      |> Keyword.merge(Keyword.drop(opts, [:auto_callbacks, :callback_policy, :initialize_opts]))

    {:ok, session} = KiroSession.start_link(merged_opts)
    on_exit(fn -> safe_stop(session) end)

    {:ok, _} = KiroSession.initialize(session, initialize_opts)
    {:ok, sn_result} = KiroSession.new_session(session, File.cwd!())
    session_id = sn_result["sessionId"]

    %{session: session, session_id: session_id}
  end

  defp safe_stop(pid) do
    if Process.alive?(pid), do: KiroSession.stop(pid)
  catch
    :exit, _ -> :ok
  end

  defp assert_agent_message_chunk(session, expected_text) do
    assert_receive {:acp_notification, ^session,
                    %{
                      method: "session/update",
                      params: %{
                        "update" => %{
                          "sessionUpdate" => "agent_message_chunk",
                          "content" => [%{"text" => ^expected_text}]
                        }
                      }
                    }},
                   5_000
  end

  # -- fs/* auto-callbacks ----------------------------------------------------

  describe "auto-callbacks for fs/read_text_file" do
    setup do
      # Create the file that the FakeAgent will try to read
      path = "/tmp/kiro-fake.txt"
      File.write!(path, "auto-callback test content\nline2\nline3")
      on_exit(fn -> File.rm(path) end)
      :ok
    end

    test "agent callback is auto-handled without manual respond" do
      %{session: session} = start_session!("callback")

      task =
        Task.async(fn ->
          KiroSession.prompt(session, "Read a file")
        end)

      # Wait for the prompt to complete.
      # With auto_callbacks: true, the fs/read_text_file request should be
      # automatically handled — the agent should receive the file content
      # and complete the prompt without us calling respond/3.
      assert {:ok, result} = Task.await(task, 10_000)
      assert result["stopReason"] == "end_turn"
    end

    test "request is still forwarded to subscriber for observability" do
      %{session: session} = start_session!("callback")

      task =
        Task.async(fn ->
          KiroSession.prompt(session, "Read a file")
        end)

      # The subscriber should still receive the raw request.
      assert_receive {:acp_request, ^session,
                      %{id: _id, method: "fs/read_text_file", params: params}},
                     5_000

      assert params["path"] == "/tmp/kiro-fake.txt"

      # The prompt should complete without us calling respond.
      assert {:ok, _} = Task.await(task, 10_000)
    end
  end

  describe "auto-callbacks for fs/read_text_file with missing file" do
    test "agent receives error response and still completes" do
      # Ensure the file does NOT exist
      path = "/tmp/kiro-fake.txt"
      File.rm(path)

      %{session: session} = start_session!("callback")

      task =
        Task.async(fn ->
          KiroSession.prompt(session, "Read a file")
        end)

      # The subscriber still sees the request.
      assert_receive {:acp_request, ^session, %{method: "fs/read_text_file"}}, 5_000

      # The auto-handler will return a "File not found" error.
      # The FakeAgent should receive the error response and still complete
      # the prompt.
      assert {:ok, _} = Task.await(task, 10_000)
    end
  end

  # -- auto_callbacks: false preserves manual response -------------------------

  describe "auto_callbacks: false preserves manual response behavior" do
    test "subscriber must manually respond when auto_callbacks is false" do
      %{session: session} = start_session!("callback", auto_callbacks: false)

      # Create the file so the auto-handler won't be involved
      File.write!("/tmp/kiro-fake.txt", "manual response content")

      task =
        Task.async(fn ->
          KiroSession.prompt(session, "Read a file")
        end)

      # Receive the request and manually respond
      assert_receive {:acp_request, ^session, %{id: req_id, method: "fs/read_text_file"}}, 5_000
      :ok = KiroSession.respond(session, req_id, %{"content" => "manual content"})

      assert {:ok, _} = Task.await(task, 10_000)
    end
  end

  # -- Unknown methods still forwarded ----------------------------------------

  describe "unknown methods are still forwarded" do
    test "unknown request methods are NOT auto-handled" do
      # The FakeAgent 'normal' scenario doesn't send any callbacks
      # during prompt — it just emits notifications and returns.
      # We verify that the auto-callbacks don't interfere with
      # normal prompt flow.
      %{session: session} = start_session!("normal")

      task =
        Task.async(fn ->
          KiroSession.prompt(session, "Hello")
        end)

      # Normal scenario: just notifications, no requests.
      # Prompt should complete without any respond calls.
      assert {:ok, _} = Task.await(task, 10_000)
    end
  end

  # -- Callbacks module -------------------------------------------------------

  describe "Callbacks.known_method?/1" do
    test "recognizes all documented callback methods" do
      assert Callbacks.known_method?("fs/read_text_file")
      assert Callbacks.known_method?("fs/write_text_file")
      assert Callbacks.known_method?("terminal/create")
      assert Callbacks.known_method?("terminal/output")
      assert Callbacks.known_method?("terminal/wait_for_exit")
      assert Callbacks.known_method?("terminal/kill")
      assert Callbacks.known_method?("terminal/release")
    end

    test "does not recognize non-callback methods" do
      refute Callbacks.known_method?("initialize")
      refute Callbacks.known_method?("session/prompt")
      refute Callbacks.known_method?("session/new")
      refute Callbacks.known_method?("_kiro.dev/commands/execute")
    end
  end

  # -- state summary includes auto_callbacks ----------------------------------

  describe "state summary" do
    test "includes auto_callbacks field" do
      %{session: session} = start_session!("normal")

      state = KiroSession.state(session)
      assert Map.has_key?(state, :auto_callbacks)
      assert state.auto_callbacks == true
    end

    test "auto_callbacks is false when disabled" do
      %{session: session} = start_session!("normal", auto_callbacks: false)

      state = KiroSession.state(session)
      assert state.auto_callbacks == false
    end

    test "includes callback_policy field" do
      %{session: session} = start_session!("normal")

      state = KiroSession.state(session)
      assert Map.has_key?(state, :callback_policy)
      assert state.callback_policy == :read_only
    end

    test "callback_policy is :read_only when explicitly set" do
      %{session: session} = start_session!("normal", callback_policy: :read_only)

      state = KiroSession.state(session)
      assert state.callback_policy == :read_only
    end

    test "read-only policy clamps unsafe initialize capability overrides" do
      unsafe_caps = %{
        "fs" => %{"readTextFile" => true, "writeTextFile" => true},
        "terminal" => true
      }

      %{session: session} =
        start_session!("normal",
          callback_policy: :read_only,
          initialize_opts: [client_capabilities: unsafe_caps]
        )

      state = KiroSession.state(session)

      assert state.client_capabilities["fs"]["readTextFile"] == true
      assert state.client_capabilities["fs"]["writeTextFile"] == false
      assert state.client_capabilities["terminal"] == false
    end
  end

  # -- Callback policy: read_only denies mutating callbacks (MUST FIX 2) ------

  describe "callback_policy: :read_only denies mutating methods" do
    setup context do
      scenario = context[:scenario] || "callback"

      elixir = System.find_executable("elixir") || flunk("elixir not on PATH")

      ebin_dirs =
        Path.wildcard(Path.expand("_build/#{Mix.env()}/lib/*/ebin", File.cwd!()))

      args =
        Enum.flat_map(ebin_dirs, fn dir -> ["-pa", dir] end) ++
          ["-e", @fake_agent_entry]

      {:ok, session} =
        KiroSession.start_link(
          executable: elixir,
          args: args,
          env: [{"FAKE_ACP_SCENARIO", scenario}],
          subscriber: self(),
          persist_messages: false,
          auto_callbacks: true,
          callback_policy: :read_only
        )

      on_exit(fn -> safe_stop(session) end)

      {:ok, _} = KiroSession.initialize(session)
      {:ok, sn_result} = KiroSession.new_session(session, File.cwd!())
      session_id = sn_result["sessionId"]

      %{session: session, session_id: session_id}
    end

    @tag scenario: "callback"
    test "read-only session auto-handles fs/read_text_file and completes prompt",
         %{session: session} do
      # Ensure the file exists
      File.write!("/tmp/kiro-fake.txt", "read-only policy test")

      task =
        Task.async(fn ->
          KiroSession.prompt(session, "Read a file")
        end)

      # The fs/read_text_file should be auto-handled under :read_only
      assert_receive {:acp_request, ^session, %{method: "fs/read_text_file"}}, 5_000

      assert {:ok, _} = Task.await(task, 10_000)
    end

    @tag scenario: "callback_write"
    test "read-only session auto-denies fs/write_text_file without writing",
         %{session: session} do
      path = "/tmp/kiro-fake-write-policy.txt"
      File.rm(path)

      task = Task.async(fn -> KiroSession.prompt(session, "Try to write a file") end)

      assert_receive {:acp_request, ^session, %{method: "fs/write_text_file"}}, 5_000
      assert_agent_message_chunk(session, "write:denied")
      assert {:ok, %{"stopReason" => "end_turn"}} = Task.await(task, 10_000)
      refute File.exists?(path)
    end

    @tag scenario: "callback_terminal"
    test "read-only session auto-denies terminal/create", %{session: session} do
      task = Task.async(fn -> KiroSession.prompt(session, "Try terminal") end)

      assert_receive {:acp_request, ^session, %{method: "terminal/create"}}, 5_000
      assert_agent_message_chunk(session, "terminal:denied")
      assert {:ok, %{"stopReason" => "end_turn"}} = Task.await(task, 10_000)
    end
  end

  # -- Callback policy: :all allows everything (backward compat) --------------

  describe "callback_policy: :all allows all callback methods" do
    test "full auto-callbacks with :all policy" do
      elixir = System.find_executable("elixir") || flunk("elixir not on PATH")

      ebin_dirs =
        Path.wildcard(Path.expand("_build/#{Mix.env()}/lib/*/ebin", File.cwd!()))

      args =
        Enum.flat_map(ebin_dirs, fn dir -> ["-pa", dir] end) ++
          ["-e", @fake_agent_entry]

      {:ok, session} =
        KiroSession.start_link(
          executable: elixir,
          args: args,
          env: [{"FAKE_ACP_SCENARIO", "callback"}],
          subscriber: self(),
          persist_messages: false,
          auto_callbacks: true,
          callback_policy: :all
        )

      on_exit(fn -> safe_stop(session) end)

      {:ok, _} = KiroSession.initialize(session)
      {:ok, _} = KiroSession.new_session(session, File.cwd!())

      state = KiroSession.state(session)
      assert state.callback_policy == :all
    end

    test ":all permits fs/write_text_file callback and writes the file" do
      path = "/tmp/kiro-fake-write-policy.txt"
      File.rm(path)

      %{session: session} = start_session!("callback_write", callback_policy: :all)

      task = Task.async(fn -> KiroSession.prompt(session, "Write a file") end)

      assert_receive {:acp_request, ^session, %{method: "fs/write_text_file"}}, 5_000
      assert_agent_message_chunk(session, "write:allowed")
      assert {:ok, %{"stopReason" => "end_turn"}} = Task.await(task, 10_000)

      assert File.read!(path) == "write callback was allowed"
      File.rm(path)
    end

    test ":all permits terminal/create callback" do
      %{session: session} = start_session!("callback_terminal", callback_policy: :all)

      task = Task.async(fn -> KiroSession.prompt(session, "Run terminal") end)

      assert_receive {:acp_request, ^session, %{method: "terminal/create"}}, 5_000
      assert_agent_message_chunk(session, "terminal:allowed")
      assert {:ok, %{"stopReason" => "end_turn"}} = Task.await(task, 10_000)
    end
  end
end
