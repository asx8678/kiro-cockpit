defmodule KiroCockpit.KiroSession.TerminalManagerTest do
  @moduledoc """
  Unit tests for `KiroCockpit.KiroSession.TerminalManager`.

  Tests terminal lifecycle: create, output, wait_for_exit, kill, release
  with deterministic OS commands (echo, cat, sleep, true, etc.).

  These tests are `async: false` because they spawn real OS processes
  and may share global resources.
  """

  use ExUnit.Case, async: false

  alias KiroCockpit.KiroSession.TerminalManager

  setup do
    {:ok, tm} = TerminalManager.start_link()
    on_exit(fn -> safe_stop(tm) end)
    {:ok, tm: tm}
  end

  defp safe_stop(pid) do
    if Process.alive?(pid), do: TerminalManager.stop(pid)
  catch
    :exit, _ -> :ok
  end

  # -- create ----------------------------------------------------------------

  describe "create/6" do
    test "starts a command and returns a terminal ID", %{tm: tm} do
      echo = System.find_executable("echo") || flunk("echo not found")

      assert {:ok, term_id} = TerminalManager.create(tm, echo, ["hello"], nil, [], 1_048_576)
      assert is_binary(term_id)
      assert String.starts_with?(term_id, "term_")
    end

    test "terminal IDs are sequential", %{tm: tm} do
      echo = System.find_executable("echo") || flunk("echo not found")

      assert {:ok, id1} = TerminalManager.create(tm, echo, ["1"], nil, [], 1_048_576)
      assert {:ok, id2} = TerminalManager.create(tm, echo, ["2"], nil, [], 1_048_576)
      assert id1 != id2
    end

    test "returns error for unknown command" do
      # Start a fresh TM for this test to avoid interfering with the setup one
      {:ok, tm2} = TerminalManager.start_link()

      try do
        assert {:error, -32_000, message, nil} =
                 TerminalManager.create(tm2, "nonexistent_cmd_xyz_12345", [], nil, [], 1_048_576)

        assert message =~ "Command not found"
      after
        safe_stop(tm2)
      end
    end

    test "accepts absolute path for command", %{tm: tm} do
      echo = System.find_executable("echo") || flunk("echo not found")

      assert {:ok, _term_id} = TerminalManager.create(tm, echo, ["abs"], nil, [], 1_048_576)
    end

    test "rejects non-absolute cwd" do
      {:ok, tm2} = TerminalManager.start_link()
      echo = System.find_executable("echo") || flunk("echo not found")

      try do
        assert {:error, -32_602, message, nil} =
                 TerminalManager.create(tm2, echo, [], "relative/path", [], 1_048_576)

        assert message =~ "cwd must be an absolute path"
      after
        safe_stop(tm2)
      end
    end

    test "accepts absolute cwd", %{tm: tm} do
      echo = System.find_executable("echo") || flunk("echo not found")
      cwd = System.tmp_dir!()

      assert {:ok, _term_id} = TerminalManager.create(tm, echo, ["test"], cwd, [], 1_048_576)
    end
  end

  # -- output ----------------------------------------------------------------

  describe "output/2" do
    test "returns buffered output from a fast command", %{tm: tm} do
      echo = System.find_executable("echo") || flunk("echo not found")
      {:ok, term_id} = TerminalManager.create(tm, echo, ["hello output"], nil, [], 1_048_576)

      # Give the process time to produce output and exit.
      Process.sleep(100)

      assert {:ok, result} = TerminalManager.output(tm, term_id)
      assert result["output"] =~ "hello output"
      assert result["truncated"] == false
      assert result["exitStatus"] != nil
    end

    test "returns exit status after process exits", %{tm: tm} do
      echo = System.find_executable("echo") || flunk("echo not found")
      {:ok, term_id} = TerminalManager.create(tm, echo, ["bye"], nil, [], 1_048_576)

      # Wait for exit
      assert {:ok, _} = TerminalManager.wait_for_exit(tm, term_id, 5_000)

      assert {:ok, result} = TerminalManager.output(tm, term_id)
      assert result["exitStatus"] != nil
      assert result["exitStatus"]["exitCode"] == 0
    end

    test "returns error for unknown terminal ID", %{tm: tm} do
      assert {:error, -32_000, message, nil} = TerminalManager.output(tm, "term_unknown")
      assert message =~ "Unknown terminal"
    end

    test "truncates output at byte limit", %{tm: tm} do
      # Use printf to generate controlled output
      printf = System.find_executable("printf") || System.find_executable("echo")
      {:ok, term_id} = TerminalManager.create(tm, printf, ["AAAA"], nil, [], 2)

      Process.sleep(100)

      assert {:ok, result} = TerminalManager.output(tm, term_id)
      assert byte_size(result["output"]) <= 2
      assert result["truncated"] == true
    end
  end

  # -- wait_for_exit ---------------------------------------------------------

  describe "wait_for_exit/3" do
    test "returns exit info for a command that already exited", %{tm: tm} do
      echo = System.find_executable("echo") || flunk("echo not found")
      {:ok, term_id} = TerminalManager.create(tm, echo, ["done"], nil, [], 1_048_576)

      # Wait for it to finish.
      assert {:ok, exit_info} = TerminalManager.wait_for_exit(tm, term_id, 5_000)
      assert exit_info["exitCode"] == 0
    end

    test "waits for a long-running command and returns exit info", %{tm: tm} do
      sleep = System.find_executable("sleep") || flunk("sleep not found")
      {:ok, term_id} = TerminalManager.create(tm, sleep, ["0.1"], nil, [], 1_048_576)

      assert {:ok, exit_info} = TerminalManager.wait_for_exit(tm, term_id, 5_000)
      assert exit_info["exitCode"] == 0
    end

    test "returns error on timeout", %{tm: tm} do
      sleep = System.find_executable("sleep") || flunk("sleep not found")
      {:ok, term_id} = TerminalManager.create(tm, sleep, ["30"], nil, [], 1_048_576)

      # Very short timeout — the command won't exit in time.
      assert {:error, -32_000, message, nil} = TerminalManager.wait_for_exit(tm, term_id, 50)
      assert message =~ "timed out"

      # Clean up the long-running terminal
      TerminalManager.release(tm, term_id)
    end

    test "returns error for unknown terminal ID", %{tm: tm} do
      assert {:error, -32_000, _message, nil} =
               TerminalManager.wait_for_exit(tm, "term_unknown", 1_000)
    end
  end

  # -- kill ------------------------------------------------------------------

  describe "kill/2" do
    test "kills a running process", %{tm: tm} do
      sleep = System.find_executable("sleep") || flunk("sleep not found")
      {:ok, term_id} = TerminalManager.create(tm, sleep, ["30"], nil, [], 1_048_576)

      # Process should be running — kill it.
      assert {:ok, nil} = TerminalManager.kill(tm, term_id)

      # Give the OS a moment to deliver the signal.
      Process.sleep(200)

      # The process should now be dead.
      assert {:ok, result} = TerminalManager.output(tm, term_id)
      assert result["exitStatus"] != nil
      # Killed by SIGKILL → exit code > 128 (128 + signal number).
      assert result["exitStatus"]["exitCode"] > 128
    end

    test "kill on already-dead process is a no-op", %{tm: tm} do
      echo = System.find_executable("echo") || flunk("echo not found")
      {:ok, term_id} = TerminalManager.create(tm, echo, ["done"], nil, [], 1_048_576)

      # Wait for it to exit naturally.
      assert {:ok, _} = TerminalManager.wait_for_exit(tm, term_id, 5_000)

      # Kill should be a no-op.
      assert {:ok, nil} = TerminalManager.kill(tm, term_id)
    end

    test "returns error for unknown terminal ID", %{tm: tm} do
      assert {:error, -32_000, _message, nil} = TerminalManager.kill(tm, "term_unknown")
    end
  end

  # -- release ---------------------------------------------------------------

  describe "release/2" do
    test "kills running process and frees resources", %{tm: tm} do
      sleep = System.find_executable("sleep") || flunk("sleep not found")
      {:ok, term_id} = TerminalManager.create(tm, sleep, ["30"], nil, [], 1_048_576)

      assert {:ok, nil} = TerminalManager.release(tm, term_id)

      # The terminal should no longer be accessible.
      assert {:error, -32_000, _message, nil} = TerminalManager.output(tm, term_id)
    end

    test "releases an already-dead process", %{tm: tm} do
      echo = System.find_executable("echo") || flunk("echo not found")
      {:ok, term_id} = TerminalManager.create(tm, echo, ["done"], nil, [], 1_048_576)

      assert {:ok, _} = TerminalManager.wait_for_exit(tm, term_id, 5_000)
      assert {:ok, nil} = TerminalManager.release(tm, term_id)

      # The terminal should no longer be accessible.
      assert {:error, -32_000, _message, nil} = TerminalManager.output(tm, term_id)
    end

    test "returns error for unknown terminal ID", %{tm: tm} do
      assert {:error, -32_000, _message, nil} = TerminalManager.release(tm, "term_unknown")
    end
  end

  # -- Full lifecycle --------------------------------------------------------

  describe "full terminal lifecycle" do
    test "create → output → wait_for_exit → release", %{tm: tm} do
      echo = System.find_executable("echo") || flunk("echo not found")

      # Create
      {:ok, term_id} = TerminalManager.create(tm, echo, ["lifecycle test"], nil, [], 1_048_576)

      # Output (may or may not have data yet — give it a moment)
      Process.sleep(100)
      {:ok, result} = TerminalManager.output(tm, term_id)
      assert result["output"] =~ "lifecycle test"

      # Wait for exit
      {:ok, exit_info} = TerminalManager.wait_for_exit(tm, term_id, 5_000)
      assert exit_info["exitCode"] == 0

      # Release
      assert {:ok, nil} = TerminalManager.release(tm, term_id)

      # Terminal is gone
      assert {:error, -32_000, _, _} = TerminalManager.output(tm, term_id)
    end
  end

  # -- Environment variables --------------------------------------------------

  describe "environment variables" do
    test "agent-supplied env vars are passed to the process", %{tm: tm} do
      sh = System.find_executable("sh") || flunk("sh not found")

      env = [%{"name" => "KIRO_TEST_VAR", "value" => "hello_from_kiro"}]

      {:ok, term_id} =
        TerminalManager.create(
          tm,
          sh,
          ["-c", "echo $KIRO_TEST_VAR"],
          nil,
          env,
          1_048_576
        )

      Process.sleep(200)

      {:ok, result} = TerminalManager.output(tm, term_id)
      assert result["output"] =~ "hello_from_kiro"
    end
  end

  # -- stderr capture ----------------------------------------------------------

  describe "stderr capture" do
    test "captures stderr output merged with stdout", %{tm: tm} do
      sh = System.find_executable("sh") || flunk("sh not found")

      {:ok, term_id} =
        TerminalManager.create(
          tm,
          sh,
          ["-c", "echo stdout_msg; echo stderr_msg >&2"],
          nil,
          [],
          1_048_576
        )

      # Wait for the process to complete.
      assert {:ok, _} = TerminalManager.wait_for_exit(tm, term_id, 5_000)

      {:ok, result} = TerminalManager.output(tm, term_id)
      # Both stdout and stderr should appear in the output buffer
      assert result["output"] =~ "stdout_msg"
      assert result["output"] =~ "stderr_msg"
    end
  end

  # -- Concurrent wait_for_exit ------------------------------------------------

  describe "concurrent wait_for_exit" do
    test "rejects second concurrent wait_for_exit call", %{tm: tm} do
      sleep = System.find_executable("sleep") || flunk("sleep not found")
      {:ok, term_id} = TerminalManager.create(tm, sleep, ["30"], nil, [], 1_048_576)

      # First wait — this will be deferred (process is running)
      task1 =
        Task.async(fn ->
          TerminalManager.wait_for_exit(tm, term_id, 5_000)
        end)

      # Give the first call a moment to register
      Process.sleep(50)

      # Second wait — should be rejected immediately
      assert {:error, -32_000, message, nil} =
               TerminalManager.wait_for_exit(tm, term_id, 1_000)

      assert message =~ "wait_for_exit call is already pending"

      # Clean up — kill the terminal so task1 doesn't hang
      TerminalManager.kill(tm, term_id)
      Task.await(task1, 5_000)
      TerminalManager.release(tm, term_id)
    end
  end
end
