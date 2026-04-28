defmodule KiroCockpit.PuppyBrain.CallbacksTest do
  @moduledoc """
  Focused tests for the callback nervous system (§26.13).

  Tests cover:
    - Behaviour conformance (Callback behaviour)
    - Registration / unregistration
    - Phase subscription
    - Dispatch with accumulator threading
    - Error resilience (failing callback doesn't block others)
    - Exception resilience (raising callback doesn't block others)
    - Canonical phase validation
    - Idempotent registration guards
    - Registry reset for test isolation
    - Telemetry emission
  """

  use ExUnit.Case, async: false

  alias KiroCockpit.PuppyBrain.{Callback, Callbacks}

  # -- Fake callback modules for testing ------------------------------------

  defmodule StartupCallback do
    @behaviour Callback

    @impl true
    def name, do: :startup_cb

    @impl true
    def phases, do: [:on_startup]

    @impl true
    def on_callback(:on_startup, _ctx, acc) do
      {:ok, Map.put(acc, :env, "test")}
    end
  end

  defmodule MultiPhaseCallback do
    @behaviour Callback

    @impl true
    def name, do: :multi_phase_cb

    @impl true
    def phases, do: [:on_load_prompt, :on_prepare_model_prompt]

    @impl true
    def on_callback(:on_load_prompt, _ctx, acc) do
      {:ok, Map.put(acc, :prompt_loaded, true)}
    end

    @impl true
    def on_callback(:on_prepare_model_prompt, _ctx, acc) do
      {:ok, Map.put(acc, :model_prompt_prepared, true)}
    end
  end

  defmodule FailingCallback do
    @behaviour Callback

    @impl true
    def name, do: :failing_cb

    @impl true
    def phases, do: [:on_startup]

    @impl true
    def on_callback(:on_startup, _ctx, _acc) do
      {:error, :deliberate_failure}
    end
  end

  defmodule RaisingCallback do
    @behaviour Callback

    @impl true
    def name, do: :raising_cb

    @impl true
    def phases, do: [:on_startup]

    @impl true
    def on_callback(:on_startup, _ctx, _acc) do
      raise "deliberate explosion"
    end
  end

  defmodule NotACallback do
    # Does NOT implement the Callback behaviour
    def name, do: :not_a_callback
    def phases, do: [:on_startup]
  end

  # -- Setup ----------------------------------------------------------------

  # The Callbacks GenServer is started by the application supervisor.
  # We just reset it for test isolation. `async: false` because we
  # touch shared global state (the ETS table).

  setup do
    Callbacks.reset()
    :ok
  end

  # -- Canonical phases -----------------------------------------------------

  describe "canonical_phases/0" do
    test "returns all phases from §26.13" do
      phases = Callbacks.canonical_phases()

      assert :on_startup in phases
      assert :on_shutdown in phases
      assert :on_load_prompt in phases
      assert :on_load_rules in phases
      assert :on_prepare_model_prompt in phases
      assert :on_register_agents in phases
      assert :on_register_tools in phases
      assert :on_register_skills in phases
      assert :on_pre_action in phases
      assert :on_post_action in phases
      assert :on_stream_event in phases
      assert :on_plan_created in phases
      assert :on_plan_approved in phases
      assert :on_task_changed in phases
      assert :on_finding_promoted in phases
      assert :on_history_compaction_start in phases
      assert :on_history_compaction_end in phases
    end

    test "has exactly 17 canonical phases" do
      assert length(Callbacks.canonical_phases()) == 17
    end
  end

  describe "canonical_phase?/1" do
    test "returns true for known phases" do
      assert Callbacks.canonical_phase?(:on_startup)
      assert Callbacks.canonical_phase?(:on_post_action)
    end

    test "returns false for unknown phases" do
      refute Callbacks.canonical_phase?(:on_bogus_event)
      refute Callbacks.canonical_phase?(:on_load_prompt_extra)
    end
  end

  # -- Registration ---------------------------------------------------------

  describe "register/1" do
    test "registers a valid callback module" do
      assert :ok == Callbacks.register(StartupCallback)
      assert Callbacks.registered?(StartupCallback)
    end

    test "registers a callback for multiple phases" do
      assert :ok == Callbacks.register(MultiPhaseCallback)

      assert Callbacks.modules_for_phase(:on_load_prompt) == [MultiPhaseCallback]
      assert Callbacks.modules_for_phase(:on_prepare_model_prompt) == [MultiPhaseCallback]
    end

    test "rejects a module that does not implement Callback behaviour" do
      assert {:error, {:invalid_callback_module, NotACallback}} ==
               Callbacks.register(NotACallback)
    end

    test "rejects duplicate registration" do
      assert :ok == Callbacks.register(StartupCallback)

      assert {:error, {:already_registered, StartupCallback}} ==
               Callbacks.register(StartupCallback)
    end

    test "maintains registration order" do
      assert :ok == Callbacks.register(StartupCallback)
      assert :ok == Callbacks.register(MultiPhaseCallback)

      assert Callbacks.registered_modules() == [StartupCallback, MultiPhaseCallback]
    end
  end

  describe "unregister/1" do
    test "removes a callback from all phases" do
      assert :ok == Callbacks.register(MultiPhaseCallback)
      assert :ok == Callbacks.unregister(MultiPhaseCallback)

      assert Callbacks.modules_for_phase(:on_load_prompt) == []
      assert Callbacks.modules_for_phase(:on_prepare_model_prompt) == []
      refute Callbacks.registered?(MultiPhaseCallback)
    end

    test "unregistering a non-registered module is a no-op" do
      assert :ok == Callbacks.unregister(StartupCallback)
    end
  end

  # -- Dispatch -------------------------------------------------------------

  describe "dispatch/3" do
    test "invokes registered callback and threads accumulator" do
      Callbacks.register(StartupCallback)

      assert {:ok, %{env: "test"}} = Callbacks.dispatch(:on_startup)
    end

    test "passes context to callback" do
      defmodule ContextSensitiveCallback do
        @behaviour Callback

        @impl true
        def name, do: :context_sensitive_cb

        @impl true
        def phases, do: [:on_startup]

        @impl true
        def on_callback(:on_startup, ctx, acc) do
          {:ok, Map.put(acc, :session_id, ctx[:session_id])}
        end
      end

      Callbacks.register(ContextSensitiveCallback)

      assert {:ok, %{session_id: "sess_1"}} =
               Callbacks.dispatch(:on_startup, %{session_id: "sess_1"})
    end

    test "threads accumulator through multiple callbacks for the same phase" do
      defmodule ToolCallback1 do
        @behaviour Callback

        @impl true
        def name, do: :tool_cb_1

        @impl true
        def phases, do: [:on_register_tools]

        @impl true
        def on_callback(:on_register_tools, _ctx, acc) do
          tools = Map.get(acc, :tools, [])
          {:ok, Map.put(acc, :tools, tools ++ [:search])}
        end
      end

      defmodule ToolCallback2 do
        @behaviour Callback

        @impl true
        def name, do: :tool_cb_2

        @impl true
        def phases, do: [:on_register_tools]

        @impl true
        def on_callback(:on_register_tools, _ctx, acc) do
          tools = Map.get(acc, :tools, [])
          {:ok, Map.put(acc, :tools, tools ++ [:replace])}
        end
      end

      Callbacks.register(ToolCallback1)
      Callbacks.register(ToolCallback2)

      assert {:ok, %{tools: [:search, :replace]}} =
               Callbacks.dispatch(:on_register_tools)
    end

    test "preserves initial accumulator when no callbacks registered for phase" do
      assert {:ok, %{existing: :data}} =
               Callbacks.dispatch(:on_startup, %{}, %{existing: :data})
    end

    test "only invokes callbacks subscribed to the dispatched phase" do
      Callbacks.register(StartupCallback)
      Callbacks.register(MultiPhaseCallback)

      # MultiPhaseCallback is NOT subscribed to :on_startup
      assert {:ok, %{env: "test"}} = Callbacks.dispatch(:on_startup)

      # StartupCallback is NOT subscribed to :on_load_prompt
      assert {:ok, %{prompt_loaded: true}} = Callbacks.dispatch(:on_load_prompt)
    end

    test "skips failing callback and continues with others" do
      Callbacks.register(FailingCallback)
      Callbacks.register(StartupCallback)

      # FailingCallback returns {:error, _} and is skipped.
      # StartupCallback still runs.
      assert {:ok, %{env: "test"}} = Callbacks.dispatch(:on_startup)
    end

    test "skips raising callback and continues with others" do
      Callbacks.register(RaisingCallback)
      Callbacks.register(StartupCallback)

      # RaisingCallback raises and is caught; StartupCallback still runs.
      assert {:ok, %{env: "test"}} = Callbacks.dispatch(:on_startup)
    end

    test "returns initial acc when all callbacks fail" do
      Callbacks.register(FailingCallback)

      assert {:ok, %{initial: true}} =
               Callbacks.dispatch(:on_startup, %{}, %{initial: true})
    end

    test "preserves partial accumulator progress when a later callback fails" do
      Callbacks.register(StartupCallback)
      Callbacks.register(FailingCallback)

      # StartupCallback succeeds first, FailingCallback fails second.
      # The acc from StartupCallback is preserved.
      assert {:ok, %{env: "test"}} = Callbacks.dispatch(:on_startup)
    end

    test "dispatch for phase with no subscribers returns initial acc" do
      assert {:ok, %{}} = Callbacks.dispatch(:on_plan_approved)
    end
  end

  # -- Registry queries -----------------------------------------------------

  describe "modules_for_phase/1" do
    test "returns empty list when no callbacks registered" do
      assert [] == Callbacks.modules_for_phase(:on_startup)
    end

    test "returns modules in registration order" do
      Callbacks.register(StartupCallback)
      Callbacks.register(MultiPhaseCallback)

      assert [StartupCallback] == Callbacks.modules_for_phase(:on_startup)
      assert [MultiPhaseCallback] == Callbacks.modules_for_phase(:on_load_prompt)
    end
  end

  describe "registered_modules/0" do
    test "returns all registered modules" do
      Callbacks.register(StartupCallback)
      Callbacks.register(MultiPhaseCallback)

      assert [StartupCallback, MultiPhaseCallback] == Callbacks.registered_modules()
    end
  end

  describe "registered?/1" do
    test "returns true for registered module" do
      Callbacks.register(StartupCallback)
      assert Callbacks.registered?(StartupCallback)
    end

    test "returns false for unregistered module" do
      refute Callbacks.registered?(StartupCallback)
    end
  end

  # -- Reset ----------------------------------------------------------------

  describe "reset/0" do
    test "clears all registrations" do
      Callbacks.register(StartupCallback)
      Callbacks.register(MultiPhaseCallback)

      assert :ok == Callbacks.reset()
      assert [] == Callbacks.registered_modules()
      assert [] == Callbacks.modules_for_phase(:on_startup)
    end
  end

  # -- Telemetry ------------------------------------------------------------

  describe "telemetry" do
    test "emits dispatch telemetry events" do
      Callbacks.register(StartupCallback)

      ref = make_ref()

      :telemetry.attach(
        {:test_dispatch, ref},
        [:kiro_cockpit, :callback, :dispatch, :stop],
        fn _name, measurements, metadata, _config ->
          send(self(), {:telemetry, :dispatch_stop, measurements, metadata})
        end,
        nil
      )

      Callbacks.dispatch(:on_startup)

      received =
        receive do
          {:telemetry, :dispatch_stop, _meas, _meta} -> true
        after
          500 -> false
        end

      assert received == true

      :telemetry.detach({:test_dispatch, ref})
    end

    test "emits invoke telemetry per callback" do
      Callbacks.register(StartupCallback)

      ref = make_ref()

      :telemetry.attach(
        {:test_invoke, ref},
        [:kiro_cockpit, :callback, :invoke, :stop],
        fn _name, _measurements, _metadata, _config ->
          send(self(), {:telemetry, :invoke_stop})
        end,
        nil
      )

      Callbacks.dispatch(:on_startup)

      received =
        receive do
          {:telemetry, :invoke_stop} -> true
        after
          500 -> false
        end

      assert received == true

      :telemetry.detach({:test_invoke, ref})
    end

    test "emits exception telemetry when callback raises" do
      Callbacks.register(RaisingCallback)

      ref = make_ref()

      :telemetry.attach(
        {:test_exception, ref},
        [:kiro_cockpit, :callback, :invoke, :exception],
        fn _name, _measurements, metadata, _config ->
          send(self(), {:telemetry, :invoke_exception, metadata})
        end,
        nil
      )

      Callbacks.dispatch(:on_startup)

      received =
        receive do
          {:telemetry, :invoke_exception, meta} -> meta
        after
          500 -> nil
        end

      # :telemetry.span/3 emits :exception events with :kind, :reason, :stacktrace
      assert received != nil
      assert received[:kind] == :error
      assert match?(%RuntimeError{message: "deliberate explosion"}, received[:reason])

      :telemetry.detach({:test_exception, ref})
    end
  end

  # -- Callback behaviour contract ------------------------------------------

  describe "Callback behaviour contract" do
    test "modules implementing Callback must export name/0, phases/0, on_callback/3" do
      assert function_exported?(StartupCallback, :name, 0)
      assert function_exported?(StartupCallback, :phases, 0)
      assert function_exported?(StartupCallback, :on_callback, 3)
    end

    test "name/0 returns an atom" do
      assert is_atom(StartupCallback.name())
    end

    test "phases/0 returns a list of atoms" do
      phases = StartupCallback.phases()
      assert is_list(phases)
      assert Enum.all?(phases, &is_atom/1)
    end

    test "on_callback/3 returns ok or error tuple" do
      assert {:ok, _} = StartupCallback.on_callback(:on_startup, %{}, %{})
      assert {:error, _} = FailingCallback.on_callback(:on_startup, %{}, %{})
    end
  end
end
