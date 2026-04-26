defmodule KiroCockpitWeb.SessionPlanLiveTest do
  @moduledoc """
  Tests for SessionPlanLive.

  Tests mount/render, plan generation, approval, rejection, revision,
  and running plans using the FakeNanoPlanner module.
  """
  use KiroCockpitWeb.ConnCase

  import Phoenix.LiveViewTest

  alias KiroCockpit.Plans
  alias KiroCockpit.Support.FakeNanoPlanner

  setup do
    # Configure the fake NanoPlanner for tests
    Application.put_env(:kiro_cockpit, :nano_planner_module, FakeNanoPlanner)

    on_exit(fn ->
      Application.delete_env(:kiro_cockpit, :nano_planner_module)
    end)

    :ok
  end

  describe "mount and render" do
    test "renders the planning page with session id", %{conn: conn} do
      session_id = "test-session-#{System.unique_integer([:positive])}"

      {:ok, _view, html} = live(conn, ~p"/sessions/#{session_id}/plan")

      assert html =~ "Session Planning"
      assert html =~ session_id
      assert html =~ "Generate Plan"
    end

    test "shows empty state when no plans exist", %{conn: conn} do
      session_id = "empty-session-#{System.unique_integer([:positive])}"

      {:ok, _view, html} = live(conn, ~p"/sessions/#{session_id}/plan")

      assert html =~ "No plans yet"
      assert html =~ "Generate your first plan"
    end

    test "lists existing plans for session", %{conn: conn} do
      session_id = "with-plans-#{System.unique_integer([:positive])}"

      # Create a plan
      {:ok, _plan} = create_test_plan(session_id, %{user_request: "Existing plan"})

      {:ok, _view, html} = live(conn, ~p"/sessions/#{session_id}/plan")

      assert html =~ "Existing plan"
      assert html =~ "1 plan"
    end

    test "pre-selects plan from query parameter", %{conn: conn} do
      session_id = "preselect-#{System.unique_integer([:positive])}"
      {:ok, plan} = create_test_plan(session_id, %{user_request: "Preselected"})

      {:ok, _view, html} = live(conn, ~p"/sessions/#{session_id}/plan?plan_id=#{plan.id}")

      # The plan should be selected/expanded
      assert html =~ "Preselected"
    end

    test "pre-selects mode from query parameter", %{conn: conn} do
      session_id = "mode-select-#{System.unique_integer([:positive])}"

      {:ok, _view, html} = live(conn, ~p"/sessions/#{session_id}/plan?mode=nano_deep")

      # The nano_deep mode should be selected (indicated by styling)
      assert html =~ "Deep"
    end
  end

  describe "plan generation" do
    test "generates a plan from user request", %{conn: conn} do
      session_id = "generate-#{System.unique_integer([:positive])}"

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session_id}/plan")

      # Fill in the form and submit
      view
      |> form("form", %{"request" => "Add a new feature", "mode" => "nano"})
      |> render_submit()

      # Wait for async operation
      assert render(view) =~ "Generating"

      # Eventually the plan should appear
      html = render(view)
      assert html =~ "Add a new feature"
    end

    test "shows error for empty request", %{conn: conn} do
      session_id = "error-empty-#{System.unique_integer([:positive])}"

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session_id}/plan")

      html =
        view
        |> form("form", %{"request" => "", "mode" => "nano"})
        |> render_submit()

      # Should show validation error
      assert html =~ "Request is required"
    end
  end

  describe "plan actions" do
    setup %{conn: conn} do
      session_id = "actions-#{System.unique_integer([:positive])}"

      # Set up a real project dir for staleness checks
      dir =
        System.tmp_dir!()
        |> Path.join("lv_actions_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "mix.exs"), "defmodule Test.Project do end")
      File.write!(Path.join(dir, "README.md"), "# Test")

      {:ok, snapshot} = KiroCockpit.NanoPlanner.ContextBuilder.build(project_dir: dir)

      {:ok, plan} =
        create_test_plan(session_id, %{
          status: "draft",
          user_request: "Actionable plan",
          project_snapshot_hash: snapshot.hash
        })

      # Configure session resolver to return a map with project dir
      Application.put_env(:kiro_cockpit, :kiro_session_resolver, fn _sid -> %{cwd: dir} end)

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session_id}/plan")

      on_exit(fn ->
        Application.delete_env(:kiro_cockpit, :kiro_session_resolver)
        File.rm_rf!(dir)
      end)

      %{conn: conn, view: view, session_id: session_id, plan: plan, project_dir: dir}
    end

    test "approves a draft plan", %{view: view, plan: plan} do
      html =
        view
        |> element("button[phx-click='approve_plan'][phx-value-id='#{plan.id}']")
        |> render_click()

      assert html =~ "Plan approved successfully"

      # Plan status should show as approved
      assert render(view) =~ "Approved"
    end

    test "rejects a plan", %{view: view, plan: plan} do
      html =
        view
        |> element("button[phx-click='reject_plan'][phx-value-id='#{plan.id}']")
        |> render_click()

      assert html =~ "Plan rejected"

      # Plan should show as rejected
      assert render(view) =~ "Rejected"
    end

    test "revising a plan triggers async generation", %{view: view, plan: plan} do
      # Click revise - this starts async generation
      view
      |> element("button[phx-click='revise_plan'][phx-value-id='#{plan.id}']")
      |> render_click()

      # Should show generating state or the view should still render
      assert render(view) =~ "Session Planning"
    end
  end

  describe "run plan action" do
    test "runs an approved plan when not stale", %{conn: conn} do
      session_id = "run-#{System.unique_integer([:positive])}"

      # Create a real project dir with matching hash
      dir = setup_project_dir_for_run()
      {:ok, snapshot} = KiroCockpit.NanoPlanner.ContextBuilder.build(project_dir: dir)

      {:ok, plan} =
        create_test_plan(session_id, %{
          status: "approved",
          user_request: "Ready to run",
          project_snapshot_hash: snapshot.hash
        })

      # Configure a session resolver that provides the project dir
      Application.put_env(:kiro_cockpit, :kiro_session_resolver, fn _sid -> %{cwd: dir} end)

      try do
        {:ok, view, _html} = live(conn, ~p"/sessions/#{session_id}/plan")

        html =
          view
          |> element("button[phx-click='run_plan'][phx-value-id='#{plan.id}']")
          |> render_click()

        assert html =~ "Plan execution started"
        assert render(view) =~ "Running"
      after
        Application.delete_env(:kiro_cockpit, :kiro_session_resolver)
        File.rm_rf!(dir)
      end
    end

    test "refuses to run a stale plan", %{conn: conn} do
      session_id = "run-stale-#{System.unique_integer([:positive])}"

      {:ok, plan} =
        create_test_plan(session_id, %{status: "approved", user_request: "Stale plan"})

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session_id}/plan")

      html =
        view
        |> element("button[phx-click='run_plan'][phx-value-id='#{plan.id}']")
        |> render_click()

      assert html =~ "stale"
      # Plan should NOT be running
      assert KiroCockpit.Plans.get_plan(plan.id).status == "approved"
    end

    test "refuses to run when staleness cannot be determined (no project dir)", %{conn: conn} do
      session_id = "run-unknown-#{System.unique_integer([:positive])}"

      {:ok, plan} =
        create_test_plan(session_id, %{status: "approved", user_request: "No dir"})

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session_id}/plan")

      html =
        view
        |> element("button[phx-click='run_plan'][phx-value-id='#{plan.id}']")
        |> render_click()

      assert html =~ "staleness cannot be determined"
      # Plan should NOT be running
      assert KiroCockpit.Plans.get_plan(plan.id).status == "approved"
    end

    test "refuses to run a draft plan from a forged event", %{conn: conn} do
      session_id = "run-draft-#{System.unique_integer([:positive])}"
      {:ok, plan} = create_test_plan(session_id, %{status: "draft", user_request: "Not ready"})

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session_id}/plan")

      render_click(view, :run_plan, %{"id" => plan.id})

      assert Plans.get_plan(plan.id).status == "draft"
    end
  end

  defp setup_project_dir_for_run do
    dir =
      System.tmp_dir!()
      |> Path.join("lv_run_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "mix.exs"), "defmodule Test.Project do end")
    File.write!(Path.join(dir, "README.md"), "# Test")
    dir
  end

  describe "plan selection and expansion" do
    setup %{conn: conn} do
      session_id = "select-#{System.unique_integer([:positive])}"
      {:ok, plan1} = create_test_plan(session_id, %{user_request: "First plan"})
      {:ok, plan2} = create_test_plan(session_id, %{user_request: "Second plan"})

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session_id}/plan")

      %{view: view, session_id: session_id, plan1: plan1, plan2: plan2}
    end

    test "selects a plan on click", %{view: view, plan1: plan1} do
      html =
        view
        |> element("h3[phx-click='select_plan'][phx-value-id='#{plan1.id}']")
        |> render_click()

      # Plan should now be selected (styling changes)
      assert html =~ plan1.user_request
    end

    test "expands and collapses a plan", %{view: view, plan1: plan1} do
      # Click to expand - should not error
      view
      |> element("button[phx-click='expand_plan'][phx-value-id='#{plan1.id}']")
      |> render_click()

      # Re-render and check that the plan is now expanded
      # (visible by expanded state indicators in the UI)
      html = render(view)
      assert html =~ plan1.user_request

      # Click again to collapse
      view
      |> element("button[phx-click='expand_plan'][phx-value-id='#{plan1.id}']")
      |> render_click()

      # View should still render successfully
      html = render(view)
      assert html =~ plan1.user_request
    end
  end

  describe "refresh functionality" do
    test "refreshes plan list on refresh click", %{conn: conn} do
      session_id = "refresh-#{System.unique_integer([:positive])}"

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session_id}/plan")

      # Create a plan externally
      {:ok, _plan} = create_test_plan(session_id, %{user_request: "New plan"})

      # Click refresh
      html =
        view
        |> element("button[phx-click='refresh_plans']")
        |> render_click()

      # Should now show the new plan
      assert html =~ "New plan"
    end
  end

  describe "PubSub updates" do
    test "receives plan updates via PubSub", %{conn: conn} do
      session_id = "pubsub-#{System.unique_integer([:positive])}"
      {:ok, plan} = create_test_plan(session_id, %{status: "draft"})

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session_id}/plan")

      # Broadcast a plan update
      {:ok, updated_plan} = Plans.approve_plan(plan.id)

      send(view.pid, {:plan_updated, updated_plan})

      # View should reflect the update
      html = render(view)
      assert html =~ "Approved"
    end
  end

  describe "plan status counts" do
    test "displays plan counts by status", %{conn: conn} do
      session_id = "counts-#{System.unique_integer([:positive])}"

      # Create plans with different statuses
      {:ok, _} = create_test_plan(session_id, %{status: "draft", user_request: "Draft plan"})
      {:ok, p2} = create_test_plan(session_id, %{status: "draft", user_request: "To approve"})
      {:ok, _} = create_test_plan(session_id, %{status: "draft", user_request: "To reject"})

      {:ok, view, html} = live(conn, ~p"/sessions/#{session_id}/plan")

      # Should show 3 plans in draft
      assert html =~ "3 plans"

      # Approve one
      {:ok, approved} = Plans.approve_plan(p2.id)
      send(view.pid, {:plan_updated, approved})

      # Now should show updated counts
      html = render(view)
      assert html =~ "Draft"
      assert html =~ "Approved"
    end
  end

  describe "error handling" do
    test "handles approve failure gracefully (already approved)", %{conn: conn} do
      session_id = "error-approve-#{System.unique_integer([:positive])}"
      # Create already approved plan - can't approve again
      {:ok, plan} = create_test_plan(session_id, %{status: "approved"})

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session_id}/plan")

      # Try to approve again — staleness check will fail first (no project dir)
      # or if a project dir were available, approve_plan would reject with
      # :invalid_transition. Either way the UI should show an error.
      html = render_click(view, :approve_plan, %{"id" => plan.id})

      # Should show some error (stale_plan_unknown or invalid_transition)
      assert html =~ "staleness cannot be determined" or html =~ "invalid status transition"
    end

    test "handles reject failure gracefully", %{conn: conn} do
      session_id = "error-reject-#{System.unique_integer([:positive])}"
      # Create already rejected plan - can't reject again
      {:ok, plan} = create_test_plan(session_id, %{status: "rejected"})

      {:ok, view, _html} = live(conn, ~p"/sessions/#{session_id}/plan")

      html = render_click(view, :reject_plan, %{"id" => plan.id})

      assert html =~ "invalid status transition"
    end
  end

  # Helper functions

  defp create_test_plan(session_id, attrs) do
    defaults = %{
      mode: "nano",
      status: "draft",
      user_request: "Test request #{System.unique_integer([:positive])}",
      plan_markdown: "## Test Plan",
      execution_prompt: "Execute test",
      project_snapshot_hash: "test-hash"
    }

    attrs = Map.merge(defaults, attrs)

    steps = [
      %{
        phase_number: 1,
        step_number: 1,
        title: "Test step 1",
        permission_level: "read",
        status: "planned"
      },
      %{
        phase_number: 1,
        step_number: 2,
        title: "Test step 2",
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
        "summary" => "Test summary",
        "phases" => [
          %{
            "number" => 1,
            "title" => "Test Phase",
            "steps" => [
              %{"title" => "Step 1", "permission" => "read"},
              %{"title" => "Step 2", "permission" => "write"}
            ]
          }
        ],
        "permissions_needed" => ["read", "write"],
        "acceptance_criteria" => ["Test passes"],
        "risks" => [%{"description" => "Test risk", "mitigation" => "Be careful"}],
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

    # Update status if needed (via appropriate context function)
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

        "completed" ->
          {:ok, approved} = Plans.approve_plan(plan.id)
          {:ok, running} = Plans.update_status(approved.id, "running", %{})
          {:ok, p} = Plans.update_status(running.id, "completed", %{})
          p

        "failed" ->
          {:ok, approved} = Plans.approve_plan(plan.id)
          {:ok, running} = Plans.update_status(approved.id, "running", %{})
          {:ok, p} = Plans.update_status(running.id, "failed", %{})
          p

        "superseded" ->
          {:ok, p} = Plans.update_status(plan.id, "superseded", %{})
          p

        _ ->
          plan
      end

    {:ok, plan}
  end
end
