defmodule KiroCockpit.Acp.PortProcessTest do
  @moduledoc """
  Integration test for `KiroCockpit.Acp.PortProcess`.

  Spawns a real `elixir` subprocess running `KiroCockpit.Test.Acp.FakeAgent.main/0`
  and exercises both directions:

    * client → agent request, agent → client response
    * agent → client notification (one-way)
    * agent → client request, client → agent response (the bidirectional bit)
    * RPC error response
    * unknown method (-32601)
    * port exit cleanup
  """

  use ExUnit.Case, async: false

  alias KiroCockpit.Acp.PortProcess

  @fake_agent_entry ~s|KiroCockpit.Test.Acp.FakeAgent.main()|

  setup do
    elixir_path =
      System.find_executable("elixir") || flunk("elixir not on PATH; cannot run port test")

    # Compute -pa flags for every dep + this app's ebin so the spawned VM
    # has Jason and KiroCockpit.Test.Acp.FakeAgent available.
    ebin_dirs =
      Path.wildcard(Path.expand("_build/#{Mix.env()}/lib/*/ebin", File.cwd!()))

    args = Enum.flat_map(ebin_dirs, fn dir -> ["-pa", dir] end) ++ ["-e", @fake_agent_entry]

    {:ok, %{elixir: elixir_path, args: args}}
  end

  describe "lifecycle" do
    test "rejects start_link without :executable" do
      Process.flag(:trap_exit, true)
      assert {:error, {:invalid_option, :executable}} = PortProcess.start_link([])
    end

    test "starts and stops cleanly", %{elixir: elixir, args: args} do
      {:ok, pid} = PortProcess.start_link(executable: elixir, args: args, owner: self())
      assert Process.alive?(pid)
      :ok = PortProcess.stop(pid)
      refute Process.alive?(pid)
    end
  end

  describe "bidirectional JSON-RPC round-trip" do
    setup %{elixir: elixir, args: args} do
      {:ok, pid} = PortProcess.start_link(executable: elixir, args: args, owner: self())
      on_exit(fn -> safe_stop(pid) end)
      {:ok, %{pid: pid}}
    end

    test "request → response, plus inbound notification, plus inbound request → respond",
         %{pid: pid} do
      # 1. Send a `ping` request. The fake agent will reply with `{"pong": true}`,
      #    THEN emit a `session/update` notification, THEN send us a `fs/read`
      #    request that we have to answer.
      assert {:ok, %{"pong" => true}} = PortProcess.request(pid, "ping", %{}, 5_000)

      # 2. Receive the notification (sent right after the ping response).
      assert_receive {:acp_notification, ^pid,
                      %{method: "session/update", params: %{"phase" => "thinking"}}},
                     2_000

      # 3. Receive the agent's inbound request and respond to it.
      assert_receive {:acp_request, ^pid,
                      %{id: req_id, method: "fs/read", params: %{"path" => "/tmp/kiro-fake.txt"}}},
                     2_000

      :ok = PortProcess.respond(pid, req_id, %{"contents" => "hello from client"})

      # 4. The agent emits a final `session/done` notification echoing our reply.
      assert_receive {:acp_notification, ^pid,
                      %{method: "session/done", params: %{"echoed" => "hello from client"}}},
                     2_000
    end

    test "echo request preserves params", %{pid: pid} do
      assert {:ok, %{"x" => 1, "y" => "z"}} =
               PortProcess.request(pid, "echo", %{"x" => 1, "y" => "z"}, 5_000)
    end

    test "RPC error responses surface as {:error, {:rpc_error, ...}}", %{pid: pid} do
      assert {:error,
              {:rpc_error, %{code: -32_000, message: "boom", data: %{"trace" => "synthetic"}}}} =
               PortProcess.request(pid, "boom", %{}, 5_000)
    end

    test "unknown method returns -32601", %{pid: pid} do
      assert {:error, {:rpc_error, %{code: -32_601, message: "Method not found"}}} =
               PortProcess.request(pid, "no_such_method", %{}, 5_000)
    end

    test "notify/3 is fire-and-forget and does not raise", %{pid: pid} do
      assert :ok = PortProcess.notify(pid, "session/cancel", %{"reason" => "user"})
      # No assertion on response — notifications have no reply by definition.
      # We just need the GenServer to remain alive.
      Process.sleep(50)
      assert Process.alive?(pid)
    end

    test "respond_error/3 sends a structured error", %{pid: pid} do
      # Trigger the agent to send us a request, then reply with an error.
      assert {:ok, _} = PortProcess.request(pid, "ping", %{}, 5_000)
      assert_receive {:acp_request, ^pid, %{id: req_id, method: "fs/read"}}, 2_000

      :ok = PortProcess.respond_error(pid, req_id, -32_001, "denied", %{"reason" => "policy"})

      # The fake agent's response handler only fires on success, so we don't get a
      # session/done. Just verify the GenServer didn't choke on the error response.
      Process.sleep(50)
      assert Process.alive?(pid)
    end
  end

  describe "timeout handling" do
    setup %{elixir: elixir, args: args} do
      {:ok, pid} = PortProcess.start_link(executable: elixir, args: args, owner: self())
      os_pid = port_os_pid(pid)
      on_exit(fn -> safe_stop(pid) end)
      {:ok, %{pid: pid, os_pid: os_pid}}
    end

    test "request returns {:error, :timeout} when no reply arrives", %{pid: pid} do
      # `silent` consumes the request and writes nothing. Stdin stays open so
      # the agent is alive — exactly the "agent ignores us" failure mode.
      assert {:error, :timeout} = PortProcess.request(pid, "silent", %{}, 100)
      # GenServer is still healthy after the timeout.
      assert Process.alive?(pid)
    end

    test "timeout test does not leak the child OS process", %{pid: pid, os_pid: os_pid} do
      # Trigger the timeout, then stop the GenServer. The FakeAgent loop reads
      # stdin → sees :eof when the port closes → exits. No orphan child should
      # remain. (Contrast with `/bin/sleep 10`, which ignores stdin entirely.)
      assert {:error, :timeout} = PortProcess.request(pid, "silent", %{}, 50)
      :ok = PortProcess.stop(pid, :normal, 2_000)

      assert eventually_dead?(os_pid, 2_000),
             "child OS pid #{os_pid} still alive after PortProcess stop — leak"
    end

    test "request/4 with :infinity timeout does not crash and waits for a reply",
         %{pid: pid} do
      # Regression: `Process.send_after(_, _, :infinity)` raises ArgumentError.
      # `arm_request_timer/2` must short-circuit on :infinity instead.
      assert {:ok, %{"pong" => true}} = PortProcess.request(pid, "ping", %{}, :infinity)
      # Drain the side effects emitted by `ping`.
      assert_receive {:acp_notification, ^pid, %{method: "session/update"}}, 2_000
      assert_receive {:acp_request, ^pid, %{id: req_id, method: "fs/read"}}, 2_000
      :ok = PortProcess.respond(pid, req_id, %{"contents" => "x"})
      assert_receive {:acp_notification, ^pid, %{method: "session/done"}}, 2_000
    end

    test "request/4 with :infinity resolves with :transport_closed when port stops",
         %{pid: pid} do
      # Pending entry has a nil timer ref. `fail_all_pending/2` must accept
      # that and reply cleanly — no crash on `Process.cancel_timer(nil, _)`.
      task =
        Task.async(fn ->
          PortProcess.request(pid, "silent", %{}, :infinity)
        end)

      # Give the request a beat to land in `:pending`.
      Process.sleep(50)
      :ok = PortProcess.stop(pid, :normal, 2_000)

      assert {:error, :transport_closed} = Task.await(task, 2_000)
    end
  end

  describe "owner default" do
    test "with :owner omitted, caller pid is the owner", %{elixir: elixir, args: args} do
      # Bug being regressed: `:owner` defaulted inside `init/1`, where `self()`
      # is the GenServer pid — making the GenServer its own owner and starving
      # the actual caller of inbound notifications.
      caller = self()
      {:ok, pid} = PortProcess.start_link(executable: elixir, args: args)
      on_exit(fn -> safe_stop(pid) end)

      # Drive the agent to emit a notification AND an inbound request.
      assert {:ok, %{"pong" => true}} = PortProcess.request(pid, "ping", %{}, 5_000)

      # If the bug were back, these would be sitting in the GenServer's mailbox
      # forever and assert_receive would time out.
      assert_receive {:acp_notification, ^pid, %{method: "session/update"}}, 2_000
      assert_receive {:acp_request, ^pid, %{id: _req_id, method: "fs/read"}}, 2_000
      assert self() == caller
    end
  end

  # `on_exit/1` callbacks run in a separate process, so by the time they fire
  # the GenServer's owner-monitor may have already brought it down. Tolerate
  # "no process" exits — they're a successful cleanup, not a failure.
  defp safe_stop(pid) do
    if Process.alive?(pid), do: PortProcess.stop(pid, :normal, 2_000)
  catch
    :exit, _ -> :ok
  end

  defp port_os_pid(pid) do
    %{port: port} = :sys.get_state(pid)
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    os_pid
  end

  # Poll `kill -0 <pid>` (POSIX: probe-without-signal) until the process is
  # gone or `deadline_ms` elapses. Returns true iff the process is gone.
  defp eventually_dead?(os_pid, deadline_ms) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_wait_dead(os_pid, deadline)
  end

  defp do_wait_dead(os_pid, deadline) do
    case System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true) do
      {_out, 0} ->
        if System.monotonic_time(:millisecond) >= deadline do
          false
        else
          Process.sleep(25)
          do_wait_dead(os_pid, deadline)
        end

      {_out, _nonzero} ->
        true
    end
  end

  describe "agent exit" do
    test "clean status-0 exit stops GenServer with reason :normal" do
      true_path = System.find_executable("true") || flunk("`true` not on PATH")

      {:ok, pid} = PortProcess.start_link(executable: true_path, args: [], owner: self())
      ref = Process.monitor(pid)

      assert_receive {:acp_exit, ^pid, 0}, 2_000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    end

    @tag :capture_log
    test "non-zero exit stops GenServer with reason {:port_exited, status}" do
      # Critical for restart semantics: a transient supervisor only restarts
      # on abnormal termination. Stopping :normal here would mean agent
      # crashes silently disappear. We expect — and capture — the GenServer's
      # abnormal-termination report from the error logger.
      false_path = System.find_executable("false") || flunk("`false` not on PATH")

      Process.flag(:trap_exit, true)
      {:ok, pid} = PortProcess.start_link(executable: false_path, args: [], owner: self())
      ref = Process.monitor(pid)

      assert_receive {:acp_exit, ^pid, 1}, 2_000
      assert_receive {:DOWN, ^ref, :process, ^pid, {:port_exited, 1}}, 2_000
      # Linked test process also receives the EXIT signal — drain it.
      assert_receive {:EXIT, ^pid, {:port_exited, 1}}, 2_000
    end
  end
end
