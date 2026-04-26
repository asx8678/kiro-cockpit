defmodule KiroCockpit.NanoPlannerBoundaryTest do
  @moduledoc """
  Regression tests for kiro-43h: Phase 3 planner lifecycle actions through
  ActionBoundary.

  Verifies that NanoPlanner.plan/3 (:nano_plan_generate) and
  NanoPlanner.approve/3 (:nano_plan_approve) route through
  ActionBoundary/HookManager with mandatory Bronze capture for both
  allowed and blocked attempts.
  """
  use KiroCockpit.DataCase

  alias KiroCockpit.NanoPlanner
  alias KiroCockpit.Plans
  alias KiroCockpit.Swarm.{ActionBoundary, Hook, HookResult}

  # ── Fake session module (same as NanoPlannerTest) ────────────────────

  defmodule FakeKiroSession do
    @moduledoc false
    def state(_session) do
      Process.get(:fake_kiro_state) ||
        %{
          session_id: "boundary-test-session",
          cwd: Process.get(:fake_kiro_cwd)
        }
    end

    def prompt(_session, prompt_text, opts) do
      calls = Process.get(:fake_kiro_prompt_calls, [])
      Process.put(:fake_kiro_prompt_calls, calls ++ [{prompt_text, opts}])
      Process.get(:fake_kiro_prompt_result) || {:ok, %{}}
    end

    def recent_stream_events(_session, _opts) do
      Process.get(:fake_kiro_stream_events, [])
    end
  end

  # ── Blocking hook for testing blocked boundary attempts ─────────────

  defmodule AlwaysBlockNanoPlanHook do
    @moduledoc false
    @behaviour Hook

    @impl true
    def name, do: :always_block_nano_plan

    @impl true
    def priority, do: 200

    @impl true
    def filter(%KiroCockpit.Swarm.Event{action_name: action})
        when action in [:nano_plan_generate, :nano_plan_approve],
        do: true

    @impl true
    def filter(_event), do: false

    @impl true
    def on_event(event, _ctx) do
      HookResult.block(event, "blocked for boundary test", ["always_block_nano_plan blocked"])
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp valid_plan_map(overrides \\ %{}) do
    base = %{
      "objective" => "Boundary test plan",
      "summary" => "Test plan for boundary integration.",
      "phases" => [
        %{
          "number" => 1,
          "title" => "Phase 1",
          "steps" => [
            %{
              "title" => "Step 1",
              "details" => "Read-only discovery",
              "permission" => "read",
              "validation" => "Files visible"
            }
          ]
        }
      ],
      "permissions_needed" => ["read"],
      "acceptance_criteria" => ["Test passes"],
      "risks" => [],
      "execution_prompt" => "Execute the boundary test plan.",
      "plan_markdown" => "# Boundary Test Plan"
    }

    Map.merge(base, overrides)
  end

  defp setup_project_dir(_) do
    dir =
      System.tmp_dir!()
      |> Path.join("nano_planner_boundary_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "mix.exs"), "defmodule Test.Project do\nend")
    File.write!(Path.join(dir, "README.md"), "# Test Project")

    Process.put(:fake_kiro_cwd, dir)
    Process.put(:fake_kiro_state, %{session_id: "boundary-test-session", cwd: dir})
    Process.put(:fake_kiro_prompt_calls, [])
    Process.put(:fake_kiro_stream_events, [])

    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, project_dir: dir}
  end

  defp default_plan_opts(dir) do
    [
      kiro_session_module: FakeKiroSession,
      project_dir: dir,
      session_id: "boundary-test-session"
    ]
  end

  # ── nano_plan_generate boundary tests ────────────────────────────────

  describe "plan/3 :nano_plan_generate enters ActionBoundary" do
    setup [:setup_project_dir]

    test "writes Bronze hook_trace when hooks enabled", %{project_dir: dir} do
      Process.put(:fake_kiro_prompt_result, {:ok, valid_plan_map()})
      session_id = "boundary-gen-#{System.unique_integer([:positive])}"

      opts =
        default_plan_opts(dir)
        |> Keyword.put(:session_id, session_id)
        |> Keyword.put(:swarm_hooks, true)
        |> Keyword.put(:pre_hooks, [])
        |> Keyword.put(:post_hooks, [])

      assert {:ok, _plan} = NanoPlanner.plan(:fake_session, "Build it", opts)

      # Bronze hook_trace should be persisted by HookManager
      events = KiroCockpit.Swarm.Events.list_by_session(session_id, limit: 10)
      assert length(events) >= 1

      trace = List.first(events)
      assert trace.event_type == "hook_trace"
      # The hook_results should contain the nano_plan_generate action
      assert trace.hook_results["action"] == "nano_plan_generate"
    end

    test "boundary disabled (default test config) skips hooks and still works", %{
      project_dir: dir
    } do
      Process.put(:fake_kiro_prompt_result, {:ok, valid_plan_map()})
      # No swarm_hooks opt → defaults to Application env which is false in test

      assert {:ok, plan} =
               NanoPlanner.plan(:fake_session, "Build it", default_plan_opts(dir))

      assert plan.session_id == "boundary-test-session"
      assert plan.status == "draft"
    end

    test "boundary explicitly enabled via swarm_hooks: true", %{project_dir: dir} do
      Process.put(:fake_kiro_prompt_result, {:ok, valid_plan_map()})
      session_id = "boundary-explicit-#{System.unique_integer([:positive])}"

      opts =
        default_plan_opts(dir)
        |> Keyword.put(:session_id, session_id)
        |> Keyword.put(:swarm_hooks, true)
        |> Keyword.put(:pre_hooks, [])
        |> Keyword.put(:post_hooks, [])

      assert {:ok, plan} = NanoPlanner.plan(:fake_session, "Build it", opts)
      assert plan.status == "draft"
    end

    test "agent_id defaults to nano-planner", %{project_dir: dir} do
      Process.put(:fake_kiro_prompt_result, {:ok, valid_plan_map()})
      session_id = "boundary-agent-#{System.unique_integer([:positive])}"

      # Use a recording hook to capture what the boundary sees
      defmodule AgentIdRecordingHook do
        @moduledoc false
        @behaviour Hook

        @impl true
        def name, do: :agent_id_recorder
        @impl true
        def priority, do: 50
        @impl true
        def filter(_), do: true
        @impl true
        def on_event(event, _ctx) do
          Process.put(:recorded_agent_id, event.agent_id)
          HookResult.continue(event)
        end
      end

      opts =
        default_plan_opts(dir)
        |> Keyword.put(:session_id, session_id)
        |> Keyword.put(:swarm_hooks, true)
        |> Keyword.put(:pre_hooks, [AgentIdRecordingHook])
        |> Keyword.put(:post_hooks, [])

      assert {:ok, _plan} = NanoPlanner.plan(:fake_session, "Build it", opts)
      assert Process.get(:recorded_agent_id) == "nano-planner"
    after
      Process.delete(:recorded_agent_id)
    end

    test "custom agent_id overrides default", %{project_dir: dir} do
      Process.put(:fake_kiro_prompt_result, {:ok, valid_plan_map()})
      session_id = "boundary-agent-custom-#{System.unique_integer([:positive])}"

      defmodule CustomAgentIdHook do
        @moduledoc false
        @behaviour Hook

        @impl true
        def name, do: :custom_agent_id_recorder
        @impl true
        def priority, do: 50
        @impl true
        def filter(_), do: true
        @impl true
        def on_event(event, _ctx) do
          Process.put(:recorded_custom_agent_id, event.agent_id)
          HookResult.continue(event)
        end
      end

      opts =
        default_plan_opts(dir)
        |> Keyword.put(:session_id, session_id)
        |> Keyword.put(:swarm_hooks, true)
        |> Keyword.put(:agent_id, "custom-agent")
        |> Keyword.put(:pre_hooks, [CustomAgentIdHook])
        |> Keyword.put(:post_hooks, [])

      assert {:ok, _plan} = NanoPlanner.plan(:fake_session, "Build it", opts)
      assert Process.get(:recorded_custom_agent_id) == "custom-agent"
    after
      Process.delete(:recorded_custom_agent_id)
    end
  end

  describe "plan/3 :nano_plan_generate blocked attempts" do
    setup [:setup_project_dir]

    test "blocked via custom pre hook does not execute underlying planner", %{project_dir: dir} do
      Process.put(:fake_kiro_prompt_result, {:ok, valid_plan_map()})
      session_id = "boundary-block-gen-#{System.unique_integer([:positive])}"
      Process.put(:fake_kiro_prompt_calls, [])

      opts =
        default_plan_opts(dir)
        |> Keyword.put(:session_id, session_id)
        |> Keyword.put(:swarm_hooks, true)
        |> Keyword.put(:pre_hooks, [AlwaysBlockNanoPlanHook])
        |> Keyword.put(:post_hooks, [])

      result = NanoPlanner.plan(:fake_session, "Build it", opts)

      assert {:error, {:swarm_blocked, reason, messages}} = result
      assert reason == "blocked for boundary test"
      assert "always_block_nano_plan blocked" in messages

      # The underlying planner (session prompt) was never called
      calls = Process.get(:fake_kiro_prompt_calls, [])
      assert calls == []

      # Bronze trace is still persisted for the blocked attempt
      events = KiroCockpit.Swarm.Events.list_by_session(session_id, limit: 10)
      assert length(events) >= 1
      trace = List.first(events)
      assert trace.event_type == "hook_trace"
      assert trace.hook_results["outcome"] == "blocked"
    end
  end

  # ── nano_plan_approve boundary tests ─────────────────────────────────

  describe "approve/3 :nano_plan_approve enters ActionBoundary" do
    setup [:setup_project_dir]

    test "writes Bronze hook_trace when hooks enabled", %{project_dir: dir} do
      Process.put(:fake_kiro_prompt_result, {:ok, valid_plan_map()})
      session_id = "boundary-approve-#{System.unique_integer([:positive])}"

      plan_opts =
        default_plan_opts(dir)
        |> Keyword.put(:session_id, session_id)

      assert {:ok, plan} = NanoPlanner.plan(:fake_session, "Build it", plan_opts)

      # Approve with hooks enabled
      Process.put(:fake_kiro_prompt_result, {:ok, %{"stopReason" => "end_turn"}})
      Process.put(:fake_kiro_prompt_calls, [])

      approve_opts =
        [
          kiro_session_module: FakeKiroSession,
          project_dir: dir,
          session_id: session_id,
          swarm_hooks: true,
          pre_hooks: [],
          post_hooks: []
        ]

      assert {:ok, %{plan: approved_plan}} =
               NanoPlanner.approve(:fake_session, plan.id, approve_opts)

      assert approved_plan.status == "approved"

      # Bronze trace persisted
      events = KiroCockpit.Swarm.Events.list_by_session(session_id, limit: 10)
      assert length(events) >= 1

      # Find the approve trace (may also have a generate trace from a prior test,
      # but this session is unique so only this approve should be present)
      approve_traces =
        Enum.filter(events, fn e ->
          e.hook_results["action"] == "nano_plan_approve"
        end)

      assert length(approve_traces) >= 1
      trace = List.first(approve_traces)
      assert trace.event_type == "hook_trace"
      assert trace.hook_results["outcome"] == "ok"
    end

    test "approve with hooks disabled (default test config) still works", %{project_dir: dir} do
      Process.put(:fake_kiro_prompt_result, {:ok, valid_plan_map()})
      Process.put(:fake_kiro_prompt_calls, [])

      assert {:ok, plan} =
               NanoPlanner.plan(:fake_session, "Build it", default_plan_opts(dir))

      Process.put(:fake_kiro_prompt_result, {:ok, %{"stopReason" => "end_turn"}})
      Process.put(:fake_kiro_prompt_calls, [])

      assert {:ok, %{plan: approved_plan}} =
               NanoPlanner.approve(:fake_session, plan.id,
                 kiro_session_module: FakeKiroSession,
                 project_dir: dir
               )

      assert approved_plan.status == "approved"
    end
  end

  describe "approve/3 :nano_plan_approve blocked attempts" do
    setup [:setup_project_dir]

    test "blocked via custom pre hook does not execute approve", %{project_dir: dir} do
      Process.put(:fake_kiro_prompt_result, {:ok, valid_plan_map()})
      session_id = "boundary-block-approve-#{System.unique_integer([:positive])}"

      plan_opts =
        default_plan_opts(dir)
        |> Keyword.put(:session_id, session_id)

      assert {:ok, plan} = NanoPlanner.plan(:fake_session, "Build it", plan_opts)

      # Approve with blocking hook
      Process.put(:fake_kiro_prompt_result, {:ok, %{"stopReason" => "end_turn"}})
      Process.put(:fake_kiro_prompt_calls, [])

      approve_opts =
        [
          kiro_session_module: FakeKiroSession,
          project_dir: dir,
          session_id: session_id,
          swarm_hooks: true,
          pre_hooks: [AlwaysBlockNanoPlanHook],
          post_hooks: []
        ]

      result = NanoPlanner.approve(:fake_session, plan.id, approve_opts)

      assert {:error, {:swarm_blocked, reason, messages}} = result
      assert reason == "blocked for boundary test"
      assert "always_block_nano_plan blocked" in messages

      # The approve + prompt send never ran
      calls = Process.get(:fake_kiro_prompt_calls, [])
      assert calls == []

      # Plan should still be in draft status (not approved)
      refute_plan = Plans.get_plan(plan.id)
      assert refute_plan.status == "draft"

      # Bronze trace persisted for the blocked attempt
      events = KiroCockpit.Swarm.Events.list_by_session(session_id, limit: 10)

      approve_traces =
        Enum.filter(events, fn e ->
          e.hook_results["action"] == "nano_plan_approve"
        end)

      assert length(approve_traces) >= 1
      trace = List.first(approve_traces)
      assert trace.event_type == "hook_trace"
      assert trace.hook_results["outcome"] == "blocked"
    end
  end

  # ── Lifecycle active-task exemption tests ─────────────────────────────

  describe "nano_plan_generate/approve lifecycle active-task exemption" do
    setup [:setup_project_dir]

    test "nano_plan_generate does not require active task", %{project_dir: dir} do
      Process.put(:fake_kiro_prompt_result, {:ok, valid_plan_map()})
      session_id = "lifecycle-gen-#{System.unique_integer([:positive])}"

      # Use TaskEnforcementHook (requires active task for most actions)
      # but nano_plan_generate is a lifecycle action exempt from that
      opts =
        default_plan_opts(dir)
        |> Keyword.put(:session_id, session_id)
        |> Keyword.put(:swarm_hooks, true)
        |> Keyword.put(:pre_hooks, [KiroCockpit.Swarm.Hooks.TaskEnforcementHook])
        |> Keyword.put(:post_hooks, [])

      # No active task created — lifecycle action should still pass
      assert {:ok, plan} = NanoPlanner.plan(:fake_session, "Build it", opts)
      assert plan.status == "draft"
    end

    test "nano_plan_approve does not require active task", %{project_dir: dir} do
      Process.put(:fake_kiro_prompt_result, {:ok, valid_plan_map()})
      session_id = "lifecycle-approve-#{System.unique_integer([:positive])}"

      plan_opts =
        default_plan_opts(dir)
        |> Keyword.put(:session_id, session_id)

      assert {:ok, plan} = NanoPlanner.plan(:fake_session, "Build it", plan_opts)

      # Approve with TaskEnforcementHook but no active task
      Process.put(:fake_kiro_prompt_result, {:ok, %{"stopReason" => "end_turn"}})
      Process.put(:fake_kiro_prompt_calls, [])

      # Build an approved plan_mode so plan-mode check passes
      plan_mode = KiroCockpit.Swarm.PlanMode.new()
      {:ok, plan_mode} = KiroCockpit.Swarm.PlanMode.enter_plan_mode(plan_mode)
      {:ok, plan_mode} = KiroCockpit.Swarm.PlanMode.draft_generated(plan_mode)
      {:ok, plan_mode} = KiroCockpit.Swarm.PlanMode.approve(plan_mode)

      approve_opts =
        [
          kiro_session_module: FakeKiroSession,
          project_dir: dir,
          session_id: session_id,
          swarm_hooks: true,
          plan_mode: plan_mode,
          pre_hooks: [KiroCockpit.Swarm.Hooks.TaskEnforcementHook],
          post_hooks: []
        ]

      assert {:ok, %{plan: approved_plan}} =
               NanoPlanner.approve(:fake_session, plan.id, approve_opts)

      assert approved_plan.status == "approved"
    end

    test "nano_plan_generate is blocked by stale plan context", %{project_dir: dir} do
      Process.put(:fake_kiro_prompt_result, {:ok, valid_plan_map()})
      session_id = "lifecycle-stale-gen-#{System.unique_integer([:positive])}"

      opts =
        default_plan_opts(dir)
        |> Keyword.put(:session_id, session_id)
        |> Keyword.put(:swarm_hooks, true)
        |> Keyword.put(:swarm_ctx, %{stale_plan?: true, reason: :stale_plan})
        |> Keyword.put(:pre_hooks, [KiroCockpit.Swarm.Hooks.TaskEnforcementHook])
        |> Keyword.put(:post_hooks, [])

      # nano_plan_generate has :subagent permission — still
      # mutating from stale-plan perspective (not :read/:shell_read),
      # so stale context blocks it
      result = NanoPlanner.plan(:fake_session, "Build it", opts)
      assert {:error, {:swarm_blocked, reason, _messages}} = result
      assert reason =~ "Stale plan"
    end

    test "nano_plan_approve blocked by boundary stale check", %{project_dir: dir} do
      Process.put(:fake_kiro_prompt_result, {:ok, valid_plan_map()})
      session_id = "lifecycle-stale-approve-#{System.unique_integer([:positive])}"

      plan_opts =
        default_plan_opts(dir)
        |> Keyword.put(:session_id, session_id)

      assert {:ok, plan} = NanoPlanner.plan(:fake_session, "Build it", plan_opts)

      # Make the project stale by changing a file (snapshot hash differs)
      File.write!(Path.join(dir, "STALE_TRIGGER.md"), "# Stale content")

      Process.put(:fake_kiro_prompt_result, {:ok, %{"stopReason" => "end_turn"}})
      Process.put(:fake_kiro_prompt_calls, [])

      approve_opts =
        [
          kiro_session_module: FakeKiroSession,
          project_dir: dir,
          session_id: session_id,
          swarm_hooks: true,
          pre_hooks: [KiroCockpit.Swarm.Hooks.TaskEnforcementHook],
          post_hooks: []
        ]

      result = NanoPlanner.approve(:fake_session, plan.id, approve_opts)

      # Staleness is now checked inside the boundary via TaskEnforcementHook,
      # which blocks the stale plan and returns {:error, {:swarm_blocked, ...}}
      assert {:error, {:swarm_blocked, reason, _messages}} = result
      assert reason =~ "Stale plan"

      # Plan should still be draft (not approved)
      refreshed = KiroCockpit.Plans.get_plan(plan.id)
      assert refreshed.status == "draft"

      # No prompt should have been sent
      calls = Process.get(:fake_kiro_prompt_calls, [])
      assert calls == []

      # Bronze trace should be persisted for the blocked attempt
      events = KiroCockpit.Swarm.Events.list_by_session(session_id, limit: 10)

      approve_traces =
        Enum.filter(events, fn e ->
          e.hook_results["action"] == "nano_plan_approve"
        end)

      assert length(approve_traces) >= 1
      trace = List.first(approve_traces)
      assert trace.event_type == "hook_trace"
      assert trace.hook_results["outcome"] == "blocked"
    end
  end

  # ── Stale plan override tests ─────────────────────────────────────────

  describe "stale plan trusted override for approve/3" do
    setup [:setup_project_dir]

    test "stale_plan_confirmed? allows stale approve through boundary", %{project_dir: dir} do
      Process.put(:fake_kiro_prompt_result, {:ok, valid_plan_map()})
      session_id = "override-approve-#{System.unique_integer([:positive])}"

      plan_opts =
        default_plan_opts(dir)
        |> Keyword.put(:session_id, session_id)

      assert {:ok, plan} = NanoPlanner.plan(:fake_session, "Build it", plan_opts)

      # Make the project stale
      File.write!(Path.join(dir, "OVERRIDE_TEST.md"), "# Stale override test")

      Process.put(:fake_kiro_prompt_result, {:ok, %{"stopReason" => "end_turn"}})
      Process.put(:fake_kiro_prompt_calls, [])

      # Approve with stale_plan_confirmed? override — should succeed
      approve_opts = [
        kiro_session_module: FakeKiroSession,
        project_dir: dir,
        session_id: session_id,
        swarm_hooks: true,
        stale_plan_confirmed?: true,
        pre_hooks: [KiroCockpit.Swarm.Hooks.TaskEnforcementHook],
        post_hooks: []
      ]

      assert {:ok, %{plan: approved_plan}} =
               NanoPlanner.approve(:fake_session, plan.id, approve_opts)

      assert approved_plan.status == "approved"

      # Bronze trace should show allowed outcome
      events = KiroCockpit.Swarm.Events.list_by_session(session_id, limit: 10)

      approve_traces =
        Enum.filter(events, fn e ->
          e.hook_results["action"] == "nano_plan_approve"
        end)

      assert length(approve_traces) >= 1
      trace = List.first(approve_traces)
      assert trace.event_type == "hook_trace"
      assert trace.hook_results["outcome"] == "ok"
    end

    test "stale_plan_override? allows stale approve through boundary", %{project_dir: dir} do
      Process.put(:fake_kiro_prompt_result, {:ok, valid_plan_map()})
      session_id = "override-approve2-#{System.unique_integer([:positive])}"

      plan_opts =
        default_plan_opts(dir)
        |> Keyword.put(:session_id, session_id)

      assert {:ok, plan} = NanoPlanner.plan(:fake_session, "Build it", plan_opts)

      # Make the project stale
      File.write!(Path.join(dir, "OVERRIDE2.md"), "# Stale override test 2")

      Process.put(:fake_kiro_prompt_result, {:ok, %{"stopReason" => "end_turn"}})
      Process.put(:fake_kiro_prompt_calls, [])

      approve_opts = [
        kiro_session_module: FakeKiroSession,
        project_dir: dir,
        session_id: session_id,
        swarm_hooks: true,
        stale_plan_override?: true,
        pre_hooks: [KiroCockpit.Swarm.Hooks.TaskEnforcementHook],
        post_hooks: []
      ]

      assert {:ok, %{plan: approved_plan}} =
               NanoPlanner.approve(:fake_session, plan.id, approve_opts)

      assert approved_plan.status == "approved"
    end

    test "payload/metadata cannot bypass stale check for approve", %{project_dir: dir} do
      Process.put(:fake_kiro_prompt_result, {:ok, valid_plan_map()})
      session_id = "payload-stale-approve-#{System.unique_integer([:positive])}"

      plan_opts =
        default_plan_opts(dir)
        |> Keyword.put(:session_id, session_id)

      assert {:ok, plan} = NanoPlanner.plan(:fake_session, "Build it", plan_opts)

      # Make the project stale
      File.write!(Path.join(dir, "PAYLOAD_TEST.md"), "# Payload override attempt")

      Process.put(:fake_kiro_prompt_result, {:ok, %{"stopReason" => "end_turn"}})
      Process.put(:fake_kiro_prompt_calls, [])

      # Attempt override via payload — must be ignored by trusted ctx
      approve_opts = [
        kiro_session_module: FakeKiroSession,
        project_dir: dir,
        session_id: session_id,
        swarm_hooks: true,
        payload: %{stale_plan_override?: true, stale_plan_confirmed?: true},
        pre_hooks: [KiroCockpit.Swarm.Hooks.TaskEnforcementHook],
        post_hooks: []
      ]

      result = NanoPlanner.approve(:fake_session, plan.id, approve_opts)

      # Should still be blocked — payload is not trusted for stale override
      assert {:error, {:swarm_blocked, reason, _messages}} = result
      assert reason =~ "Stale plan"

      # Plan should still be draft
      refreshed = KiroCockpit.Plans.get_plan(plan.id)
      assert refreshed.status == "draft"
    end

    test "metadata cannot bypass stale check for approve", %{project_dir: dir} do
      Process.put(:fake_kiro_prompt_result, {:ok, valid_plan_map()})
      session_id = "meta-stale-approve-#{System.unique_integer([:positive])}"

      plan_opts =
        default_plan_opts(dir)
        |> Keyword.put(:session_id, session_id)

      assert {:ok, plan} = NanoPlanner.plan(:fake_session, "Build it", plan_opts)

      # Make the project stale
      File.write!(Path.join(dir, "META_TEST.md"), "# Metadata override attempt")

      Process.put(:fake_kiro_prompt_result, {:ok, %{"stopReason" => "end_turn"}})
      Process.put(:fake_kiro_prompt_calls, [])

      # Attempt override via metadata — must be ignored by trusted ctx
      approve_opts = [
        kiro_session_module: FakeKiroSession,
        project_dir: dir,
        session_id: session_id,
        swarm_hooks: true,
        metadata: %{stale_plan_override?: true, stale_plan_confirmed?: true},
        pre_hooks: [KiroCockpit.Swarm.Hooks.TaskEnforcementHook],
        post_hooks: []
      ]

      result = NanoPlanner.approve(:fake_session, plan.id, approve_opts)

      # Should still be blocked — metadata is not trusted for stale override
      assert {:error, {:swarm_blocked, reason, _messages}} = result
      assert reason =~ "Stale plan"

      # Plan should still be draft
      refreshed = KiroCockpit.Plans.get_plan(plan.id)
      assert refreshed.status == "draft"
    end
  end

  describe "stale plan trusted override for run_plan" do
    setup [:setup_project_dir]

    test "stale_plan_confirmed? allows stale run through boundary", %{project_dir: dir} do
      {:ok, plan} =
        KiroCockpit.Plans.create_plan(
          "override-run-sess",
          "req",
          :nano,
          [],
          %{
            plan_markdown: "# Plan",
            execution_prompt: "Execute",
            raw_model_output: %{},
            project_snapshot_hash: compute_hash(dir)
          }
        )

      {:ok, approved} = KiroCockpit.Plans.approve_plan(plan.id)

      # Make the project stale
      File.write!(Path.join(dir, "RUN_OVERRIDE.md"), "# Run stale override")

      # Run with stale_plan_confirmed? override
      assert {:ok, running} =
               KiroCockpit.Plans.run_plan(approved.id,
                 project_dir: dir,
                 session_id: "override-run-sess",
                 swarm_hooks: true,
                 stale_plan_confirmed?: true,
                 pre_hooks: [KiroCockpit.Swarm.Hooks.TaskEnforcementHook],
                 post_hooks: []
               )

      assert running.status == "running"
    end

    test "stale_plan_override? allows stale run through boundary", %{project_dir: dir} do
      {:ok, plan} =
        KiroCockpit.Plans.create_plan(
          "override-run-sess2",
          "req",
          :nano,
          [],
          %{
            plan_markdown: "# Plan",
            execution_prompt: "Execute",
            raw_model_output: %{},
            project_snapshot_hash: compute_hash(dir)
          }
        )

      {:ok, approved} = KiroCockpit.Plans.approve_plan(plan.id)

      # Make the project stale
      File.write!(Path.join(dir, "RUN_OVERRIDE2.md"), "# Run stale override 2")

      assert {:ok, running} =
               KiroCockpit.Plans.run_plan(approved.id,
                 project_dir: dir,
                 session_id: "override-run-sess2",
                 swarm_hooks: true,
                 stale_plan_override?: true,
                 pre_hooks: [KiroCockpit.Swarm.Hooks.TaskEnforcementHook],
                 post_hooks: []
               )

      assert running.status == "running"
    end

    test "payload/metadata cannot bypass stale check for run", %{project_dir: dir} do
      {:ok, plan} =
        KiroCockpit.Plans.create_plan(
          "payload-run-sess",
          "req",
          :nano,
          [],
          %{
            plan_markdown: "# Plan",
            execution_prompt: "Execute",
            raw_model_output: %{},
            project_snapshot_hash: compute_hash(dir)
          }
        )

      {:ok, approved} = KiroCockpit.Plans.approve_plan(plan.id)

      # Make the project stale
      File.write!(Path.join(dir, "PAYLOAD_RUN.md"), "# Payload run override attempt")

      # Attempt override via payload in opts — must be ignored by trusted ctx
      result =
        KiroCockpit.Plans.run_plan(approved.id,
          project_dir: dir,
          session_id: "payload-run-sess",
          swarm_hooks: true,
          payload: %{stale_plan_override?: true, stale_plan_confirmed?: true},
          pre_hooks: [KiroCockpit.Swarm.Hooks.TaskEnforcementHook],
          post_hooks: []
        )

      assert {:error, {:swarm_blocked, reason}} = result
      assert reason =~ "Stale plan"

      # Plan should not transition
      refreshed = KiroCockpit.Plans.get_plan(approved.id)
      assert refreshed.status == "approved"
    end
  end

  # ── Full standard hook chain integration ──────────────────────────────

  describe "nano_plan_generate with standard hook chain" do
    setup [:setup_project_dir]

    test "runs through PlanModeFirstActionHook + TaskEnforcementHook + SteeringPreActionHook",
         %{project_dir: dir} do
      Process.put(:fake_kiro_prompt_result, {:ok, valid_plan_map()})
      session_id = "full-chain-gen-#{System.unique_integer([:positive])}"

      # Build a plan-mode in planning state (read-only allowed)
      plan_mode = KiroCockpit.Swarm.PlanMode.new()
      {:ok, plan_mode} = KiroCockpit.Swarm.PlanMode.enter_plan_mode(plan_mode)

      opts =
        default_plan_opts(dir)
        |> Keyword.put(:session_id, session_id)
        |> Keyword.put(:swarm_hooks, true)
        |> Keyword.put(:plan_mode, plan_mode)
        |> Keyword.put(:pre_hooks, ActionBoundary.default_pre_hooks())
        |> Keyword.put(:post_hooks, ActionBoundary.default_post_hooks())

      # nano_plan_generate (:subagent permission) should be blocked in
      # planning-locked state because subagent is not a read-only permission
      result = NanoPlanner.plan(:fake_session, "Build it", opts)

      # PlanMode blocks subagent in planning state
      assert {:error, {:swarm_blocked, reason, _messages}} = result
      # PlanMode blocks with "Action blocked during planning" or similar
      assert is_binary(reason)
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────

  defp compute_hash(project_dir) do
    {:ok, snapshot} = KiroCockpit.NanoPlanner.ContextBuilder.build(project_dir: project_dir)
    snapshot.hash
  end
end
