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
    test "request returns {:error, :timeout} when no reply arrives" do
      # `sleep` is universally available and ignores stdin, so any request we
      # write succeeds at the pipe layer but never produces a response.
      sleep_path = System.find_executable("sleep") || flunk("`sleep` not on PATH")

      {:ok, pid} = PortProcess.start_link(executable: sleep_path, args: ["10"], owner: self())
      on_exit(fn -> safe_stop(pid) end)

      assert {:error, :timeout} = PortProcess.request(pid, "no_reply", %{}, 100)
    end
  end

  # `on_exit/1` callbacks run in a separate process, so by the time they fire
  # the GenServer's owner-monitor may have already brought it down. Tolerate
  # "no process" exits — they're a successful cleanup, not a failure.
  defp safe_stop(pid) do
    try do
      if Process.alive?(pid), do: PortProcess.stop(pid, :normal, 2_000)
    catch
      :exit, _ -> :ok
    end
  end

  describe "agent exit" do
    test "owner receives :acp_exit when agent exits", %{elixir: _elixir} do
      # Use `false` (the BSD utility) which exits immediately with status 1,
      # OR `true` which exits 0. Both are universally available.
      true_path = System.find_executable("true") || flunk("`true` not on PATH")

      {:ok, pid} = PortProcess.start_link(executable: true_path, args: [], owner: self())

      assert_receive {:acp_exit, ^pid, status}, 2_000
      assert status in [0, 1]

      # GenServer should stop normally afterwards.
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2_000
    end
  end
end
