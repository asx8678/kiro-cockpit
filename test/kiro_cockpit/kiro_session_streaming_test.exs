defmodule KiroCockpit.KiroSessionStreamingTest do
  @moduledoc """
  Integration tests for the kiro-1rd streaming layer:

    * normalized `session/update` → `%StreamEvent{}` delivery
    * ordered fanout with monotonic sequence numbers
    * bounded recent-events buffer with deterministic overflow
    * turn discipline (running until `turn_end`, not until prompt RPC result)
    * cancel plumbing (request → notification → state transition)

  These spawn real `elixir` subprocesses running `KiroCockpit.Test.Acp.FakeAgent`
  with various `FAKE_ACP_SCENARIO` env values.
  """

  use ExUnit.Case, async: false

  alias KiroCockpit.KiroSession
  alias KiroCockpit.KiroSession.StreamEvent

  @fake_agent_entry ~s|KiroCockpit.Test.Acp.FakeAgent.main()|

  # -- Setup helpers --------------------------------------------------------

  defp start_session!(scenario, opts \\ []) do
    elixir = System.find_executable("elixir") || flunk("elixir not on PATH")

    ebin_dirs =
      Path.wildcard(Path.expand("_build/#{Mix.env()}/lib/*/ebin", File.cwd!()))

    args = Enum.flat_map(ebin_dirs, fn dir -> ["-pa", dir] end) ++ ["-e", @fake_agent_entry]

    base_opts = [
      executable: elixir,
      args: args,
      env: [{"FAKE_ACP_SCENARIO", scenario}],
      subscriber: self(),
      persist_messages: false
    ]

    {:ok, session} = KiroSession.start_link(Keyword.merge(base_opts, opts))
    on_exit(fn -> safe_stop(session) end)

    {:ok, _} = KiroSession.initialize(session)
    {:ok, sn_result} = KiroSession.new_session(session, File.cwd!())
    session_id = sn_result["sessionId"]

    # NOTE: FakeAgent's session/new does NOT emit a session/update
    # notification (unlike FakeLifecycleAgent). Don't bother draining
    # mailbox slots that won't be filled — that was costing us 2-4s per
    # test setup against a non-existent drain (Shepherd SHOULD fix).

    %{session: session, session_id: session_id}
  end

  defp safe_stop(pid) do
    if Process.alive?(pid), do: KiroSession.stop(pid)
  catch
    :exit, _ -> :ok
  end

  # -- Stream event collection helpers --------------------------------------
  #
  # All collectors are designed to terminate as soon as the agent goes
  # quiet rather than blocking the full timeout. The deterministic
  # FakeAgent finishes within tens of ms on a hot test box; sleeping for
  # 1.5s per test was pure waste.

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

  # Collect stream events up to and including the first event whose `kind`
  # is in `terminal_kinds`. Returns the accumulated events in arrival
  # order. If `timeout` elapses first, returns whatever arrived.
  defp collect_until_kind(session, terminal_kinds, timeout)
       when is_list(terminal_kinds) do
    do_collect_until_kind(session, terminal_kinds, timeout, [])
  end

  defp do_collect_until_kind(session, terminal_kinds, timeout, acc) do
    receive do
      {:kiro_stream_event, ^session, %StreamEvent{kind: kind} = ev} ->
        acc = [ev | acc]

        if kind in terminal_kinds do
          Enum.reverse(acc)
        else
          do_collect_until_kind(session, terminal_kinds, timeout, acc)
        end
    after
      timeout -> Enum.reverse(acc)
    end
  end

  # -- Stream event delivery ------------------------------------------------

  describe "stream event delivery" do
    test "every session/update notification produces both legacy and normalized messages" do
      %{session: session} = start_session!("normal")

      task = Task.async(fn -> KiroSession.prompt(session, "hi") end)

      # We expect at least one of each (interleaved) — the normal scenario
      # emits 3 session/update notifications.
      assert_receive {:acp_notification, ^session, %{method: "session/update"}}, 2_000
      assert_receive {:kiro_stream_event, ^session, %StreamEvent{}}, 2_000

      assert {:ok, _} = Task.await(task, 5_000)
    end

    test "session_id on the event matches the prompt's sessionId" do
      %{session: session, session_id: sid} = start_session!("normal")

      task = Task.async(fn -> KiroSession.prompt(session, "hi") end)
      assert {:ok, _} = Task.await(task, 5_000)
      events = drain_stream_events(session)

      assert events != []
      for ev <- events, do: assert(ev.session_id == sid)
    end

    test "kinds for the normal scenario include :agent_message_chunk and :agent_thought_chunk" do
      %{session: session} = start_session!("normal")

      task = Task.async(fn -> KiroSession.prompt(session, "hi") end)
      assert {:ok, _} = Task.await(task, 5_000)
      events = drain_stream_events(session)

      kinds = Enum.map(events, & &1.kind)
      assert :agent_message_chunk in kinds
      assert :agent_thought_chunk in kinds
    end

    test "kinds for long_turn scenario include :turn_end" do
      %{session: session} = start_session!("long_turn")

      task = Task.async(fn -> KiroSession.prompt(session, "hi") end)
      assert {:ok, _} = Task.await(task, 5_000)
      # long_turn scenario emits turn_end as the last event — wait for it
      # explicitly rather than sleeping for a fixed window.
      events = collect_until_kind(session, [:turn_end], 2_000)

      kinds = Enum.map(events, & &1.kind)
      assert :turn_end in kinds
    end
  end

  # -- Ordered delivery + monotonic sequence -------------------------------

  describe "ordered delivery" do
    test "sequence numbers are strictly monotonic and start from initial state" do
      %{session: session} = start_session!("normal")

      # FakeAgent's session/new emits no notification, so the stream
      # sequence cursor starts at 0 here.
      initial_state = KiroSession.state(session)
      start_seq = initial_state.stream_sequence

      task = Task.async(fn -> KiroSession.prompt(session, "hi") end)
      assert {:ok, _} = Task.await(task, 5_000)
      events = drain_stream_events(session)

      assert length(events) >= 3, "expected at least 3 events, got #{inspect(events)}"

      seqs = Enum.map(events, & &1.sequence)
      assert hd(seqs) == start_seq, "first event seq must equal pre-prompt sequence cursor"

      # Strictly monotonic by 1
      Enum.zip(seqs, tl(seqs))
      |> Enum.each(fn {a, b} ->
        assert b == a + 1, "sequence not monotonic: #{a} → #{b} (full: #{inspect(seqs)})"
      end)
    end

    test "multiple prompts continue the same monotonic sequence" do
      # Use long_turn so each turn closes with a normalized :turn_end
      # event, satisfying the active-turn guard before the second prompt
      # is issued. (Active-turn guard is the kiro-1rd Shepherd MUST fix.)
      %{session: session} = start_session!("long_turn")

      assert {:ok, _} =
               Task.async(fn -> KiroSession.prompt(session, "first") end)
               |> Task.await(5_000)

      events_a = collect_until_kind(session, [:turn_end], 2_000)
      assert List.last(events_a).kind == :turn_end
      assert KiroSession.state(session).turn_status == :complete

      assert {:ok, _} =
               Task.async(fn -> KiroSession.prompt(session, "second") end)
               |> Task.await(5_000)

      events_b = collect_until_kind(session, [:turn_end], 2_000)
      assert List.last(events_b).kind == :turn_end

      all_seqs = Enum.map(events_a ++ events_b, & &1.sequence)
      assert all_seqs == Enum.sort(all_seqs)
      # All unique
      assert length(Enum.uniq(all_seqs)) == length(all_seqs)
    end

    test "long_turn delivers events strictly in arrival order (not by kind)" do
      %{session: session} = start_session!("long_turn")

      task = Task.async(fn -> KiroSession.prompt(session, "hi") end)
      assert {:ok, _} = Task.await(task, 5_000)
      events = collect_until_kind(session, [:turn_end], 2_000)

      # Per FakeAgent long_turn: chunk → (prompt result lands here) → chunk → turn_end
      kinds = Enum.map(events, & &1.kind)
      assert :turn_end == List.last(kinds), "turn_end must be the last event"
      assert Enum.count(kinds, &(&1 == :agent_message_chunk)) >= 2
    end
  end

  # -- Bounded buffer / overflow ------------------------------------------

  describe "bounded recent-events buffer" do
    test "buffer caps at :stream_buffer_limit and drops oldest on overflow" do
      # normal scenario emits 3 session/update notifications during a prompt.
      # With limit=2, we expect the oldest to be evicted.
      %{session: session} = start_session!("normal", stream_buffer_limit: 2)

      task = Task.async(fn -> KiroSession.prompt(session, "hi") end)
      assert {:ok, _} = Task.await(task, 5_000)
      _events = drain_stream_events(session)

      state = KiroSession.state(session)
      assert state.stream_buffer_limit == 2
      assert state.stream_buffer_size == 2
      assert state.stream_dropped_count >= 1

      recent = KiroSession.recent_stream_events(session)
      assert length(recent) == 2

      # The buffer holds the MOST RECENT events. For normal scenario the
      # last event is the third agent_message_chunk.
      assert List.last(recent).kind == :agent_message_chunk
    end

    test "subscriber receives a {:kiro_stream_overflow, _, n} marker per drop" do
      %{session: session} = start_session!("normal", stream_buffer_limit: 1)

      task = Task.async(fn -> KiroSession.prompt(session, "hi") end)
      assert {:ok, _} = Task.await(task, 5_000)

      # Drain stream events; we don't care about their content here.
      _ = drain_stream_events(session)

      # Collect overflow markers.
      markers = collect_overflow_markers(session, 100)

      assert markers != [], "expected at least one overflow marker"
      assert Enum.all?(markers, &is_integer/1)

      # The marker values must be strictly increasing (each is the running
      # total dropped count).
      assert markers == Enum.sort(markers)
      assert length(Enum.uniq(markers)) == length(markers)
    end

    test "default buffer limit is large enough that normal flow does not drop" do
      %{session: session} = start_session!("normal")

      task = Task.async(fn -> KiroSession.prompt(session, "hi") end)
      assert {:ok, _} = Task.await(task, 5_000)
      _ = drain_stream_events(session)

      state = KiroSession.state(session)
      assert state.stream_dropped_count == 0
      assert state.stream_buffer_size >= 3
    end

    test "rejects invalid :stream_buffer_limit at start_link" do
      Process.flag(:trap_exit, true)

      assert {:error, {:invalid_option, {:stream_buffer_limit, 0}}} =
               KiroSession.start_link(
                 executable: System.find_executable("true") || "/usr/bin/true",
                 stream_buffer_limit: 0,
                 subscriber: self(),
                 persist_messages: false
               )

      assert {:error, {:invalid_option, {:stream_buffer_limit, :nope}}} =
               KiroSession.start_link(
                 executable: System.find_executable("true") || "/usr/bin/true",
                 stream_buffer_limit: :nope,
                 subscriber: self(),
                 persist_messages: false
               )
    end

    defp collect_overflow_markers(session, timeout) do
      deadline = System.monotonic_time(:millisecond) + timeout
      do_collect_overflow(session, deadline, [])
    end

    defp do_collect_overflow(session, deadline, acc) do
      remaining = max(deadline - System.monotonic_time(:millisecond), 0)

      receive do
        {:kiro_stream_overflow, ^session, n} ->
          do_collect_overflow(session, deadline, [n | acc])
      after
        remaining -> Enum.reverse(acc)
      end
    end
  end

  # -- Turn discipline (long_turn) ----------------------------------------

  describe "turn discipline" do
    test "turn_status starts :idle on a fresh session" do
      %{session: session} = start_session!("normal")
      assert KiroSession.state(session).turn_status == :idle
    end

    test "turn_status flips to :running when prompt/3 is in flight" do
      %{session: session} = start_session!("long_turn")

      # Spawn the prompt; while it's flying the GenServer is :running.
      task = Task.async(fn -> KiroSession.prompt(session, "hi", timeout: :infinity) end)

      # Wait for the very first stream event to land — that proves the
      # prompt RPC has been sent and the agent is mid-turn (no fixed
      # sleep needed).
      assert_receive {:kiro_stream_event, ^session, %StreamEvent{}}, 2_000

      state = KiroSession.state(session)
      assert state.turn_status in [:running, :complete]
      assert state.turn_id == 1

      # Drain everything to completion to keep things tidy.
      _ = Task.await(task, 5_000)
      _ = drain_stream_events(session)
    end

    test "prompt RPC result alone does NOT mark turn :complete (kiro-011 regression)" do
      # The cleanest deterministic proof of the headline invariant:
      # the `normal` scenario emits chunks + a prompt result with stopReason
      # "end_turn" but NEVER emits a turn_end notification. If the prompt
      # RPC result alone marked the turn complete, turn_status would be
      # :complete after Task.await. We assert :running to prove it does NOT.
      #
      # This is plan2.md §17 / §30.4 gold-memory rule:
      #   "Do not mark Kiro turns complete from session/prompt response
      #   alone. Wait for session/update turn_end."
      %{session: session} = start_session!("normal")

      task = Task.async(fn -> KiroSession.prompt(session, "hi") end)
      assert {:ok, %{"stopReason" => "end_turn"}} = Task.await(task, 5_000)

      # Drain any in-flight stream events to ensure the GenServer has
      # processed everything in its mailbox before we read state.
      _ = drain_stream_events(session)

      state = KiroSession.state(session)

      assert state.turn_status == :running,
             "turn_status must NOT flip on prompt RPC result alone " <>
               "(got #{inspect(state.turn_status)}); this is kiro-011."

      assert state.last_stop_reason == "end_turn",
             "last_stop_reason should be recorded from prompt RPC result"

      assert state.turn_id == 1
    end

    test "long_turn: prompt result records stop_reason; turn_end completes the turn" do
      # Companion test: when turn_end DOES arrive (long_turn scenario),
      # turn_status flips to :complete. last_stop_reason still reflects
      # the prompt RPC's stopReason.
      %{session: session} = start_session!("long_turn")

      task = Task.async(fn -> KiroSession.prompt(session, "hi") end)
      assert {:ok, %{"stopReason" => "end_turn"}} = Task.await(task, 5_000)

      events = collect_until_kind(session, [:turn_end], 2_000)
      kinds = Enum.map(events, & &1.kind)
      assert :turn_end in kinds, "long_turn scenario must emit turn_end"

      final = KiroSession.state(session)
      assert final.turn_status == :complete
      assert final.last_stop_reason == "end_turn"
    end

    test "state/1 exposes all turn + stream fields" do
      %{session: session} = start_session!("normal")

      state = KiroSession.state(session)

      assert Map.has_key?(state, :turn_id)
      assert Map.has_key?(state, :turn_status)
      assert Map.has_key?(state, :last_stop_reason)
      assert Map.has_key?(state, :stream_sequence)
      assert Map.has_key?(state, :stream_buffer_size)
      assert Map.has_key?(state, :stream_buffer_limit)
      assert Map.has_key?(state, :stream_dropped_count)
    end
  end

  # -- Cancel plumbing -----------------------------------------------------

  describe "cancel/2" do
    test "returns {:error, :no_active_turn} when idle" do
      %{session: session} = start_session!("normal")
      assert {:error, :no_active_turn} = KiroSession.cancel(session)
    end

    test "during a running turn: marks :cancel_requested, sends notification, agent observes it" do
      # The :cancel scenario in FakeAgent BLOCKS reading stdin until it sees
      # session/cancel. This is end-to-end proof that the notification was
      # actually delivered to the agent's stdin.
      %{session: session, session_id: sid} = start_session!("cancel")

      task = Task.async(fn -> KiroSession.prompt(session, "long-running task") end)

      # Wait for the initial chunk so we know the agent is in its blocking read.
      assert_receive {:kiro_stream_event, ^session,
                      %StreamEvent{kind: :agent_message_chunk, session_id: ^sid}},
                     2_000

      # Cancel is synchronous: state must be :cancel_requested on return.
      assert :ok = KiroSession.cancel(session)
      assert KiroSession.state(session).turn_status == :cancel_requested

      # The fact that the prompt eventually returns proves the agent
      # received and acted on session/cancel (it was blocked waiting for it).
      assert {:ok, %{"stopReason" => "cancelled"}} = Task.await(task, 5_000)

      # turn_end with reason cancelled is the next stream event.
      events = collect_until_kind(session, [:turn_end], 2_000)
      assert Enum.any?(events, fn e -> e.kind == :turn_end end)

      final = KiroSession.state(session)
      assert final.turn_status == :complete

      # last_stop_reason carries the cancelled signal.
      assert final.last_stop_reason in ["cancelled"]
    end

    test "is idempotent: second cancel during cancel_requested also returns :ok" do
      %{session: session} = start_session!("cancel")

      task = Task.async(fn -> KiroSession.prompt(session, "x") end)

      assert_receive {:kiro_stream_event, ^session, %StreamEvent{kind: :agent_message_chunk}},
                     2_000

      assert :ok = KiroSession.cancel(session)
      assert :ok = KiroSession.cancel(session)
      assert KiroSession.state(session).turn_status == :cancel_requested

      assert {:ok, _} = Task.await(task, 5_000)
    end

    test "rejects cancel from :uninitialized phase" do
      elixir = System.find_executable("elixir") || flunk("elixir not on PATH")

      ebin_dirs =
        Path.wildcard(Path.expand("_build/#{Mix.env()}/lib/*/ebin", File.cwd!()))

      args = Enum.flat_map(ebin_dirs, fn dir -> ["-pa", dir] end) ++ ["-e", @fake_agent_entry]

      {:ok, session} =
        KiroSession.start_link(
          executable: elixir,
          args: args,
          env: [{"FAKE_ACP_SCENARIO", "normal"}],
          subscriber: self(),
          persist_messages: false
        )

      on_exit(fn -> safe_stop(session) end)

      assert {:error, {:invalid_phase, :uninitialized}} = KiroSession.cancel(session)
    end
  end

  # -- recent_stream_events/2 ----------------------------------------------

  describe "recent_stream_events/2" do
    test "returns events oldest-first" do
      %{session: session} = start_session!("normal")

      task = Task.async(fn -> KiroSession.prompt(session, "hi") end)
      assert {:ok, _} = Task.await(task, 5_000)
      _ = drain_stream_events(session)

      events = KiroSession.recent_stream_events(session)
      seqs = Enum.map(events, & &1.sequence)
      assert seqs == Enum.sort(seqs)
    end

    test "honours :limit option (most recent N)" do
      %{session: session} = start_session!("normal")

      task = Task.async(fn -> KiroSession.prompt(session, "hi") end)
      assert {:ok, _} = Task.await(task, 5_000)
      _ = drain_stream_events(session)

      limited = KiroSession.recent_stream_events(session, limit: 1)
      assert length(limited) == 1
      # That one must be the LAST one in the buffer.
      all = KiroSession.recent_stream_events(session)
      assert hd(limited) == List.last(all)
    end

    test "returns [] for a session that has received no stream events" do
      %{session: session} = start_session!("normal")
      assert KiroSession.recent_stream_events(session) == []
    end

    test "rejects invalid :limit with {:error, {:invalid_option, _}} (does not crash)" do
      # An invalid `:limit` is a caller bug, not a runtime fault. The
      # GenServer must keep serving — it returns the structured error and
      # accepts further calls. (Shepherd SHOULD fix.)
      %{session: session} = start_session!("normal")

      assert {:error, {:invalid_option, {:limit, :nope}}} =
               KiroSession.recent_stream_events(session, limit: :nope)

      assert {:error, {:invalid_option, {:limit, -1}}} =
               KiroSession.recent_stream_events(session, limit: -1)

      assert {:error, {:invalid_option, {:limit, "5"}}} =
               KiroSession.recent_stream_events(session, limit: "5")

      # Still alive and serving valid calls.
      assert Process.alive?(session)
      assert KiroSession.recent_stream_events(session) == []
    end
  end

  # -- Active-turn prompt guard (kiro-1rd Shepherd MUST fix) ---------------

  describe "active-turn prompt guard" do
    test "rejects a second prompt while turn_status is :running (no turn_end yet)" do
      # `normal` scenario sends a prompt RPC result with stopReason
      # "end_turn" but NEVER emits a turn_end notification. After the
      # first prompt's RPC returns, `pending_prompt` is cleared but
      # `turn_status` stays :running. A second prompt issued at this
      # point MUST be rejected with `{:error, :turn_in_progress}` —
      # otherwise we'd start a new turn while the previous one is
      # logically still in flight.
      %{session: session} = start_session!("normal")

      assert {:ok, %{"stopReason" => "end_turn"}} =
               Task.async(fn -> KiroSession.prompt(session, "first") end)
               |> Task.await(5_000)

      # Drain to ensure the GenServer has processed everything; turn_status
      # is still :running because no turn_end has been emitted.
      _ = drain_stream_events(session)
      assert KiroSession.state(session).turn_status == :running

      assert {:error, :turn_in_progress} = KiroSession.prompt(session, "second")
      assert {:error, :turn_in_progress} = KiroSession.prompt(session, "third")

      # State unchanged — guard is purely declarative.
      state = KiroSession.state(session)
      assert state.turn_status == :running
      assert state.turn_id == 1
    end

    test "a later prompt proceeds once turn_end has landed (long_turn)" do
      # `long_turn` emits chunk → prompt result → chunk → turn_end. After
      # the turn_end stream event arrives, `turn_status` flips to
      # :complete and the next prompt is allowed.
      %{session: session} = start_session!("long_turn")

      assert {:ok, _} =
               Task.async(fn -> KiroSession.prompt(session, "first") end)
               |> Task.await(5_000)

      events = collect_until_kind(session, [:turn_end], 2_000)
      assert List.last(events).kind == :turn_end
      assert KiroSession.state(session).turn_status == :complete

      # Second prompt is allowed now.
      assert {:ok, _} =
               Task.async(fn -> KiroSession.prompt(session, "second") end)
               |> Task.await(5_000)

      assert KiroSession.state(session).turn_id == 2
    end

    test ":prompt_in_progress takes precedence over :turn_in_progress" do
      # Sanity check: if there's still a pending RPC in flight, the
      # GenServer reports `:prompt_in_progress`, not `:turn_in_progress`.
      # The two error atoms are distinct and stable.
      #
      # The guard arm `turn_status in [:running, :cancel_requested]`
      # collapses both running and cancel_requested into the same
      # `:turn_in_progress` reply, but it only fires once the RPC has
      # cleared (`pending_prompt: nil`). Cancel-during-RPC is naturally
      # covered by the `:prompt_in_progress` clause at higher priority.
      %{session: session} = start_session!("cancel")

      task = Task.async(fn -> KiroSession.prompt(session, "first") end)

      # The cancel scenario blocks reading stdin until session/cancel is
      # received, so the prompt RPC is still in flight here.
      assert_receive {:kiro_stream_event, ^session, %StreamEvent{kind: :agent_message_chunk}},
                     2_000

      assert {:error, :prompt_in_progress} = KiroSession.prompt(session, "second")

      # Clean up.
      assert :ok = KiroSession.cancel(session)
      assert {:ok, _} = Task.await(task, 5_000)
      _ = collect_until_kind(session, [:turn_end], 2_000)
    end
  end
end
