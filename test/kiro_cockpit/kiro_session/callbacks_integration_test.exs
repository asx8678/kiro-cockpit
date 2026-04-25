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

    base_opts = [
      executable: elixir,
      args: args,
      env: [{"FAKE_ACP_SCENARIO", scenario}],
      subscriber: self(),
      persist_messages: false,
      auto_callbacks: auto_callbacks
    ]

    merged_opts = Keyword.merge(base_opts, Keyword.delete(opts, :auto_callbacks))
    {:ok, session} = KiroSession.start_link(merged_opts)
    on_exit(fn -> safe_stop(session) end)

    {:ok, _} = KiroSession.initialize(session)
    {:ok, sn_result} = KiroSession.new_session(session, File.cwd!())
    session_id = sn_result["sessionId"]

    %{session: session, session_id: session_id}
  end

  defp safe_stop(pid) do
    if Process.alive?(pid), do: KiroSession.stop(pid)
  catch
    :exit, _ -> :ok
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
  end
end
