defmodule KiroCockpitWeb.Components.PlanCardTest do
  @moduledoc """
  Tests for the PlanCard component.
  """
  use KiroCockpit.DataCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import KiroCockpitWeb.Components.Planning.PlanCard

  alias KiroCockpit.Plans

  describe "plan_card/1" do
    setup do
      plan =
        create_test_plan(%{
          status: "draft",
          mode: "nano",
          user_request: "Test request",
          plan_markdown: "## Test summary"
        })

      %{plan: plan}
    end

    test "renders plan with basic information", %{plan: plan} do
      assigns = %{plan: plan}

      html =
        rendered_to_string(~H"""
        <.plan_card plan={@plan} />
        """)

      assert html =~ "Test request"
      assert html =~ "Draft"
      assert html =~ "Nano"
    end

    test "shows correct status badge color for draft", %{plan: plan} do
      assigns = %{plan: plan}

      html =
        rendered_to_string(~H"""
        <.plan_card plan={@plan} />
        """)

      assert html =~ "bg-slate-100"
      assert html =~ "text-slate-800"
    end

    test "shows approve button for draft plans", %{plan: plan} do
      assigns = %{plan: plan}

      html =
        rendered_to_string(~H"""
        <.plan_card plan={@plan} on_approve="approve_plan" />
        """)

      assert html =~ "Approve"
      assert html =~ "phx-click"
      assert html =~ "approve_plan"
    end

    test "does not show approve button for approved plans" do
      plan =
        create_test_plan(%{
          status: "approved",
          mode: "nano",
          user_request: "Approved test"
        })

      assigns = %{plan: plan}

      html =
        rendered_to_string(~H"""
        <.plan_card plan={@plan} on_approve="approve_plan" />
        """)

      refute html =~ ">Approve<"
    end

    test "shows run button for approved plans" do
      plan =
        create_test_plan(%{
          status: "approved",
          mode: "nano",
          user_request: "Ready to run"
        })

      assigns = %{plan: plan}

      html =
        rendered_to_string(~H"""
        <.plan_card plan={@plan} on_run="run_plan" />
        """)

      assert html =~ "Run"
      assert html =~ "run_plan"
    end

    test "shows reject button for draft and approved plans", %{plan: plan} do
      assigns = %{plan: plan}

      html =
        rendered_to_string(~H"""
        <.plan_card plan={@plan} on_reject="reject_plan" />
        """)

      assert html =~ "Reject"
      assert html =~ "reject_plan"
    end

    test "shows revise button when handler provided", %{plan: plan} do
      assigns = %{plan: plan}

      html =
        rendered_to_string(~H"""
        <.plan_card plan={@plan} on_revise="revise_plan" />
        """)

      assert html =~ "Revise"
      assert html =~ "revise_plan"
    end

    test "renders in expanded state when expanded=true", %{plan: plan} do
      plan = Plans.get_plan(plan.id)
      assigns = %{plan: plan}

      html =
        rendered_to_string(~H"""
        <.plan_card plan={@plan} expanded={true} />
        """)

      # Should show phases and steps when expanded
      assert html =~ "Phases & Steps"
    end

    test "renders raw model output when expanded and present", %{plan: plan} do
      plan = %{Plans.get_plan(plan.id) | raw_model_output: %{"foo" => "bar"}}
      assigns = %{plan: plan}

      html =
        rendered_to_string(~H"""
        <.plan_card plan={@plan} expanded={true} />
        """)

      assert html =~ "Raw Model Output"
      assert html =~ "foo"
      assert html =~ "bar"
    end

    test "does not render raw model output section for empty maps", %{plan: plan} do
      plan = %{Plans.get_plan(plan.id) | raw_model_output: %{}}
      assigns = %{plan: plan}

      html =
        rendered_to_string(~H"""
        <.plan_card plan={@plan} expanded={true} />
        """)

      refute html =~ "Raw Model Output"
    end

    test "renders in collapsed state when expanded=false", %{plan: plan} do
      assigns = %{plan: plan}

      html =
        rendered_to_string(~H"""
        <.plan_card plan={@plan} expanded={false} />
        """)

      refute html =~ "Phases & Steps"
    end

    test "shows selected state styling when selected=true", %{plan: plan} do
      assigns = %{plan: plan}

      html =
        rendered_to_string(~H"""
        <.plan_card plan={@plan} selected={true} />
        """)

      assert html =~ "ring-2"
      assert html =~ "ring-blue-500"
    end

    test "shows permission badges from raw_model_output", %{plan: plan} do
      plan = update_plan_with_permissions(plan, [:read, :write, :shell_read])
      assigns = %{plan: plan}

      html =
        rendered_to_string(~H"""
        <.plan_card plan={@plan} />
        """)

      assert html =~ "Permissions:"
      # Check for permission badge text
      assert html =~ "read"
      assert html =~ "write"
      assert html =~ "shell read"
    end

    test "renders different mode badges correctly" do
      nano_plan = create_test_plan(%{mode: "nano", user_request: "Nano plan"})
      deep_plan = create_test_plan(%{mode: "nano_deep", user_request: "Deep plan"})
      fix_plan = create_test_plan(%{mode: "nano_fix", user_request: "Fix plan"})

      assigns = %{plan: nano_plan}

      nano_html =
        rendered_to_string(~H"""
        <.plan_card plan={@plan} />
        """)

      assigns = %{plan: deep_plan}

      deep_html =
        rendered_to_string(~H"""
        <.plan_card plan={@plan} />
        """)

      assigns = %{plan: fix_plan}

      fix_html =
        rendered_to_string(~H"""
        <.plan_card plan={@plan} />
        """)

      assert nano_html =~ "Nano"
      assert deep_html =~ "Nano Deep"
      assert fix_html =~ "Nano Fix"
    end

    test "truncates long user requests" do
      long_request = String.duplicate("a", 100)
      plan = create_test_plan(%{user_request: long_request})
      assigns = %{plan: plan}

      html =
        rendered_to_string(~H"""
        <.plan_card plan={@plan} />
        """)

      # Should be truncated with ellipsis
      assert html =~ "..."
    end

    test "formats timestamp correctly" do
      plan = create_test_plan(%{user_request: "With timestamp"})
      assigns = %{plan: plan}

      html =
        rendered_to_string(~H"""
        <.plan_card plan={@plan} />
        """)

      # Should have some timestamp content (exact format depends on current time)
      # Year part of timestamp
      assert html =~ "202"
    end
  end

  describe "plan_card status variants" do
    test "renders approved status with correct colors" do
      plan = create_test_plan(%{status: "approved"})
      assigns = %{plan: plan}

      html =
        rendered_to_string(~H"""
        <.plan_card plan={@plan} />
        """)

      assert html =~ "bg-emerald-100"
      assert html =~ "text-emerald-800"
      assert html =~ "Approved"
    end

    test "renders running status with correct colors" do
      plan = create_test_plan(%{status: "running"})
      assigns = %{plan: plan}

      html =
        rendered_to_string(~H"""
        <.plan_card plan={@plan} />
        """)

      assert html =~ "bg-blue-100"
      assert html =~ "text-blue-800"
      assert html =~ "Running"
    end

    test "renders completed status with correct colors" do
      plan = create_test_plan(%{status: "completed"})
      assigns = %{plan: plan}

      html =
        rendered_to_string(~H"""
        <.plan_card plan={@plan} />
        """)

      assert html =~ "bg-green-100"
      assert html =~ "text-green-800"
      assert html =~ "Completed"
    end

    test "renders rejected status with correct colors" do
      plan = create_test_plan(%{status: "rejected"})
      assigns = %{plan: plan}

      html =
        rendered_to_string(~H"""
        <.plan_card plan={@plan} />
        """)

      assert html =~ "bg-rose-100"
      assert html =~ "text-rose-800"
      assert html =~ "Rejected"
    end

    test "renders failed status with correct colors" do
      plan = create_test_plan(%{status: "failed"})
      assigns = %{plan: plan}

      html =
        rendered_to_string(~H"""
        <.plan_card plan={@plan} />
        """)

      assert html =~ "bg-red-100"
      assert html =~ "text-red-800"
      assert html =~ "Failed"
    end

    test "renders superseded status with correct colors" do
      plan = create_test_plan(%{status: "superseded"})
      assigns = %{plan: plan}

      html =
        rendered_to_string(~H"""
        <.plan_card plan={@plan} />
        """)

      assert html =~ "bg-gray-100"
      assert html =~ "text-gray-800"
      assert html =~ "Superseded"
    end
  end

  # Helper functions

  defp create_test_plan(attrs) do
    session_id = "test-session-#{System.unique_integer([:positive])}"

    defaults = %{
      session_id: session_id,
      mode: "nano",
      status: "draft",
      user_request: "Default test request",
      plan_markdown: "## Test Plan",
      execution_prompt: "Execute test",
      project_snapshot_hash: "test-hash"
    }

    attrs = Map.merge(defaults, attrs)

    steps = [
      %{
        phase_number: 1,
        step_number: 1,
        title: "Test step",
        permission_level: "read",
        status: "planned"
      }
    ]

    {:ok, plan} =
      Plans.create_plan(
        attrs.session_id,
        attrs.user_request,
        attrs.mode,
        steps,
        Map.take(attrs, [:plan_markdown, :execution_prompt, :project_snapshot_hash])
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

    plan
  end

  defp update_plan_with_permissions(plan, permissions) do
    raw_output = %{
      "permissions_needed" => Enum.map(permissions, &to_string/1),
      "acceptance_criteria" => ["Test criterion"],
      "risks" => []
    }

    # Reload with preloaded associations and update raw_model_output
    Plans.get_plan(plan.id)
    |> then(fn p ->
      %{p | raw_model_output: raw_output}
    end)
  end
end
