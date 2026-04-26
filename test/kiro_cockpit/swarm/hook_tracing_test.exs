defmodule KiroCockpit.Swarm.HookTracingTest do
  use KiroCockpit.DataCase, async: true

  alias KiroCockpit.Swarm.{Event, Hook, HookManager, HookResult, TraceContext, Events, HookTrace}
  alias KiroCockpit.Telemetry

  # Helper to attach telemetry handlers for specific events
  defp attach_handler(events) when is_list(events) do
    test_pid = self()
    handler_id = "telemetry-test-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        events,
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  # Fake hook that continues
  defmodule ContinueHook do
    @behaviour Hook

    @impl true
    def name, do: :continue_hook

    @impl true
    def priority, do: 50

    @impl true
    def filter(_event), do: true

    @impl true
    def on_event(event, _ctx) do
      HookResult.continue(event, ["continue hook executed"])
    end
  end

  # Fake hook that blocks
  defmodule BlockHook do
    @behaviour Hook

    @impl true
    def name, do: :block_hook

    @impl true
    def priority, do: 40

    @impl true
    def filter(_event), do: true

    @impl true
    def on_event(event, _ctx) do
      HookResult.block(event, "blocked by test", ["block hook executed"])
    end
  end

  # Fake hook that raises an exception
  defmodule ExceptionHook do
    @behaviour Hook

    @impl true
    def name, do: :exception_hook

    @impl true
    def priority, do: 30

    @impl true
    def filter(_event), do: true

    @impl true
    def on_event(_event, _ctx) do
      raise "intentional exception"
    end
  end

  # Fake hook that modifies the event
  defmodule ModifyHook do
    @behaviour Hook

    @impl true
    def name, do: :modify_hook

    @impl true
    def priority, do: 60

    @impl true
    def filter(_event), do: true

    @impl true
    def on_event(event, _ctx) do
      modified = %{event | payload: Map.put(event.payload, :modified, true)}
      HookResult.modify(modified, ["modify hook executed"])
    end
  end

  describe "hook chain telemetry" do
    test "emits chain start and stop events with correlation metadata" do
      event =
        Event.new(:test_action,
          session_id: "sess_123",
          plan_id: "plan_456",
          task_id: "task_789",
          agent_id: "agent"
        )

      hooks = [ContinueHook]

      chain_start = Telemetry.event(:hook, :chain, :start)
      chain_stop = Telemetry.event(:hook, :chain, :stop)
      attach_handler([chain_start, chain_stop])

      # Run the hook chain (pre-phase)
      {:ok, _final_event, _messages} = HookManager.run(event, hooks, %{}, :pre)

      # Assert start event
      assert_receive {:telemetry, ^chain_start, start_measurements, start_meta}
      assert is_integer(start_measurements.monotonic_time)
      assert start_meta.session_id == "sess_123"
      assert start_meta.plan_id == "plan_456"
      assert start_meta.task_id == "task_789"
      assert start_meta.agent_id == "agent"
      assert start_meta.action_name == :test_action
      assert start_meta.phase == :pre

      # Assert stop event
      assert_receive {:telemetry, ^chain_stop, stop_measurements, stop_meta}
      assert is_integer(stop_measurements.duration)
      assert stop_meta.session_id == "sess_123"
      assert stop_meta.plan_id == "plan_456"
      assert stop_meta.task_id == "task_789"
      assert stop_meta.agent_id == "agent"
      assert stop_meta.action_name == :test_action
      assert stop_meta.phase == :pre
    end

    test "emits per-hook stop event for continue decision" do
      event = Event.new(:test_action)
      hooks = [ContinueHook]

      hook_run_start = Telemetry.event(:hook, :run, :start)
      hook_run_stop = Telemetry.event(:hook, :run, :stop)
      attach_handler([hook_run_start, hook_run_stop])

      {:ok, _final_event, _messages} = HookManager.run(event, hooks, %{}, :pre)

      # Expect start and stop for the single hook
      assert_receive {:telemetry, ^hook_run_start, _, meta}
      assert meta.hook_name == :continue_hook
      assert meta.priority == 50

      assert_receive {:telemetry, ^hook_run_stop, stop_measurements, stop_meta}
      assert is_integer(stop_measurements.duration)
      assert stop_meta.decision == :continue
    end

    test "emits per-hook stop event for block decision" do
      event = Event.new(:test_action)
      hooks = [BlockHook]

      hook_run_stop = Telemetry.event(:hook, :run, :stop)
      attach_handler([hook_run_stop])

      {:blocked, _final_event, _reason, _messages} = HookManager.run(event, hooks, %{}, :pre)

      assert_receive {:telemetry, ^hook_run_stop, stop_measurements, stop_meta}
      assert is_integer(stop_measurements.duration)
      assert stop_meta.decision == :block
    end

    test "emits per-hook exception event when hook raises" do
      event = Event.new(:test_action)
      hooks = [ExceptionHook]

      hook_run_exception = Telemetry.event(:hook, :run, :exception)
      attach_handler([hook_run_exception])

      # The hook chain will treat the exception as a block (our implementation)
      {:blocked, _final_event, _reason, _messages} = HookManager.run(event, hooks, %{}, :pre)

      assert_receive {:telemetry, ^hook_run_exception, exc_measurements, exc_meta}
      assert is_integer(exc_measurements.duration)
      assert exc_meta.hook_name == :exception_hook
      assert inspect(exc_meta.reason) =~ "intentional exception"
    end

    test "trace context propagation (trace_id and span_id present)" do
      trace_ctx = TraceContext.new()
      event = Event.new(:test_action, trace_context: trace_ctx)
      hooks = [ContinueHook]

      chain_start = Telemetry.event(:hook, :chain, :start)
      attach_handler([chain_start])

      {:ok, _final_event, _messages} = HookManager.run(event, hooks, %{}, :pre)

      assert_receive {:telemetry, ^chain_start, _, meta}
      assert meta.trace_id == trace_ctx.trace_id
      assert meta.span_id == trace_ctx.span_id
    end

    test "HookTrace.maybe_persist_trace inserts Bronze event without persist_hook_trace? opt-in (kiro-f77)" do
      session_id = "sess_mandatory_#{System.unique_integer([:positive])}"
      plan_id = Ecto.UUID.generate()
      task_id = Ecto.UUID.generate()

      event =
        Event.new(:test_action,
          session_id: session_id,
          plan_id: plan_id,
          task_id: task_id,
          agent_id: "agent"
        )

      hook_results = [%{"hook" => "block_hook", "decision" => "block"}]
      trace_summary = HookTrace.chain_summary(event, hook_results, :blocked, "blocked by test", 0)
      # No persist_hook_trace? flag — mandatory Bronze capture ignores it
      ctx = %{phase: :pre}

      assert :ok = HookTrace.maybe_persist_trace(event, trace_summary, ctx)

      events = Events.list_by_session(session_id, limit: 10)
      assert length(events) == 1
      bronze_event = List.first(events)
      assert bronze_event.event_type == "hook_trace"
      assert bronze_event.session_id == session_id
      assert bronze_event.plan_id == plan_id
      assert bronze_event.task_id == task_id
      assert bronze_event.agent_id == "agent"
      assert bronze_event.phase == "pre"
      assert is_map(bronze_event.hook_results)
      assert is_list(bronze_event.hook_results["hook_results"])
      hook_result = List.first(bronze_event.hook_results["hook_results"])
      assert hook_result["hook"] == "block_hook"
      assert hook_result["decision"] == "block"
    end

    test "HookTrace.maybe_persist_trace still works when legacy persist_hook_trace? is true" do
      session_id = "sess_legacy_#{System.unique_integer([:positive])}"
      plan_id = Ecto.UUID.generate()
      task_id = Ecto.UUID.generate()

      event =
        Event.new(:test_action,
          session_id: session_id,
          plan_id: plan_id,
          task_id: task_id,
          agent_id: "agent"
        )

      hook_results = [%{"hook" => "block_hook", "decision" => "block"}]
      trace_summary = HookTrace.chain_summary(event, hook_results, :blocked, "blocked by test", 0)
      ctx = %{persist_hook_trace?: true, phase: :pre}

      assert :ok = HookTrace.maybe_persist_trace(event, trace_summary, ctx)

      events = Events.list_by_session(session_id, limit: 10)
      assert length(events) == 1
      bronze_event = List.first(events)
      assert bronze_event.event_type == "hook_trace"
      assert bronze_event.session_id == session_id
    end

    test "HookTrace.chain_summary omits nil phase and includes explicit phase" do
      event = Event.new(:test_action, session_id: "sess_phase", agent_id: "agent")
      hook_results = [%{"hook" => "continue_hook", "decision" => "continue"}]

      summary_without_phase = HookTrace.chain_summary(event, hook_results, :ok, nil, 12)

      refute Map.has_key?(summary_without_phase, "phase")
      assert summary_without_phase["duration_ms"] == 12
      assert summary_without_phase["hook_results"] == hook_results

      summary_with_phase = HookTrace.chain_summary(event, hook_results, :ok, nil, 12, :pre)

      assert summary_with_phase["phase"] == "pre"
    end

    test "HookTrace.maybe_persist_trace defaults missing ctx phase to lifecycle" do
      session_id = "sess_#{System.unique_integer([:positive])}"

      event = Event.new(:test_action, session_id: session_id, agent_id: "agent")
      trace_summary = HookTrace.chain_summary(event, [], :ok)
      ctx = %{persist_hook_trace?: true}

      assert :ok = HookTrace.maybe_persist_trace(event, trace_summary, ctx)

      [bronze_event] = Events.list_by_session(session_id, limit: 10)
      assert bronze_event.event_type == "hook_trace"
      assert bronze_event.phase == "lifecycle"
    end

    test "HookTrace.maybe_persist_trace emits telemetry and does not crash on persistence errors" do
      persistence_exception = Telemetry.event(:hook, :persistence, :exception)
      attach_handler([persistence_exception])

      event = Event.new(:test_action)
      trace_summary = HookTrace.chain_summary(event, [], :blocked, "missing correlation")

      # No opt-in needed — mandatory persistence, but missing session_id/agent_id
      # triggers validation error that must be caught
      assert :ok = HookTrace.maybe_persist_trace(event, trace_summary, %{phase: :pre})

      assert_receive {:telemetry, ^persistence_exception, measurements, metadata}
      assert measurements.count == 1
      assert metadata == %{}
    end

    test "HookManager.run persists hook trace without opt-in ctx (kiro-f77 mandatory)" do
      session_id = "sess_run_mandatory_#{System.unique_integer([:positive])}"
      plan_id = Ecto.UUID.generate()
      task_id = Ecto.UUID.generate()

      event =
        Event.new(:test_action,
          session_id: session_id,
          plan_id: plan_id,
          task_id: task_id,
          agent_id: "agent"
        )

      hooks = [BlockHook]
      # Empty ctx — no persist_hook_trace? flag
      ctx = %{}

      assert {:blocked, _final_event, _reason, _messages} =
               HookManager.run(event, hooks, ctx, :pre)

      events = Events.list_by_session(session_id, limit: 10)
      assert length(events) == 1
      bronze_event = List.first(events)
      assert bronze_event.event_type == "hook_trace"
      assert bronze_event.session_id == session_id
      assert bronze_event.plan_id == plan_id
      assert bronze_event.task_id == task_id
      assert bronze_event.agent_id == "agent"
      assert bronze_event.phase == "pre"
      assert is_map(bronze_event.hook_results)
      assert is_list(bronze_event.hook_results["hook_results"])
      hook_result = List.first(bronze_event.hook_results["hook_results"])
      assert hook_result["hook"] == "block_hook"
      assert hook_result["decision"] == "block"
    end

    test "HookManager.run persists continue outcome without opt-in" do
      session_id = "sess_run_continue_#{System.unique_integer([:positive])}"
      plan_id = Ecto.UUID.generate()
      task_id = Ecto.UUID.generate()

      event =
        Event.new(:test_action,
          session_id: session_id,
          plan_id: plan_id,
          task_id: task_id,
          agent_id: "agent"
        )

      hooks = [ContinueHook]
      ctx = %{}

      assert {:ok, _final_event, _messages} =
               HookManager.run(event, hooks, ctx, :pre)

      events = Events.list_by_session(session_id, limit: 10)
      assert length(events) == 1
      bronze_event = List.first(events)
      assert bronze_event.event_type == "hook_trace"
      assert bronze_event.phase == "pre"
      assert bronze_event.hook_results["outcome"] == "ok"
    end

    test "Blocked capture records reason, phase, session_id, plan_id, task_id, agent_id, hook_results (kiro-f77)" do
      session_id = "sess_bronze_kf77_#{System.unique_integer([:positive])}"
      plan_id = Ecto.UUID.generate()
      task_id = Ecto.UUID.generate()

      event =
        Event.new(:file_write,
          session_id: session_id,
          plan_id: plan_id,
          task_id: task_id,
          agent_id: "bronze_agent"
        )

      hooks = [BlockHook]
      # No opt-in — mandatory capture per §27.11 inv. 7
      ctx = %{}

      {:blocked, _event, reason, _messages} = HookManager.run(event, hooks, ctx, :pre)

      [bronze] = Events.list_by_session(session_id, limit: 10)
      assert bronze.event_type == "hook_trace"
      assert bronze.session_id == session_id
      assert bronze.plan_id == plan_id
      assert bronze.task_id == task_id
      assert bronze.agent_id == "bronze_agent"
      assert bronze.phase == "pre"
      # Blocked reason and hook_results are fully captured
      assert bronze.hook_results["outcome"] == "blocked"
      assert bronze.hook_results["reason"] == reason
      assert is_list(bronze.hook_results["hook_results"])
      [hr] = bronze.hook_results["hook_results"]
      assert hr["hook"] == "block_hook"
      assert hr["decision"] == "block"
    end

    test "HookManager.run persists without opt-in for continue outcome (§36.1)" do
      session_id = "sess_bronze_continue_#{System.unique_integer([:positive])}"
      plan_id = Ecto.UUID.generate()
      task_id = Ecto.UUID.generate()

      event =
        Event.new(:file_read,
          session_id: session_id,
          plan_id: plan_id,
          task_id: task_id,
          agent_id: "reader_agent"
        )

      hooks = [ContinueHook]
      ctx = %{}

      {:ok, _event, _messages} = HookManager.run(event, hooks, ctx, :post)

      [bronze] = Events.list_by_session(session_id, limit: 10)
      assert bronze.event_type == "hook_trace"
      assert bronze.session_id == session_id
      assert bronze.plan_id == plan_id
      assert bronze.task_id == task_id
      assert bronze.agent_id == "reader_agent"
      assert bronze.phase == "post"
      assert bronze.hook_results["outcome"] == "ok"
      assert is_list(bronze.hook_results["hook_results"])
      [hr] = bronze.hook_results["hook_results"]
      assert hr["hook"] == "continue_hook"
      assert hr["decision"] == "continue"
    end
  end
end
