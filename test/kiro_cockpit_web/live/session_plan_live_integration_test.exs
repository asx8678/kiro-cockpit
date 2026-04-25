defmodule KiroCockpitWeb.SessionPlanLiveIntegrationTest do
  @moduledoc """
  Integration tests for SessionPlanLive with FakeNanoPlanner.

  Proves:
    - LiveView mount/render with fake planner, showing phases/permissions/card details
    - LiveView generate creates a plan via the injected planner
    - LiveView approve routes through the injectable NanoPlanner module
      (not Plans.approve_plan/1 directly), sending execution_prompt
    - LiveView revise creates a new plan version and supersedes old plan
    - Approval routing for UI path does not bypass NanoPlanner when
      an injected planner is configured
  """

  use KiroCockpitWeb.ConnCase

  import Phoenix.LiveViewTest

  alias KiroCockpit.Plans
  alias KiroCockpit.Support.FakeNanoPlanner

  # ── Recording wrapper around FakeNanoPlanner ────────────────────────
  # Uses an Agent + Application env for cross-process call recording.
  # LiveView runs in its own process; Process dictionary is isolated.

  defmodule RecordingFakePlanner do
    @moduledoc false

    # Wraps FakeNanoPlanner and records approve/revise calls to an Agent
    # so the test process can inspect them regardless of which process
    # invoked the planner. The Agent name is read from Application env.

    def approve(session, plan_id, opts) do
      record_call(:approve, {plan_id, opts})
      FakeNanoPlanner.approve(session, plan_id, opts)
    end

    def plan(session, request, opts) do
      FakeNanoPlanner.plan(session, request, opts)
    end

    def revise(session, plan_id, request, opts) do
      record_call(:revise, {plan_id, request, opts})
      FakeNanoPlanner.revise(session, plan_id, request, opts)
    end

    defp record_call(kind, entry) do
      recorder = Application.get_env(:kiro_cockpit, :planner_recorder)

      if recorder do
        Agent.update(recorder, fn state ->
          Map.update!(state, kind, fn calls -> calls ++ [entry] end)
        end)
      end
    end
  end

  # ── Stale planner that always returns :stale_plan on approve ─────────

  defmodule StalePlanner do
    @moduledoc false

    def approve(_session, _plan_id, _opts), do: {:error, :stale_plan}

    def plan(_session, _request, _opts), do: {:ok, %{id: "stub"}}

    def revise(_session, _plan_id, _request, _opts), do: {:ok, %{id: "stub"}}
  end

  # ── Failing planner that always errors ──────────────────────────────

  defmodule FailingPlanner do
    @moduledoc false

    def revise(_session, _plan_id, _request, _opts), do: {:error, :model_down}

    def plan(_session, _request, _opts), do: {:error, :model_down}

    def approve(_session, _plan_id, _opts), do: {:error, :model_down}
  end

  # ── Setup ────────────────────────────────────────────────────────────

  setup do
    recorder = :"planner_recorder_#{System.unique_integer([:positive])}"

    {:ok, _} =
      Agent.start_link(
        fn -> %{approve: [], revise: []} end,
        name: recorder
      )

    Application.put_env(:kiro_cockpit, :nano_planner_module, RecordingFakePlanner)
    Application.put_env(:kiro_cockpit, :planner_recorder, recorder)

    on_exit(fn ->
      Application.delete_env(:kiro_cockpit, :nano_planner_module)
      Application.delete_env(:kiro_cockpit, :planner_recorder)

      # Agent may already be stopped if the test DB sandbox rolled back
      try do
        Agent.stop(recorder)
      catch
        :exit, _ -> :ok
      end
    end)

    {:ok, recorder: recorder}
  end

  # Helper to create a plan with rich data for rendering assertions
  defp create_rich_plan(session_id, attrs \\ %{}) do
    defaults = %{
      mode: "nano",
      status: "draft",
      user_request: "Build dashboard widget",
      plan_markdown: "## Dashboard Widget Plan\n\nA plan to build a dashboard widget.",
      execution_prompt: "Execute the approved dashboard widget plan phase by phase.",
      project_snapshot_hash: "test-hash-#{System.unique_integer([:positive])}"
    }

    attrs = Map.merge(defaults, attrs)

    steps = [
      %{
        phase_number: 1,
        step_number: 1,
        title: "Create widget schema",
        permission_level: "write",
        status: "planned"
      },
      %{
        phase_number: 1,
        step_number: 2,
        title: "Read existing layout",
        permission_level: "read",
        status: "planned"
      },
      %{
        phase_number: 2,
        step_number: 1,
        title: "Wire widget to LiveView",
        permission_level: "write",
        status: "planned"
      }
    ]

    opts = [
      plan_markdown: attrs.plan_markdown,
      execution_prompt: attrs.execution_prompt,
      project_snapshot_hash: attrs.project_snapshot_hash,
      raw_model_output: %{
        "objective" => attrs.user_request,
        "summary" => "Add a dashboard widget",
        "phases" => [
          %{
            "number" => 1,
            "title" => "Foundation",
            "steps" => [
              %{"title" => "Create widget schema", "permission" => "write"},
              %{"title" => "Read existing layout", "permission" => "read"}
            ]
          },
          %{
            "number" => 2,
            "title" => "Integration",
            "steps" => [
              %{"title" => "Wire widget to LiveView", "permission" => "write"}
            ]
          }
        ],
        "permissions_needed" => ["read", "write"],
        "acceptance_criteria" => ["Widget renders", "Schema persists"],
        "risks" => [
          %{"description" => "Layout conflicts", "mitigation" => "Use scoped CSS"}
        ],
        "execution_prompt" => attrs.execution_prompt
      }
    ]

    {:ok, plan} =
      Plans.create_plan(
        session_id,
        attrs.user_request,
        attrs.mode,
        steps,
        opts
      )

    # Transition status if needed
    plan =
      case attrs.status do
        "draft" ->
          plan

        "approved" ->
          {:ok, p} = Plans.approve_plan(plan.id)
          p

        "rejected" ->
          {:ok, p} = Plans.reject_plan(plan.id, "test rejection")
          p

        "running" ->
          {:ok, approved} = Plans.approve_plan(plan.id)
          {:ok, p} = Plans.update_status(approved.id, "running", %{})
          p

        "superseded" ->
          {:ok, p} = Plans.update_status(plan.id, "superseded", %{})
          p

        _ ->
          plan
      end

    {:ok, plan}
  end

  defp approve_calls(recorder), do: Agent.get(recorder, & &1.approve)
  defp revise_calls(recorder), do: Agent.get(recorder, & &1.revise)

  # ── Mount / render with fake planner ────────────────────────────────

  describe "LiveView mount and render with fake planner" do
    test "mounts and renders session planning page", %{conn: conn} do
      session_id = "int-lv-#{System.unique_integer([:positive])}"

      {:ok, _view, html} = live(conn, ~p"/sessions/#{session_id}/plan")

      assert html =~ "Session Planning"
      assert html =~ session_id
      assert html =~ "Generate Plan"
    end

    test "renders existing plan with phases and permissions", %{conn: conn} do
      session_id = "int-render-#{System.unique_integer([:positive])}"
      {:ok, plan} = create_rich_plan(session_id)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session_id}/plan")

      html =
        view
        |> element("button[phx-click='expand_plan'][phx-value-id='#{plan.id}']")
        |> render_click()

      # Step titles rendered
      assert html =~ "Create widget schema"
      assert html =~ "Read existing layout"
      assert html =~ "Wire widget to LiveView"

      # Permission badges rendered
      assert html =~ "Write" or html =~ "write"
      assert html =~ "Read" or html =~ "read"
    end

    test "renders plan card with status badge", %{conn: conn} do
      session_id = "int-status-#{System.unique_integer([:positive])}"
      {:ok, _plan} = create_rich_plan(session_id, %{status: "draft"})

      {:ok, _view, html} = live(conn, ~p"/sessions/#{session_id}/plan")

      assert html =~ "Draft"
    end

    test "renders mode indicator on plan card", %{conn: conn} do
      session_id = "int-mode-#{System.unique_integer([:positive])}"
      {:ok, _plan} = create_rich_plan(session_id, %{mode: "nano_deep"})

      {:ok, _view, html} = live(conn, ~p"/sessions/#{session_id}/plan")

      assert html =~ "Deep"
    end
  end

  # ── Plan generation via fake planner ────────────────────────────────

  describe "LiveView plan generation with fake planner" do
    test "generates a plan via the injected fake planner", %{conn: conn} do
      session_id = "int-gen-#{System.unique_integer([:positive])}"

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session_id}/plan")

      view
      |> form("form", %{"request" => "Build a new feature", "mode" => "nano"})
      |> render_submit()

      # Wait for async generation
      html = render(view)

      assert html =~ "Build a new feature"
    end
  end

  # ── LiveView approve routes through injected NanoPlanner ────────────

  describe "LiveView approval routing through NanoPlanner" do
    test "approve_plan event routes through the injected planner module", %{
      conn: conn,
      recorder: recorder
    } do
      session_id = "int-approve-#{System.unique_integer([:positive])}"
      {:ok, plan} = create_rich_plan(session_id)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session_id}/plan")

      html =
        view
        |> element("button[phx-click='approve_plan'][phx-value-id='#{plan.id}']")
        |> render_click()

      assert html =~ "Plan approved successfully" or html =~ "Approved"

      # THE KEY ASSERTION: approve/3 was routed through the injected
      # RecordingFakePlanner, NOT through Plans.approve_plan/1 directly
      calls = approve_calls(recorder)
      assert length(calls) >= 1

      {called_plan_id, _opts} = hd(calls)
      assert called_plan_id == plan.id
    end

    test "approve_plan does not bypass NanoPlanner when planner is configured", %{
      conn: conn,
      recorder: recorder
    } do
      session_id = "int-no-bypass-#{System.unique_integer([:positive])}"
      {:ok, plan} = create_rich_plan(session_id)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session_id}/plan")

      view
      |> element("button[phx-click='approve_plan'][phx-value-id='#{plan.id}']")
      |> render_click()

      # Must have gone through the planner, not directly through Plans.approve_plan
      calls = approve_calls(recorder)
      assert length(calls) >= 1

      # The plan should be approved in the DB too
      refreshed = Plans.get_plan(plan.id)
      assert refreshed.status == "approved"
    end

    test "approve_plan shows stale_plan error from planner", %{conn: conn} do
      session_id = "int-stale-#{System.unique_integer([:positive])}"
      {:ok, plan} = create_rich_plan(session_id)

      # Override the planner to return :stale_plan
      Application.put_env(:kiro_cockpit, :nano_planner_module, StalePlanner)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session_id}/plan")

      html = render_click(view, :approve_plan, %{"id" => plan.id})

      assert html =~ "stale" or html =~ "Stale"

      # Plan should NOT be approved
      refreshed = Plans.get_plan(plan.id)
      assert refreshed.status == "draft"

      # Restore
      Application.put_env(:kiro_cockpit, :nano_planner_module, RecordingFakePlanner)
    end

    test "default planner without a session resolver falls back to safe DB approval", %{
      conn: conn
    } do
      session_id = "int-default-fallback-#{System.unique_integer([:positive])}"
      {:ok, plan} = create_rich_plan(session_id)

      Application.delete_env(:kiro_cockpit, :nano_planner_module)
      Application.delete_env(:kiro_cockpit, :kiro_session_resolver)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session_id}/plan")

      html =
        view
        |> element("button[phx-click='approve_plan'][phx-value-id='#{plan.id}']")
        |> render_click()

      assert html =~ "Plan approved successfully" or html =~ "Approved"
      assert Plans.get_plan(plan.id).status == "approved"

      Application.put_env(:kiro_cockpit, :nano_planner_module, RecordingFakePlanner)
    end
  end

  # ── LiveView revise creates new plan version ─────────────────────────

  describe "LiveView revise creates new plan version and supersedes" do
    test "revise event creates a new draft and supersedes the old plan", %{
      conn: conn,
      recorder: recorder
    } do
      session_id = "int-revise-#{System.unique_integer([:positive])}"
      {:ok, plan} = create_rich_plan(session_id)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session_id}/plan")

      view
      |> element("button[phx-click='revise_plan'][phx-value-id='#{plan.id}']")
      |> render_click()

      # Give async operation time to complete
      Process.sleep(200)
      _html = render(view)

      # The revise call should have gone through the planner
      calls = revise_calls(recorder)
      assert length(calls) >= 1

      {called_plan_id, _request, _opts} = hd(calls)
      assert called_plan_id == plan.id

      # Old plan should be superseded in the database
      refreshed_old = Plans.get_plan(plan.id)
      assert refreshed_old.status == "superseded"

      # A new plan should exist for this session
      all_plans = Plans.list_plans(session_id)
      draft_plans = Enum.filter(all_plans, &(&1.status == "draft"))
      assert length(draft_plans) >= 1
    end

    test "old plan remains when revise fails", %{conn: conn} do
      session_id = "int-revise-fail-#{System.unique_integer([:positive])}"

      # Override the planner to fail
      Application.put_env(:kiro_cockpit, :nano_planner_module, FailingPlanner)

      {:ok, plan} = create_rich_plan(session_id)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session_id}/plan")

      view
      |> element("button[phx-click='revise_plan'][phx-value-id='#{plan.id}']")
      |> render_click()

      # Give async operation time to complete
      Process.sleep(200)
      _html = render(view)

      # Old plan should still be draft
      refreshed = Plans.get_plan(plan.id)
      assert refreshed.status == "draft"

      # Restore
      Application.put_env(:kiro_cockpit, :nano_planner_module, RecordingFakePlanner)
    end
  end

  # ── Full pipeline: plan → approve → revise ───────────────────────────

  describe "full pipeline: plan → approve → revise" do
    test "end-to-end plan lifecycle through LiveView", %{conn: conn, recorder: recorder} do
      session_id = "int-e2e-#{System.unique_integer([:positive])}"

      # 1. Generate a plan
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session_id}/plan")

      view
      |> form("form", %{"request" => "Build analytics dashboard", "mode" => "nano"})
      |> render_submit()

      # Wait for async
      Process.sleep(200)
      html = render(view)

      assert html =~ "analytics dashboard" or html =~ "Analytics"

      # 2. Find the generated plan
      plans = Plans.list_plans(session_id)
      assert length(plans) >= 1

      draft_plan = Enum.find(plans, &(&1.status == "draft"))
      assert draft_plan != nil

      # 3. Approve it
      {:ok, view2, _html} = live(conn, ~p"/sessions/#{session_id}/plan")

      _html =
        view2
        |> element("button[phx-click='approve_plan'][phx-value-id='#{draft_plan.id}']")
        |> render_click()

      # Approval went through the planner
      a_calls = approve_calls(recorder)
      assert length(a_calls) >= 1

      # Plan is approved
      refreshed = Plans.get_plan(draft_plan.id)
      assert refreshed.status == "approved"

      # 4. Revise it
      {:ok, view3, _html} = live(conn, ~p"/sessions/#{session_id}/plan")

      view3
      |> element("button[phx-click='revise_plan'][phx-value-id='#{draft_plan.id}']")
      |> render_click()

      Process.sleep(200)
      _html = render(view3)

      # Revise went through the planner
      r_calls = revise_calls(recorder)
      assert length(r_calls) >= 1

      # Old plan is now superseded
      final = Plans.get_plan(draft_plan.id)
      assert final.status == "superseded"

      # New plan exists
      new_plans = Plans.list_plans(session_id)
      drafts = Enum.filter(new_plans, &(&1.status == "draft"))
      assert length(drafts) >= 1
    end
  end
end
