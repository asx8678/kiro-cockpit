defmodule KiroCockpit.NanoPlannerIntegrationTest do
  @moduledoc """
  Integration tests for NanoPlanner service + Plans context.

  Exercises the real NanoPlanner module with an injected FakeKiroSession
  (no real Kiro subprocess or model calls). Proves the full pipeline:
  plan → persist → approve (sends execution_prompt) → revise (supersedes).

  Targets plan2.md §17 acceptance criteria:
    - fake planner saves draft plan / canned model output path
    - approve sends execution_prompt through KiroSession (routing, not DB-only)
    - revise supersedes old plan
    - approval routing for CLI path (proves commands do not bypass NanoPlanner
      when an injected planner is configured)
  """

  use KiroCockpit.DataCase

  alias KiroCockpit.NanoPlanner
  alias KiroCockpit.Plans

  # ── Injectable fake KiroSession ─────────────────────────────────────

  defmodule FakeKiroSession do
    @moduledoc false

    def state(_session) do
      Process.get(:fake_kiro_state) ||
        %{
          session_id: "int-test-session",
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

  # ── Helpers ──────────────────────────────────────────────────────────

  defp valid_plan_map(overrides \\ %{}) do
    base = %{
      "objective" => "Build dashboard widget",
      "summary" => "Add a LiveView dashboard widget for plan status.",
      "phases" => [
        %{
          "number" => 1,
          "title" => "Foundation",
          "steps" => [
            %{
              "title" => "Create widget schema",
              "details" => "Add Ecto schema for widget config.",
              "files" => %{"lib/kiro_cockpit/widget.ex" => ""},
              "permission" => "write",
              "validation" => "Unit test schema."
            },
            %{
              "title" => "Read existing layout",
              "details" => "Survey current dashboard layout files.",
              "files" => %{"lib/kiro_cockpit_web/live/dashboard_live.ex" => "read"},
              "permission" => "read",
              "validation" => "Layout files listed."
            }
          ]
        },
        %{
          "number" => 2,
          "title" => "Integration",
          "steps" => [
            %{
              "title" => "Wire widget to LiveView",
              "details" => "Render widget in dashboard LiveView.",
              "files" => %{"lib/kiro_cockpit_web/live/dashboard_live.ex" => "write"},
              "permission" => "write",
              "validation" => "Widget renders."
            }
          ]
        }
      ],
      "permissions_needed" => ["read", "write"],
      "acceptance_criteria" => [
        "Widget renders in dashboard",
        "Schema persists config"
      ],
      "risks" => [
        %{"risk" => "Layout conflicts", "mitigation" => "Use scoped CSS"}
      ],
      "execution_prompt" => "Execute the approved dashboard widget plan phase by phase.",
      "plan_markdown" => "# Plan: Dashboard Widget"
    }

    Map.merge(base, overrides)
  end

  defp setup_project_dir(_) do
    dir =
      System.tmp_dir!()
      |> Path.join("nano_planner_int_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "mix.exs"), "defmodule IntTest.Project do\nend")
    File.write!(Path.join(dir, "README.md"), "# Integration Test Project")

    Process.put(:fake_kiro_cwd, dir)
    Process.put(:fake_kiro_state, %{session_id: "int-test-session", cwd: dir})
    Process.put(:fake_kiro_prompt_calls, [])
    Process.put(:fake_kiro_stream_events, [])

    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, project_dir: dir}
  end

  defp default_plan_opts(dir) do
    [
      kiro_session_module: FakeKiroSession,
      project_dir: dir,
      session_id: "int-test-session"
    ]
  end

  # ── Fake planner saves draft plan / canned model output path ─────────

  describe "plan/3 with canned model output — fake planner pipeline" do
    setup [:setup_project_dir]

    test "saves a draft plan with execution_prompt from canned model output", %{
      project_dir: dir
    } do
      canned = valid_plan_map()
      Process.put(:fake_kiro_prompt_result, {:ok, canned})

      assert {:ok, plan} =
               NanoPlanner.plan(:fake_session, "Build dashboard widget", default_plan_opts(dir))

      # Draft status
      assert plan.status == "draft"
      assert plan.session_id == "int-test-session"
      assert plan.mode == "nano"
      assert plan.user_request == "Build dashboard widget"

      # Canned model output path: execution_prompt extracted and persisted
      assert plan.execution_prompt == "Execute the approved dashboard widget plan phase by phase."
      assert plan.plan_markdown == "# Plan: Dashboard Widget"

      # Raw model output persisted for debugging
      assert plan.raw_model_output["objective"] == "Build dashboard widget"
      assert plan.raw_model_output["permissions_needed"] == ["read", "write"]

      # Steps persisted from canned phases
      assert length(plan.plan_steps) == 3

      step_titles = Enum.map(plan.plan_steps, & &1.title)
      assert "Create widget schema" in step_titles
      assert "Read existing layout" in step_titles
      assert "Wire widget to LiveView" in step_titles

      # Phases and permissions from canned output
      phases = Enum.group_by(plan.plan_steps, & &1.phase_number)
      assert Map.has_key?(phases, 1)
      assert Map.has_key?(phases, 2)

      permissions = Enum.map(plan.plan_steps, & &1.permission_level) |> Enum.uniq() |> Enum.sort()
      assert permissions == ["read", "write"]
    end

    test "saves project snapshot hash from canned context builder", %{project_dir: dir} do
      Process.put(:fake_kiro_prompt_result, {:ok, valid_plan_map()})

      assert {:ok, plan} =
               NanoPlanner.plan(:fake_session, "Build dashboard widget", default_plan_opts(dir))

      assert plan.project_snapshot_hash != ""
      assert is_binary(plan.project_snapshot_hash)
    end

    test "plan mode is persisted from opts, not from model output", %{project_dir: dir} do
      Process.put(:fake_kiro_prompt_result, {:ok, valid_plan_map()})

      assert {:ok, plan} =
               NanoPlanner.plan(
                 :fake_session,
                 "Deep analysis request",
                 Keyword.put(default_plan_opts(dir), :mode, :nano_deep)
               )

      assert plan.mode == "nano_deep"
    end
  end

  # ── Approve sends execution_prompt through KiroSession ───────────────

  describe "approve/3 routes execution_prompt through KiroSession" do
    setup [:setup_project_dir]

    test "sends execution_prompt to KiroSession on approval (not DB-only)", %{
      project_dir: dir
    } do
      Process.put(:fake_kiro_prompt_result, {:ok, valid_plan_map()})
      Process.put(:fake_kiro_prompt_calls, [])

      assert {:ok, plan} =
               NanoPlanner.plan(:fake_session, "Build dashboard widget", default_plan_opts(dir))

      # Clear calls from plan generation
      Process.put(:fake_kiro_prompt_calls, [])

      # Approve: the model call for execution prompt
      Process.put(:fake_kiro_prompt_result, {:ok, %{"stopReason" => "end_turn"}})

      assert {:ok, %{plan: approved_plan, prompt_result: result}} =
               NanoPlanner.approve(:fake_session, plan.id,
                 kiro_session_module: FakeKiroSession,
                 project_dir: dir
               )

      assert approved_plan.status == "approved"
      assert approved_plan.approved_at != nil

      # THE KEY ASSERTION: prompt/3 was called with the execution_prompt
      calls = Process.get(:fake_kiro_prompt_calls, [])
      assert length(calls) == 1

      {prompt_text, _opts} = hd(calls)
      assert prompt_text == "Execute the approved dashboard widget plan phase by phase."

      # Result from KiroSession returned
      assert result == %{"stopReason" => "end_turn"}
    end

    test "returns prompt_failed when KiroSession prompt fails after DB approval", %{
      project_dir: dir
    } do
      Process.put(:fake_kiro_prompt_result, {:ok, valid_plan_map()})
      Process.put(:fake_kiro_prompt_calls, [])

      assert {:ok, plan} =
               NanoPlanner.plan(:fake_session, "Build dashboard widget", default_plan_opts(dir))

      # Prompt send fails
      Process.put(:fake_kiro_prompt_result, {:error, :connection_lost})
      Process.put(:fake_kiro_prompt_calls, [])

      assert {:error, {:prompt_failed, failed_plan, :connection_lost}} =
               NanoPlanner.approve(:fake_session, plan.id,
                 kiro_session_module: FakeKiroSession,
                 project_dir: dir
               )

      # Plan was still approved in DB
      assert failed_plan.status == "approved"
      assert failed_plan.id == plan.id

      # But prompt WAS attempted (proving routing, not DB-only)
      calls = Process.get(:fake_kiro_prompt_calls, [])
      assert length(calls) == 1
    end

    test "detects stale plan when snapshot hash differs via boundary", %{project_dir: dir} do
      Process.put(:fake_kiro_prompt_result, {:ok, valid_plan_map()})
      session_id = "integ-stale-#{System.unique_integer([:positive])}"

      plan_opts = default_plan_opts(dir) |> Keyword.put(:session_id, session_id)

      assert {:ok, plan} =
               NanoPlanner.plan(:fake_session, "Build dashboard widget", plan_opts)

      # Modify the project so the snapshot hash changes
      File.write!(Path.join(dir, "STALE_MARKER.md"), "# This changes the hash")

      Process.put(:fake_kiro_prompt_calls, [])

      assert {:error, {:swarm_blocked, reason, _messages}} =
               NanoPlanner.approve(:fake_session, plan.id,
                 kiro_session_module: FakeKiroSession,
                 project_dir: dir,
                 session_id: session_id,
                 swarm_hooks: true,
                 pre_hooks: [KiroCockpit.Swarm.Hooks.TaskEnforcementHook],
                 post_hooks: []
               )

      assert reason =~ "Stale plan"

      # Plan should still be draft (not approved)
      refreshed = Plans.get_plan(plan.id)
      assert refreshed.status == "draft"

      # No prompt should have been sent
      calls = Process.get(:fake_kiro_prompt_calls, [])
      assert calls == []

      # Bronze trace should be persisted
      events = KiroCockpit.Swarm.Events.list_by_session(session_id, limit: 10)
      assert length(events) >= 1
      trace = List.first(events)
      assert trace.event_type == "hook_trace"
      assert trace.hook_results["outcome"] == "blocked"
      assert trace.hook_results["action"] == "nano_plan_approve"
    end
  end

  # ── Revise supersedes old plan ──────────────────────────────────────

  describe "revise/4 supersedes old plan" do
    setup [:setup_project_dir]

    test "old plan is superseded only after new plan is persisted", %{project_dir: dir} do
      Process.put(:fake_kiro_prompt_result, {:ok, valid_plan_map()})

      assert {:ok, old_plan} =
               NanoPlanner.plan(:fake_session, "Build dashboard widget", default_plan_opts(dir))

      assert old_plan.status == "draft"

      revised_map =
        Map.merge(valid_plan_map(), %{
          "objective" => "Revised dashboard widget",
          "execution_prompt" => "Execute the revised plan.",
          "plan_markdown" => "# Revised Plan"
        })

      Process.put(:fake_kiro_prompt_result, {:ok, revised_map})

      assert {:ok, new_plan} =
               NanoPlanner.revise(
                 :fake_session,
                 old_plan.id,
                 "Add error handling",
                 default_plan_opts(dir)
               )

      # New plan is draft
      assert new_plan.status == "draft"
      assert new_plan.execution_prompt == "Execute the revised plan."
      assert new_plan.user_request =~ "Add error handling"

      # Old plan is superseded
      refreshed_old = Plans.get_plan(old_plan.id)
      assert refreshed_old.status == "superseded"

      # Both plans exist for the session
      all_plans = Plans.list_plans("int-test-session")
      assert length(all_plans) == 2
      statuses = Enum.map(all_plans, & &1.status) |> Enum.sort()
      assert "draft" in statuses
      assert "superseded" in statuses
    end

    test "old plan remains draft when revision model call fails", %{project_dir: dir} do
      Process.put(:fake_kiro_prompt_result, {:ok, valid_plan_map()})

      assert {:ok, old_plan} =
               NanoPlanner.plan(:fake_session, "Build dashboard widget", default_plan_opts(dir))

      # Model call fails
      Process.put(:fake_kiro_prompt_result, {:error, :timeout})

      assert {:error, :timeout} =
               NanoPlanner.revise(
                 :fake_session,
                 old_plan.id,
                 "Please revise",
                 default_plan_opts(dir)
               )

      # Old plan is still draft
      refreshed = Plans.get_plan(old_plan.id)
      assert refreshed.status == "draft"
    end

    test "revision preserves old plan's mode", %{project_dir: dir} do
      Process.put(:fake_kiro_prompt_result, {:ok, valid_plan_map()})

      assert {:ok, old_plan} =
               NanoPlanner.plan(
                 :fake_session,
                 "Build dashboard widget",
                 Keyword.put(default_plan_opts(dir), :mode, :nano_fix)
               )

      assert old_plan.mode == "nano_fix"

      Process.put(:fake_kiro_prompt_result, {:ok, valid_plan_map()})

      assert {:ok, new_plan} =
               NanoPlanner.revise(
                 :fake_session,
                 old_plan.id,
                 "Fix also the edge case",
                 default_plan_opts(dir)
               )

      # Mode preserved from old plan
      assert new_plan.mode == "nano_fix"
    end
  end

  # ── CLI approval routing ────────────────────────────────────────────

  describe "CLI /plan approve routing through NanoPlanner" do
    setup [:setup_project_dir]

    test "CLI approve delegates to NanoPlanner.approve (not Plans.approve_plan)", %{
      project_dir: dir
    } do
      alias KiroCockpit.CLI.Commands.Plan

      Process.put(:fake_kiro_prompt_result, {:ok, valid_plan_map()})
      Process.put(:fake_kiro_prompt_calls, [])

      assert {:ok, db_plan} =
               NanoPlanner.plan(:fake_session, "Build dashboard widget", default_plan_opts(dir))

      # Clear prompt calls from plan generation
      Process.put(:fake_kiro_prompt_calls, [])

      # Set up approve response
      Process.put(:fake_kiro_prompt_result, {:ok, %{"stopReason" => "end_turn"}})

      # CLI approve goes through NanoPlanner.approve
      {:ok, result} =
        Plan.approve(db_plan.id,
          nano_planner_module: NanoPlanner,
          session: :fake_session,
          kiro_session_module: FakeKiroSession,
          project_dir: dir
        )

      assert result.kind == :plan_approved
      assert result.status == "approved"

      # Verify the execution prompt was sent through KiroSession
      calls = Process.get(:fake_kiro_prompt_calls, [])
      assert length(calls) == 1

      {prompt_text, _opts} = hd(calls)
      assert prompt_text == "Execute the approved dashboard widget plan phase by phase."
    end

    test "CLI revise delegates to NanoPlanner.revise and supersedes", %{
      project_dir: dir
    } do
      alias KiroCockpit.CLI.Commands.Plan

      Process.put(:fake_kiro_prompt_result, {:ok, valid_plan_map()})

      assert {:ok, old_plan} =
               NanoPlanner.plan(:fake_session, "Build dashboard widget", default_plan_opts(dir))

      revised_map =
        Map.merge(valid_plan_map(), %{
          "execution_prompt" => "Execute revised plan."
        })

      Process.put(:fake_kiro_prompt_result, {:ok, revised_map})

      {:ok, result} =
        Plan.revise(old_plan.id, "Add tests",
          nano_planner_module: NanoPlanner,
          session: :fake_session,
          kiro_session_module: FakeKiroSession,
          project_dir: dir
        )

      assert result.kind == :plan_revised
      assert result.status == "draft"
      assert result.previous_plan_id == old_plan.id

      # Old plan is superseded
      refreshed_old = Plans.get_plan(old_plan.id)
      assert refreshed_old.status == "superseded"
    end
  end

  # ── Approval routing: injected planner is not bypassed ──────────────

  describe "approval routing does not bypass injected planner" do
    setup [:setup_project_dir]

    test "NanoPlanner.approve sends prompt even when called via indirect paths", %{
      project_dir: dir
    } do
      Process.put(:fake_kiro_prompt_result, {:ok, valid_plan_map()})
      Process.put(:fake_kiro_prompt_calls, [])

      assert {:ok, plan} =
               NanoPlanner.plan(:fake_session, "Build dashboard widget", default_plan_opts(dir))

      Process.put(:fake_kiro_prompt_calls, [])
      Process.put(:fake_kiro_prompt_result, {:ok, %{"routed" => true}})

      assert {:ok, %{plan: approved, prompt_result: result}} =
               NanoPlanner.approve(:fake_session, plan.id,
                 kiro_session_module: FakeKiroSession,
                 project_dir: dir
               )

      # Critical: prompt/3 was actually called
      calls = Process.get(:fake_kiro_prompt_calls, [])
      assert length(calls) == 1

      # Contrast: Plans.approve_plan/1 does NOT send a prompt
      # (This is verified by the LiveView routing test below)
      assert approved.status == "approved"
      assert result == %{"routed" => true}
    end

    test "Plans.approve_plan/1 does NOT send execution_prompt (DB-only)", %{
      project_dir: dir
    } do
      Process.put(:fake_kiro_prompt_result, {:ok, valid_plan_map()})
      Process.put(:fake_kiro_prompt_calls, [])

      assert {:ok, plan} =
               NanoPlanner.plan(:fake_session, "Build dashboard widget", default_plan_opts(dir))

      Process.put(:fake_kiro_prompt_calls, [])

      # Direct Plans.approve_plan does NOT route through KiroSession
      assert {:ok, _approved} = Plans.approve_plan(plan.id)

      # No prompt calls were made — this is DB-only
      calls = Process.get(:fake_kiro_prompt_calls, [])
      assert calls == []
    end
  end
end
