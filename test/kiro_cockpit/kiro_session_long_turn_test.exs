defmodule KiroCockpit.KiroSessionLongTurnTest do
  @moduledoc """
  Focused regression test for kiro-011: long-turn discipline.

  The headline invariant: a turn must NOT be marked complete on
  `session/prompt` response alone. The turn remains `:running` until a
  normalized `:turn_end` stream event arrives.

  This test uses `FakeLongTurnAgent` which deliberately withholds `turn_end`
  until the test sends a `test/emit_turn_end` trigger via `KiroSession.notify/3`.
  This eliminates all races and sleeps — the intermediate state where the
  prompt RPC has returned but `turn_end` hasn't arrived is observed
  deterministically.
  """

  use ExUnit.Case, async: false

  alias KiroCockpit.KiroSession
  alias KiroCockpit.KiroSession.StreamEvent

  @fake_agent_entry ~s|KiroCockpit.Test.Acp.FakeLongTurnAgent.main()|

  # -- Setup helpers --------------------------------------------------------

  defp start_session!(opts \\ []) do
    elixir = System.find_executable("elixir") || flunk("elixir not on PATH")

    ebin_dirs =
      Path.wildcard(Path.expand("_build/#{Mix.env()}/lib/*/ebin", File.cwd!()))

    args = Enum.flat_map(ebin_dirs, fn dir -> ["-pa", dir] end) ++ ["-e", @fake_agent_entry]

    base_opts = [
      executable: elixir,
      args: args,
      subscriber: self(),
      persist_messages: false,
      # kiro-egn: test_bypass for non-bypassable action boundary in test env
      test_bypass: true
    ]

    {:ok, session} = KiroSession.start_link(Keyword.merge(base_opts, opts))
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

  # Drain stream events until the mailbox is quiet for `quiet_window` ms
  # (default 80). Bounded by `max_wait` (default 2_000).
  defp drain_stream_events(session, opts \\ []) do
    quiet_window = Keyword.get(opts, :quiet_window, 80)
    max_wait = Keyword.get(opts, :max_wait, 2_000)
    deadline = System.monotonic_time(:millisecond) + max_wait
    do_drain_stream(session, deadline, quiet_window, [])
  end

  defp do_drain_stream(session, deadline, quiet_window, acc) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)
    wait = min(remaining, quiet_window)

    receive do
      {:kiro_stream_event, ^session, %StreamEvent{} = ev} ->
        do_drain_stream(session, deadline, quiet_window, [ev | acc])
    after
      wait -> Enum.reverse(acc)
    end
  end

  # -- Long-turn regression (kiro-011) --------------------------------------

  describe "long-turn regression (kiro-011)" do
    test "turn remains :running after prompt RPC result; turn_end completes it" do
      %{session: session, session_id: sid} = start_session!()

      # 1. Issue a prompt. The fake agent will:
      #    - emit an agent_message_chunk
      #    - respond to session/prompt with stopReason: "end_turn"
      #    - block reading stdin until we send test/emit_turn_end
      task = Task.async(fn -> KiroSession.prompt(session, "hello") end)

      # Wait for the initial chunk so we know the agent is processing.
      assert_receive {:kiro_stream_event, ^session, %StreamEvent{kind: :agent_message_chunk}},
                     2_000

      # 2. The prompt RPC result returns (Task.await succeeds), but
      #    the turn is NOT complete — no turn_end has been emitted.
      assert {:ok, %{"stopReason" => "end_turn"}} = Task.await(task, 5_000)

      # Drain any in-flight stream events to ensure the GenServer has
      # processed everything in its mailbox before we read state.
      _ = drain_stream_events(session)

      # 3. THE KEY INVARIANT: turn_status must be :running, NOT :complete.
      #    If KiroSession were to mark the turn complete from the prompt
      #    RPC result alone, this assertion would fail — and that's exactly
      #    the regression this test is designed to catch.
      state = KiroSession.state(session)

      assert state.turn_status == :running,
             "turn_status must NOT flip on prompt RPC result alone " <>
               "(got #{inspect(state.turn_status)}); this is kiro-011."

      assert state.last_stop_reason == "end_turn",
             "last_stop_reason should be recorded from prompt RPC result"

      assert state.turn_id == 1

      # 4. A second prompt must be rejected — the turn is logically still
      #    in flight even though the RPC has returned.
      assert {:error, :turn_in_progress} = KiroSession.prompt(session, "second"),
             "second prompt must be rejected while turn is running"

      # State unchanged by the rejected prompt.
      assert KiroSession.state(session).turn_status == :running
      assert KiroSession.state(session).turn_id == 1

      # 5. Send the trigger notification. The fake agent is blocking on
      #    stdin waiting for exactly this notification. On receipt, it
      #    emits the turn_end session/update.
      :ok = KiroSession.notify(session, "test/emit_turn_end", %{"sessionId" => sid})

      # 6. Receive the turn_end stream event.
      assert_receive {:kiro_stream_event, ^session, %StreamEvent{kind: :turn_end}}, 2_000

      # 7. Now the turn is complete — turn_end is the only signal that
      #    flips turn_status from :running to :complete.
      final = KiroSession.state(session)

      assert final.turn_status == :complete,
             "turn_status must be :complete after turn_end (got #{inspect(final.turn_status)})"

      assert final.last_stop_reason == "end_turn"
      assert final.turn_id == 1
    end

    test "second prompt succeeds after turn_end completes the first turn" do
      %{session: session, session_id: sid} = start_session!()

      # First turn: prompt → RPC result → trigger turn_end → complete
      task = Task.async(fn -> KiroSession.prompt(session, "first") end)

      assert_receive {:kiro_stream_event, ^session, %StreamEvent{kind: :agent_message_chunk}},
                     2_000

      assert {:ok, %{"stopReason" => "end_turn"}} = Task.await(task, 5_000)
      _ = drain_stream_events(session)

      assert KiroSession.state(session).turn_status == :running

      :ok = KiroSession.notify(session, "test/emit_turn_end", %{"sessionId" => sid})
      assert_receive {:kiro_stream_event, ^session, %StreamEvent{kind: :turn_end}}, 2_000
      assert KiroSession.state(session).turn_status == :complete

      # Second turn: prompt is now allowed (turn_status is :complete).
      task2 = Task.async(fn -> KiroSession.prompt(session, "second") end)

      assert_receive {:kiro_stream_event, ^session, %StreamEvent{kind: :agent_message_chunk}},
                     2_000

      assert {:ok, %{"stopReason" => "end_turn"}} = Task.await(task2, 5_000)
      _ = drain_stream_events(session)

      # Turn 2 is also :running until turn_end.
      state2 = KiroSession.state(session)
      assert state2.turn_status == :running
      assert state2.turn_id == 2

      # Complete turn 2 so the agent doesn't leak :epipe on exit.
      :ok = KiroSession.notify(session, "test/emit_turn_end", %{"sessionId" => sid})
      assert_receive {:kiro_stream_event, ^session, %StreamEvent{kind: :turn_end}}, 2_000
      assert KiroSession.state(session).turn_status == :complete
    end
  end
end
