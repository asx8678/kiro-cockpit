defmodule KiroCockpit.TelemetryTest do
  @moduledoc """
  Behavioural tests for the Phase 1 telemetry/structured-logging seed
  (`plan2.md` §25.3 R8). We assert that:

  * canonical event names are built from the closed sets,
  * unknown contexts/actions/phases raise (no near-duplicates),
  * `execute/3` and `span/4` actually emit through `:telemetry`,
  * metadata filtering only keeps the canonical correlation keys,
  * Logger metadata helpers respect that same whitelist and restore
    prior state.

  We do **not** assert log line formatting — that is brittle and not what
  this seed is responsible for.
  """
  use ExUnit.Case, async: true

  alias KiroCockpit.Telemetry, as: T

  require Logger

  describe "event/3" do
    test "builds the canonical four-element event name" do
      assert T.event(:session, :create, :stop) ==
               [:kiro_cockpit, :session, :create, :stop]

      assert T.event(:acp, :prompt, :start) ==
               [:kiro_cockpit, :acp, :prompt, :start]

      assert T.event(:event_store, :append, :exception) ==
               [:kiro_cockpit, :event_store, :append, :exception]
    end

    test "rejects unknown contexts" do
      assert_raise ArgumentError, ~r/unknown telemetry context: :tool_run/, fn ->
        T.event(:tool_run, :dispatch, :stop)
      end
    end

    test "rejects unknown actions for a known context" do
      assert_raise ArgumentError, ~r/unknown telemetry action :enqueue/, fn ->
        # :enqueue is from a different (future) taxonomy — should be
        # rejected here and routed through a deliberate spec change.
        T.event(:session, :enqueue, :stop)
      end
    end

    test "rejects unknown phases" do
      assert_raise ArgumentError, ~r/unknown telemetry phase :finished/, fn ->
        T.event(:session, :create, :finished)
      end
    end
  end

  describe "contexts/0, actions/1, metadata_keys/0" do
    test "expose the closed sets" do
      assert T.contexts() == [:acp, :session, :event_store]
      assert :create in T.actions(:session)
      assert :append in T.actions(:event_store)
      assert :prompt in T.actions(:acp)

      keys = T.metadata_keys()
      assert :session_id in keys
      assert :plan_id in keys
      assert :task_id in keys
      assert :agent_id in keys
      assert :permission_level in keys
      assert :trace_id in keys
      assert :request_id in keys
    end

    test "actions/1 raises for an unknown context" do
      assert_raise ArgumentError, ~r/unknown telemetry context: :nope/, fn ->
        T.actions(:nope)
      end
    end
  end

  describe "filter_metadata/1" do
    test "keeps only the canonical keys from a map" do
      input = %{
        session_id: "s-1",
        plan_id: "p-1",
        task_id: "t-1",
        agent_id: "a-1",
        permission_level: :read,
        trace_id: "tr-1",
        # forbidden / unknown keys must be dropped
        secret: "sk-XXXX",
        user_input: "do the thing",
        password: "hunter2"
      }

      filtered = T.filter_metadata(input)

      assert filtered == %{
               session_id: "s-1",
               plan_id: "p-1",
               task_id: "t-1",
               agent_id: "a-1",
               permission_level: :read,
               trace_id: "tr-1"
             }

      refute Map.has_key?(filtered, :secret)
      refute Map.has_key?(filtered, :user_input)
      refute Map.has_key?(filtered, :password)
    end

    test "keeps only the canonical keys from a keyword list" do
      input = [
        session_id: "s-1",
        plan_id: "p-1",
        secret: "sk-XXXX",
        user_input: "do the thing"
      ]

      assert T.filter_metadata(input) == [session_id: "s-1", plan_id: "p-1"]
    end
  end

  describe "execute/3" do
    test "emits a telemetry event with filtered metadata" do
      event = T.event(:session, :create, :stop)
      attach_handler(event)

      :ok =
        T.execute(
          event,
          %{duration: 42},
          %{session_id: "s-1", secret: "sk-leak"}
        )

      assert_receive {:telemetry, ^event, %{duration: 42}, meta}
      assert meta == %{session_id: "s-1"}
    end
  end

  describe "span/4" do
    test "emits :start and :stop with filtered metadata and forwards the result" do
      stop_event = [:kiro_cockpit, :event_store, :append, :stop]
      start_event = [:kiro_cockpit, :event_store, :append, :start]
      attach_handler([start_event, stop_event])

      result =
        T.span(:event_store, :append, %{session_id: "s-1", secret: "leak"}, fn ->
          # 3-tuple form: extras split between measurements and metadata,
          # matching the canonical pattern documented in the module.
          {:ok_value, %{rows: 1}, %{}}
        end)

      assert result == :ok_value

      # `:telemetry.span/3` injects a `:telemetry_span_context` reference
      # to correlate :start and :stop. We ignore it and assert on the
      # user-controlled correlation keys.
      assert_receive {:telemetry, ^start_event, start_measurements, start_meta}
      assert is_integer(start_measurements.monotonic_time)
      assert is_integer(start_measurements.system_time)
      assert Map.get(start_meta, :session_id) == "s-1"
      refute Map.has_key?(start_meta, :secret)

      assert_receive {:telemetry, ^stop_event, stop_measurements, stop_meta}
      assert stop_measurements.rows == 1
      assert is_integer(stop_measurements.duration) and stop_measurements.duration >= 0
      assert Map.get(stop_meta, :session_id) == "s-1"
      refute Map.has_key?(stop_meta, :secret)
    end

    test "accepts the 2-tuple result form for callers that don't split measurements" do
      stop_event = [:kiro_cockpit, :session, :resume, :stop]
      attach_handler(stop_event)

      assert :resumed =
               T.span(:session, :resume, %{session_id: "s-2"}, fn ->
                 {:resumed, %{}}
               end)

      assert_receive {:telemetry, ^stop_event, %{duration: _}, stop_meta}
      assert Map.get(stop_meta, :session_id) == "s-2"
    end

    test "emits :exception with start metadata propagated when fun raises" do
      exception_event = [:kiro_cockpit, :event_store, :append, :exception]
      attach_handler(exception_event)

      assert_raise RuntimeError, "boom", fn ->
        T.span(:event_store, :append, %{session_id: "s-3", plan_id: "p-3"}, fn ->
          raise "boom"
        end)
      end

      assert_receive {:telemetry, ^exception_event, _measurements, exc_meta}
      assert Map.get(exc_meta, :session_id) == "s-3"
      assert Map.get(exc_meta, :plan_id) == "p-3"
      # `:telemetry.span/3` adds :kind / :reason / :stacktrace itself.
      assert Map.has_key?(exc_meta, :kind)
      assert Map.has_key?(exc_meta, :reason)
    end

    test "raises a useful error if fun returns the wrong shape" do
      assert_raise ArgumentError, ~r/span function must return/, fn ->
        T.span(:session, :create, %{session_id: "s-4"}, fn -> :not_a_tuple end)
      end
    end

    test "rejects unknown action without emitting" do
      attach_handler([:kiro_cockpit, :session, :create, :start])

      assert_raise ArgumentError, ~r/unknown telemetry action :enqueue/, fn ->
        T.span(:session, :enqueue, %{session_id: "s-1"}, fn -> {:ok, %{}} end)
      end

      refute_receive {:telemetry, _, _, _}, 50
    end
  end

  describe "put_metadata/1" do
    test "sets only canonical keys on the Logger metadata, dropping the rest" do
      previous = Logger.metadata()

      try do
        Logger.reset_metadata([])

        T.put_metadata(
          session_id: "s-1",
          plan_id: "p-1",
          secret: "sk-leak",
          user_input: "do the thing"
        )

        meta = Logger.metadata()
        assert Keyword.get(meta, :session_id) == "s-1"
        assert Keyword.get(meta, :plan_id) == "p-1"
        refute Keyword.has_key?(meta, :secret)
        refute Keyword.has_key?(meta, :user_input)
      after
        Logger.reset_metadata(previous)
      end
    end

    test "accepts a map and filters it the same way" do
      previous = Logger.metadata()

      try do
        Logger.reset_metadata([])

        T.put_metadata(%{session_id: "s-1", secret: "sk-leak"})
        meta = Logger.metadata()

        assert Keyword.get(meta, :session_id) == "s-1"
        refute Keyword.has_key?(meta, :secret)
      after
        Logger.reset_metadata(previous)
      end
    end
  end

  describe "with_metadata/2" do
    test "scopes metadata to the function and restores prior state" do
      previous = Logger.metadata()

      try do
        Logger.reset_metadata(request_id: "req-existing")

        result =
          T.with_metadata([session_id: "s-inner", secret: "leak"], fn ->
            inner_meta = Logger.metadata()
            assert Keyword.get(inner_meta, :session_id) == "s-inner"
            assert Keyword.get(inner_meta, :request_id) == "req-existing"
            refute Keyword.has_key?(inner_meta, :secret)
            :inner_result
          end)

        assert result == :inner_result

        # After the block returns, prior metadata is fully restored.
        restored = Logger.metadata()
        assert Keyword.get(restored, :request_id) == "req-existing"
        refute Keyword.has_key?(restored, :session_id)
      after
        Logger.reset_metadata(previous)
      end
    end

    test "restores prior metadata even when the function raises" do
      previous = Logger.metadata()

      try do
        Logger.reset_metadata(request_id: "req-existing")

        assert_raise RuntimeError, "boom", fn ->
          T.with_metadata([session_id: "s-inner"], fn ->
            raise "boom"
          end)
        end

        restored = Logger.metadata()
        assert Keyword.get(restored, :request_id) == "req-existing"
        refute Keyword.has_key?(restored, :session_id)
      after
        Logger.reset_metadata(previous)
      end
    end
  end

  # ------- helpers -------

  defp attach_handler(events) when is_list(events) do
    events =
      case events do
        [head | _] when is_atom(head) -> [events]
        _ -> events
      end

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
end
