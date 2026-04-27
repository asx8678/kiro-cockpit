defmodule KiroCockpit.Swarm.AcpEgressBoundaryAuditTest do
  @moduledoc """
  Tests for ACP egress boundary audit (kiro-bih).

  Verifies that ActionBoundary.run_egress/3:

    * Routes exempt egress actions (cancel, respond, respond_error) through
      an audit-only path that skips pre-hook blocking but still emits Bronze
      action_before/action_after lifecycle records with full correlation
      (§27.11 inv. 7, §35 Phase 3).

    * Routes non-exempt egress actions (notify) through the full boundary
      pipeline where pre-hooks can block; blocked attempts emit Bronze
      action_blocked records.

    * Codifies exemptions in @egress_exempt_actions and exposes them via
      egress_exempt?/1 and egress_exempt_actions/0.

    * When boundary is disabled, egress executes directly without audit.
  """

  # async: false — tests toggle global Application env (:bronze_action_capture_enabled)
  use KiroCockpit.DataCase, async: false

  alias KiroCockpit.KiroSession
  alias KiroCockpit.Swarm.{ActionBoundary, Hook, HookResult}
  alias KiroCockpit.Swarm.DataPipeline.BronzeAction
  alias KiroCockpit.Swarm.Tasks.TaskManager

  # -- Test hooks -----------------------------------------------------------

  defmodule AlwaysBlockHook do
    @behaviour Hook

    @impl true
    def name, do: :always_block
    @impl true
    def priority, do: 100
    @impl true
    def filter(_event), do: true
    @impl true
    def on_event(event, _ctx) do
      HookResult.block(event, "blocked for test", ["always_block blocked"])
    end
  end

  defmodule AlwaysContinueHook do
    @behaviour Hook

    @impl true
    def name, do: :always_continue
    @impl true
    def priority, do: 50
    @impl true
    def filter(_event), do: true
    @impl true
    def on_event(event, _ctx) do
      HookResult.continue(event, ["always_continue passed"])
    end
  end

  # -- Helpers --------------------------------------------------------------

  defp with_bronze_capture(fun) do
    key = :bronze_action_capture_enabled
    original = Application.get_env(:kiro_cockpit, key, true)
    Application.put_env(:kiro_cockpit, key, true)

    try do
      fun.()
    after
      Application.put_env(:kiro_cockpit, key, original)
    end
  end

  defp create_active_task!(session_id, agent_id, opts) do
    attrs = %{
      session_id: session_id,
      content: Keyword.get(opts, :content, "egress test task"),
      owner_id: agent_id,
      status: "in_progress",
      category: Keyword.get(opts, :category, "acting"),
      files_scope: Keyword.get(opts, :files_scope, [])
    }

    {:ok, task} = TaskManager.create(attrs)
    task
  end

  # -- Exemption codification ------------------------------------------------

  describe "egress_exempt?/1" do
    test "cancel is exempt" do
      assert ActionBoundary.egress_exempt?(:acp_egress_cancel)
    end

    test "respond is exempt" do
      assert ActionBoundary.egress_exempt?(:acp_egress_respond)
    end

    test "respond_error is exempt" do
      assert ActionBoundary.egress_exempt?(:acp_egress_respond_error)
    end

    test "notify is NOT exempt" do
      refute ActionBoundary.egress_exempt?(:acp_egress_notify)
    end

    test "unknown action is not exempt" do
      refute ActionBoundary.egress_exempt?(:unknown_action)
    end
  end

  describe "egress_exempt_actions/0" do
    test "returns the list of exempt actions" do
      exempt = ActionBoundary.egress_exempt_actions()

      assert :acp_egress_cancel in exempt
      assert :acp_egress_respond in exempt
      assert :acp_egress_respond_error in exempt
      refute :acp_egress_notify in exempt
    end

    test "all exempt actions pass egress_exempt?/1" do
      for action <- ActionBoundary.egress_exempt_actions() do
        assert ActionBoundary.egress_exempt?(action),
               "expected #{action} to be egress-exempt"
      end
    end
  end

  # -- Exempt egress: audit-only path ---------------------------------------

  describe "run_egress/3 — exempt actions (cancel, respond, respond_error)" do
    setup do
      session_id = "egress-exempt-test-#{System.unique_integer([:positive])}"
      agent_id = "egress-test-agent"
      {:ok, session_id: session_id, agent_id: agent_id}
    end

    test "cancel executes even when pre-hooks would block", %{session_id: sid, agent_id: aid} do
      ref = make_ref()

      result =
        ActionBoundary.run_egress(
          :acp_egress_cancel,
          [
            session_id: sid,
            agent_id: aid,
            pre_hooks: [AlwaysBlockHook],
            enabled: true
          ],
          fn -> {:sent, ref} end
        )

      # Exempt: cancel always executes regardless of blocking hooks
      assert {:ok, {:sent, ^ref}} = result
    end

    test "respond executes even when pre-hooks would block", %{session_id: sid, agent_id: aid} do
      ref = make_ref()

      result =
        ActionBoundary.run_egress(
          :acp_egress_respond,
          [
            session_id: sid,
            agent_id: aid,
            pre_hooks: [AlwaysBlockHook],
            enabled: true
          ],
          fn -> {:sent, ref} end
        )

      assert {:ok, {:sent, ^ref}} = result
    end

    test "respond_error executes even when pre-hooks would block", %{
      session_id: sid,
      agent_id: aid
    } do
      ref = make_ref()

      result =
        ActionBoundary.run_egress(
          :acp_egress_respond_error,
          [
            session_id: sid,
            agent_id: aid,
            pre_hooks: [AlwaysBlockHook],
            enabled: true
          ],
          fn -> {:sent, ref} end
        )

      assert {:ok, {:sent, ^ref}} = result
    end

    test "exempt egress emits Bronze action_before and action_after records", %{
      session_id: sid,
      agent_id: aid
    } do
      with_bronze_capture(fn ->
        ActionBoundary.run_egress(
          :acp_egress_cancel,
          [
            session_id: sid,
            agent_id: aid,
            pre_hooks: [],
            post_hooks: [],
            enabled: true
          ],
          fn -> :ok end
        )

        # Find Bronze action events for this session
        actions = BronzeAction.list_actions(sid)

        before_events = Enum.filter(actions, &(&1.event_type == "action_before"))
        after_events = Enum.filter(actions, &(&1.event_type == "action_after"))

        assert length(before_events) >= 1, "expected at least one action_before for exempt egress"
        assert length(after_events) >= 1, "expected at least one action_after for exempt egress"

        # Verify correlation on the most recent action_before
        before = List.last(before_events)
        assert before.session_id == sid
        assert before.agent_id == aid

        hook_results = before.hook_results || %{}
        assert hook_results["action_name"] == "acp_egress_cancel"
      end)
    end

    test "exempt egress Bronze records carry plan_id/task_id correlation", %{
      session_id: sid,
      agent_id: aid
    } do
      with_bronze_capture(fn ->
        task = create_active_task!(sid, aid, category: "acting")
        plan_id = task.plan_id

        ActionBoundary.run_egress(
          :acp_egress_respond,
          [
            session_id: sid,
            agent_id: aid,
            plan_id: plan_id,
            task_id: task.id,
            pre_hooks: [],
            post_hooks: [],
            enabled: true
          ],
          fn -> :ok end
        )

        actions = BronzeAction.list_actions(sid)
        before_events = Enum.filter(actions, &(&1.event_type == "action_before"))

        assert length(before_events) >= 1
        before = List.last(before_events)

        # §27.11 inv. 8: every execution traceable to plan_id and task_id
        assert before.plan_id == plan_id
        assert before.task_id == task.id
      end)
    end

    test "exempt egress never emits action_blocked", %{session_id: sid, agent_id: aid} do
      with_bronze_capture(fn ->
        # Even with a blocking hook, exempt egress should not produce action_blocked
        ActionBoundary.run_egress(
          :acp_egress_cancel,
          [
            session_id: sid,
            agent_id: aid,
            pre_hooks: [AlwaysBlockHook],
            enabled: true
          ],
          fn -> :ok end
        )

        actions = BronzeAction.list_actions(sid)
        blocked_events = Enum.filter(actions, &(&1.event_type == "action_blocked"))

        assert blocked_events == [], "exempt egress should never produce action_blocked"
      end)
    end
  end

  # -- Non-exempt egress: full boundary pipeline ----------------------------

  describe "run_egress/3 — non-exempt actions (notify)" do
    setup do
      session_id = "egress-notify-test-#{System.unique_integer([:positive])}"
      agent_id = "egress-test-agent"
      {:ok, session_id: session_id, agent_id: agent_id}
    end

    test "notify executes when pre-hooks allow", %{session_id: sid, agent_id: aid} do
      ref = make_ref()

      result =
        ActionBoundary.run_egress(
          :acp_egress_notify,
          [
            session_id: sid,
            agent_id: aid,
            pre_hooks: [AlwaysContinueHook],
            post_hooks: [],
            enabled: true
          ],
          fn -> {:sent, ref} end
        )

      assert {:ok, {:sent, ^ref}} = result
    end

    test "notify is blocked when pre-hooks block", %{session_id: sid, agent_id: aid} do
      ref = make_ref()

      result =
        ActionBoundary.run_egress(
          :acp_egress_notify,
          [
            session_id: sid,
            agent_id: aid,
            pre_hooks: [AlwaysBlockHook],
            enabled: true
          ],
          fn -> {:sent, ref} end
        )

      assert {:error, {:swarm_blocked, "blocked for test", _}} = result
    end

    test "blocked notify emits Bronze action_before and action_blocked", %{
      session_id: sid,
      agent_id: aid
    } do
      with_bronze_capture(fn ->
        ActionBoundary.run_egress(
          :acp_egress_notify,
          [
            session_id: sid,
            agent_id: aid,
            pre_hooks: [AlwaysBlockHook],
            enabled: true
          ],
          fn -> :ok end
        )

        actions = BronzeAction.list_actions(sid)

        before_events = Enum.filter(actions, &(&1.event_type == "action_before"))
        blocked_events = Enum.filter(actions, &(&1.event_type == "action_blocked"))

        # §27.11 inv. 7: Bronze captures every event, including blocked
        assert length(before_events) >= 1, "expected action_before for blocked egress"
        assert length(blocked_events) >= 1, "expected action_blocked for blocked egress"

        # Verify the blocked record has the correct action name
        blocked = List.last(blocked_events)
        hook_results = blocked.hook_results || %{}
        assert hook_results["action_name"] == "acp_egress_notify"
        assert hook_results["block_reason"] == "blocked for test"
      end)
    end

    test "allowed notify emits Bronze action_before and action_after", %{
      session_id: sid,
      agent_id: aid
    } do
      with_bronze_capture(fn ->
        ActionBoundary.run_egress(
          :acp_egress_notify,
          [
            session_id: sid,
            agent_id: aid,
            pre_hooks: [AlwaysContinueHook],
            post_hooks: [],
            enabled: true
          ],
          fn -> :ok end
        )

        actions = BronzeAction.list_actions(sid)

        before_events = Enum.filter(actions, &(&1.event_type == "action_before"))
        after_events = Enum.filter(actions, &(&1.event_type == "action_after"))

        assert length(before_events) >= 1
        assert length(after_events) >= 1
      end)
    end

    test "blocked notify Bronze records carry correlation", %{session_id: sid, agent_id: aid} do
      with_bronze_capture(fn ->
        task = create_active_task!(sid, aid, category: "acting")
        plan_id = task.plan_id

        ActionBoundary.run_egress(
          :acp_egress_notify,
          [
            session_id: sid,
            agent_id: aid,
            plan_id: plan_id,
            task_id: task.id,
            pre_hooks: [AlwaysBlockHook],
            enabled: true
          ],
          fn -> :ok end
        )

        actions = BronzeAction.list_actions(sid)
        blocked_events = Enum.filter(actions, &(&1.event_type == "action_blocked"))

        assert length(blocked_events) >= 1
        blocked = List.last(blocked_events)

        # §27.11 inv. 8: every execution traceable to plan_id and task_id
        assert blocked.plan_id == plan_id
        assert blocked.task_id == task.id
        assert blocked.session_id == sid
      end)
    end
  end

  # -- Boundary disabled ----------------------------------------------------

  describe "run_egress/3 — boundary disabled" do
    test "executes fun directly when boundary disabled via opts" do
      ref = make_ref()

      result =
        ActionBoundary.run_egress(
          :acp_egress_notify,
          [enabled: false],
          fn -> {:direct, ref} end
        )

      assert {:ok, {:direct, ^ref}} = result
    end

    test "exempt egress executes directly when boundary disabled" do
      ref = make_ref()

      result =
        ActionBoundary.run_egress(
          :acp_egress_cancel,
          [enabled: false],
          fn -> {:direct, ref} end
        )

      assert {:ok, {:direct, ^ref}} = result
    end
  end

  # -- Consistency with run/3 for non-exempt --------------------------------

  describe "run_egress/3 delegates to run/3 for non-exempt actions" do
    setup do
      session_id = "egress-delegate-test-#{System.unique_integer([:positive])}"
      agent_id = "egress-test-agent"
      {:ok, session_id: session_id, agent_id: agent_id}
    end

    test "non-exempt egress with no active task is blocked by TaskEnforcementHook", %{
      session_id: sid,
      agent_id: aid
    } do
      result =
        ActionBoundary.run_egress(
          :acp_egress_notify,
          [
            session_id: sid,
            agent_id: aid,
            enabled: true
          ],
          fn -> :ok end
        )

      # TaskEnforcementHook should block when no active task
      assert {:error, {:swarm_blocked, _reason, _messages}} = result
    end

    test "non-exempt egress with active task and allowing hooks is allowed", %{
      session_id: sid,
      agent_id: aid
    } do
      # TaskEnforcementHook blocks unknown action names — use ContinueHook
      # to prove that non-exempt egress goes through run/3 and succeeds
      # when hooks allow.
      result =
        ActionBoundary.run_egress(
          :acp_egress_notify,
          [
            session_id: sid,
            agent_id: aid,
            pre_hooks: [AlwaysContinueHook],
            post_hooks: [],
            enabled: true
          ],
          fn -> :ok end
        )

      assert {:ok, :ok} = result
    end
  end

  # -- Exempt egress always passes TaskEnforcementHook ----------------------

  describe "exempt egress always passes (kiro-bih core guarantee)" do
    setup do
      session_id = "egress-always-pass-#{System.unique_integer([:positive])}"
      agent_id = "egress-test-agent"
      {:ok, session_id: session_id, agent_id: agent_id}
    end

    test "cancel passes even without active task", %{session_id: sid, agent_id: aid} do
      # No active task — TaskEnforcementHook would block a normal action,
      # but cancel is exempt and always passes.
      result =
        ActionBoundary.run_egress(
          :acp_egress_cancel,
          [
            session_id: sid,
            agent_id: aid,
            enabled: true
          ],
          fn -> :ok end
        )

      assert {:ok, :ok} = result
    end

    test "respond passes even without active task", %{session_id: sid, agent_id: aid} do
      result =
        ActionBoundary.run_egress(
          :acp_egress_respond,
          [
            session_id: sid,
            agent_id: aid,
            enabled: true
          ],
          fn -> :ok end
        )

      assert {:ok, :ok} = result
    end

    test "respond_error passes even without active task", %{session_id: sid, agent_id: aid} do
      result =
        ActionBoundary.run_egress(
          :acp_egress_respond_error,
          [
            session_id: sid,
            agent_id: aid,
            enabled: true
          ],
          fn -> :ok end
        )

      assert {:ok, :ok} = result
    end
  end

  # -- Bronze payload persistence (kiro-bih) ---------------------------------
  #
  # Verifies that ACP egress method/details are persisted in Bronze action
  # capture payload/raw_payload, not metadata-only. This mirrors the
  # callback_boundary_opts style where callback_method appears in payload
  # and raw_payload.method is extracted as method_hint.

  describe "run_egress/3 — Bronze payload persistence (kiro-bih)" do
    setup do
      session_id = "egress-persist-test-#{System.unique_integer([:positive])}"
      agent_id = "egress-test-agent"
      {:ok, session_id: session_id, agent_id: agent_id}
    end

    test "exempt egress (cancel) persists ACP method in Bronze raw_payload.method_hint",
         %{session_id: sid, agent_id: aid} do
      with_bronze_capture(fn ->
        ActionBoundary.run_egress(
          :acp_egress_cancel,
          [
            session_id: sid,
            agent_id: aid,
            pre_hooks: [],
            post_hooks: [],
            enabled: true,
            payload: %{egress_type: :acp_egress, egress_method: "session/cancel"},
            raw_payload: %{method: "session/cancel"}
          ],
          fn -> :ok end
        )

        actions = BronzeAction.list_actions(sid)
        before_events = Enum.filter(actions, &(&1.event_type == "action_before"))

        assert length(before_events) >= 1, "expected action_before for exempt egress"
        before = List.last(before_events)

        # Bronze raw_payload summary must include method_hint with the actual
        # ACP method string — not just metadata (kiro-bih).
        raw = before.raw_payload || %{}

        assert raw["method_hint"] == "session/cancel",
               "expected raw_payload.method_hint == 'session/cancel', got: #{inspect(raw)}"

        # Bronze payload summary must include egress_type and egress_method keys
        payload = before.payload || %{}
        assert payload["type"] == "payload_summary"

        assert "egress_type" in (payload["keys"] || []),
               "expected egress_type in payload keys, got: #{inspect(payload)}"

        assert "egress_method" in (payload["keys"] || []),
               "expected egress_method in payload keys, got: #{inspect(payload)}"
      end)
    end

    test "non-exempt egress (notify) persists ACP method in Bronze raw_payload.method_hint",
         %{session_id: sid, agent_id: aid} do
      with_bronze_capture(fn ->
        ActionBoundary.run_egress(
          :acp_egress_notify,
          [
            session_id: sid,
            agent_id: aid,
            pre_hooks: [AlwaysContinueHook],
            post_hooks: [],
            enabled: true,
            payload: %{egress_type: :acp_egress, egress_method: "fs/read_text_file"},
            raw_payload: %{method: "fs/read_text_file"}
          ],
          fn -> :ok end
        )

        actions = BronzeAction.list_actions(sid)
        before_events = Enum.filter(actions, &(&1.event_type == "action_before"))

        assert length(before_events) >= 1, "expected action_before for non-exempt egress"
        before = List.last(before_events)

        # Bronze raw_payload summary must include method_hint (kiro-bih)
        raw = before.raw_payload || %{}

        assert raw["method_hint"] == "fs/read_text_file",
               "expected raw_payload.method_hint == 'fs/read_text_file', got: #{inspect(raw)}"

        # Bronze payload summary must include egress keys
        payload = before.payload || %{}
        assert payload["type"] == "payload_summary"

        assert "egress_type" in (payload["keys"] || []),
               "expected egress_type in payload keys, got: #{inspect(payload)}"

        assert "egress_method" in (payload["keys"] || []),
               "expected egress_method in payload keys, got: #{inspect(payload)}"
      end)
    end

    test "exempt egress (respond) with request_id preserves id_hint in raw_payload",
         %{session_id: sid, agent_id: aid} do
      with_bronze_capture(fn ->
        ActionBoundary.run_egress(
          :acp_egress_respond,
          [
            session_id: sid,
            agent_id: aid,
            pre_hooks: [],
            post_hooks: [],
            enabled: true,
            payload: %{egress_type: :acp_egress, egress_method: "callback_response"},
            raw_payload: %{method: "callback_response", id: 42}
          ],
          fn -> :ok end
        )

        actions = BronzeAction.list_actions(sid)
        before_events = Enum.filter(actions, &(&1.event_type == "action_before"))

        assert length(before_events) >= 1
        before = List.last(before_events)

        raw = before.raw_payload || %{}

        assert raw["method_hint"] == "callback_response",
               "expected method_hint == 'callback_response', got: #{inspect(raw)}"

        # request_id appears as :id in raw_payload → id_hint "has_id"
        assert raw["id_hint"] == "has_id",
               "expected raw_payload.id_hint == 'has_id', got: #{inspect(raw)}"
      end)
    end

    test "blocked non-exempt egress (notify) still persists method in Bronze records",
         %{session_id: sid, agent_id: aid} do
      with_bronze_capture(fn ->
        ActionBoundary.run_egress(
          :acp_egress_notify,
          [
            session_id: sid,
            agent_id: aid,
            pre_hooks: [AlwaysBlockHook],
            enabled: true,
            payload: %{egress_type: :acp_egress, egress_method: "fs/write_text_file"},
            raw_payload: %{method: "fs/write_text_file"}
          ],
          fn -> :ok end
        )

        actions = BronzeAction.list_actions(sid)
        blocked_events = Enum.filter(actions, &(&1.event_type == "action_blocked"))

        assert length(blocked_events) >= 1, "expected action_blocked for blocked egress"
        blocked = List.last(blocked_events)

        # Even blocked egress must persist the method (kiro-bih)
        raw = blocked.raw_payload || %{}

        assert raw["method_hint"] == "fs/write_text_file",
               "expected method_hint in blocked record, got: #{inspect(raw)}"

        payload = blocked.payload || %{}

        assert "egress_type" in (payload["keys"] || []),
               "expected egress_type in blocked payload keys, got: #{inspect(payload)}"
      end)
    end
  end

  # -- KiroSession integration (kiro-bih) --------------------------------------
  #
  # Proves that KiroSession routes egress actions through
  # ActionBoundary.run_egress/3 when swarm_hooks is enabled.
  # Uses a mock swarm_hooks_module that records invocations.

  describe "KiroSession egress integration (kiro-bih)" do
    defmodule EgressSpy do
      @moduledoc """
      Spy module that records run_egress calls for KiroSession integration tests.
      Implements the same public API as ActionBoundary (run/3, run_egress/3)
      so it can be injected as swarm_hooks_module.
      """
      use Agent

      def start_link(_opts \\ []), do: Agent.start_link(fn -> [] end, name: __MODULE__)

      def get_calls, do: Agent.get(__MODULE__, & &1)

      def reset, do: Agent.update(__MODULE__, fn _ -> [] end)

      def run(action, opts, fun) do
        Agent.update(__MODULE__, fn calls -> [{:run, action, opts} | calls] end)
        {:ok, fun.()}
      end

      def run_egress(action, opts, fun) do
        Agent.update(__MODULE__, fn calls -> [{:run_egress, action, opts} | calls] end)
        {:ok, fun.()}
      end

      def run_lifecycle_post_hooks(_action, _opts), do: :ok
    end

    test "KiroSession.cancel routes through run_egress when swarm_hooks enabled" do
      EgressSpy.start_link()
      EgressSpy.reset()

      elixir = System.find_executable("elixir") || flunk("elixir not on PATH")

      ebin_dirs =
        Path.wildcard(Path.expand("_build/#{Mix.env()}/lib/*/ebin", File.cwd!()))

      fake_agent_entry = ~s|KiroCockpit.Test.Acp.FakeAgent.main()|

      args =
        Enum.flat_map(ebin_dirs, fn dir -> ["-pa", dir] end) ++
          ["-e", fake_agent_entry]

      {:ok, session} =
        KiroSession.start_link(
          executable: elixir,
          args: args,
          env: [{"FAKE_ACP_SCENARIO", "cancel"}],
          subscriber: self(),
          persist_messages: false,
          auto_callbacks: false,
          swarm_hooks: true,
          swarm_hooks_module: EgressSpy
        )

      # Initialize + new_session so the session is ready for a prompt
      assert {:ok, _} = KiroSession.initialize(session)
      assert {:ok, _result} = KiroSession.new_session(session, File.cwd!())

      # Start a prompt (sets turn_status to :running) — the cancel scenario
      # agent emits one chunk then blocks reading stdin until cancel arrives
      task = Task.async(fn -> KiroSession.prompt(session, "long-running") end)

      # Wait for the initial chunk so the agent is in its blocking read
      assert_receive {:kiro_stream_event, ^session, _}, 2_000

      # Issue cancel — should route through EgressSpy.run_egress/3
      :ok = KiroSession.cancel(session)

      # Let the prompt complete so the session shuts down cleanly
      Task.await(task, 5_000)

      calls = EgressSpy.get_calls()

      # Must have at least one run_egress call with the cancel action
      egress_calls = Enum.filter(calls, &match?({:run_egress, _, _}, &1))
      assert length(egress_calls) >= 1, "expected run_egress call, got: #{inspect(calls)}"

      {_, action, _opts} = List.last(egress_calls)
      assert action == :acp_egress_cancel, "expected :acp_egress_cancel, got: #{action}"

      # Cleanup
      KiroSession.stop(session)
    end

    test "KiroSession egress opts include method in payload and raw_payload" do
      EgressSpy.start_link()
      EgressSpy.reset()

      elixir = System.find_executable("elixir") || flunk("elixir not on PATH")

      ebin_dirs =
        Path.wildcard(Path.expand("_build/#{Mix.env()}/lib/*/ebin", File.cwd!()))

      fake_agent_entry = ~s|KiroCockpit.Test.Acp.FakeAgent.main()|

      args =
        Enum.flat_map(ebin_dirs, fn dir -> ["-pa", dir] end) ++
          ["-e", fake_agent_entry]

      {:ok, session} =
        KiroSession.start_link(
          executable: elixir,
          args: args,
          env: [{"FAKE_ACP_SCENARIO", "cancel"}],
          subscriber: self(),
          persist_messages: false,
          auto_callbacks: false,
          swarm_hooks: true,
          swarm_hooks_module: EgressSpy
        )

      assert {:ok, _} = KiroSession.initialize(session)
      assert {:ok, _result} = KiroSession.new_session(session, File.cwd!())

      # Start a prompt to set turn_status to :running
      task = Task.async(fn -> KiroSession.prompt(session, "long-running") end)

      # Wait for the initial chunk so the agent is in its blocking read
      assert_receive {:kiro_stream_event, ^session, _}, 2_000

      # Cancel — routes through EgressSpy
      :ok = KiroSession.cancel(session)

      # Let the prompt complete
      Task.await(task, 5_000)

      calls = EgressSpy.get_calls()
      egress_calls = Enum.filter(calls, &match?({:run_egress, _, _}, &1))
      assert length(egress_calls) >= 1

      {_, _action, opts} = List.last(egress_calls)

      # Verify egress_boundary_opts includes payload and raw_payload with method
      payload = Keyword.get(opts, :payload, %{})
      raw_payload = Keyword.get(opts, :raw_payload, %{})

      assert payload[:egress_type] == :acp_egress,
             "expected payload.egress_type == :acp_egress, got: #{inspect(payload)}"

      assert payload[:egress_method] == "session/cancel",
             "expected payload.egress_method == 'session/cancel', got: #{inspect(payload)}"

      assert raw_payload[:method] == "session/cancel",
             "expected raw_payload.method == 'session/cancel', got: #{inspect(raw_payload)}"

      KiroSession.stop(session)
    end

    test "exemption classification is correct for all egress actions" do
      assert ActionBoundary.egress_exempt?(:acp_egress_cancel)
      assert ActionBoundary.egress_exempt?(:acp_egress_respond)
      assert ActionBoundary.egress_exempt?(:acp_egress_respond_error)
      refute ActionBoundary.egress_exempt?(:acp_egress_notify)
    end
  end
end
