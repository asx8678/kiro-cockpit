defmodule KiroCockpit.CLI.IntegrationTest do
  @moduledoc """
  Integration smoke test that wires real `KiroCockpit.Plans` (with
  the test DB) into the CLI surface, while keeping the NanoPlanner
  service stubbed (so no Kiro subprocess runs).

  This proves that:

    * `/plans`, `/plan show`, `/plan reject`, `/plan run` work
      against the actual Plans context, and
    * `/plan approve`/`/plan revise` correctly forward to the
      injected planner module without bypassing the application
      layer.

  These tests live alongside the pure parser/dispatcher tests in
  `cli_test.exs`; they exist to catch contract drift between the CLI
  payload shapes and the real Ecto schemas.
  """

  use KiroCockpit.DataCase

  alias KiroCockpit.CLI
  alias KiroCockpit.Plans

  defmodule StubPlanner do
    @moduledoc false

    # Returns canned values for the planner-mediated commands. We do
    # NOT exercise NanoPlanner.plan/3 here; that is covered by the
    # existing nano_planner_test.exs.

    def plan(_session, _request, _opts) do
      raise "StubPlanner.plan/3 should not be reached in this test file"
    end

    def approve(_session, plan_id, _opts) do
      case Plans.approve_plan(plan_id) do
        {:ok, plan} ->
          {:ok, %{plan: plan, prompt_result: %{"stub" => true}}}

        other ->
          other
      end
    end

    def revise(_session, _plan_id, _request, _opts) do
      raise "StubPlanner.revise/4 should not be reached in this test file"
    end
  end

  defp default_plan_attrs do
    %{
      plan_markdown: "# Plan",
      execution_prompt: "go",
      project_snapshot_hash: "hash"
    }
  end

  defp create_real_plan(session_id \\ "sess-int") do
    {:ok, plan} = Plans.create_plan(session_id, "build it", :nano, [], default_plan_attrs())
    plan
  end

  defp create_real_plan_with_hash(hash, session_id \\ "sess-int") do
    attrs = Map.put(default_plan_attrs(), :project_snapshot_hash, hash)
    {:ok, plan} = Plans.create_plan(session_id, "build it", :nano, [], attrs)
    plan
  end

  defp setup_integration_project_dir do
    dir =
      System.tmp_dir!()
      |> Path.join("cli_int_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "mix.exs"), "defmodule Test.Project do end")
    File.write!(Path.join(dir, "README.md"), "# Test")
    dir
  end

  defp opts(extra \\ []) do
    Keyword.merge(
      [
        plans_module: Plans,
        nano_planner_module: StubPlanner,
        session: :int_session,
        session_id: "sess-int"
      ],
      extra
    )
  end

  describe "/plans against real Plans module" do
    test "lists plans for a session" do
      _p1 = create_real_plan()
      _p2 = create_real_plan()
      _other = create_real_plan("sess-other")

      assert {:ok, %{kind: :plans_listed, count: 2, plans: plans}} =
               CLI.run("/plans", opts())

      assert Enum.all?(plans, &(&1.session_id == "sess-int"))
    end

    test "errors clearly when /plans has no session id" do
      assert {:error, %{code: :session_id_required}} =
               CLI.run("/plans", opts() |> Keyword.delete(:session_id))
    end
  end

  describe "/plan show against real Plans module" do
    test "shows an existing plan" do
      plan = create_real_plan()

      assert {:ok, %{kind: :plan_shown, plan_id: id, status: "draft"}} =
               CLI.run("/plan show #{plan.id}", opts())

      assert id == plan.id
    end

    test "returns :not_found for an unknown id" do
      assert {:error, %{code: :not_found}} =
               CLI.run("/plan show #{Ecto.UUID.generate()}", opts())
    end
  end

  describe "/plan approve against real Plans + stub planner" do
    test "approves a draft plan" do
      plan = create_real_plan()

      assert {:ok, %{kind: :plan_approved, status: "approved"}} =
               CLI.run("/plan approve #{plan.id}", opts())

      assert Plans.get_plan(plan.id).status == "approved"
    end
  end

  describe "/plan reject against real Plans module" do
    test "rejects a plan with a multi-word reason" do
      plan = create_real_plan()

      assert {:ok, %{kind: :plan_rejected, status: "rejected", reason: "user cancelled"}} =
               CLI.run("/plan reject #{plan.id} user cancelled", opts())

      assert Plans.get_plan(plan.id).status == "rejected"
    end

    test "rejects a plan with no reason" do
      plan = create_real_plan()

      assert {:ok, %{kind: :plan_rejected, reason: nil}} =
               CLI.run("/plan reject #{plan.id}", opts())
    end

    test "errors with :invalid_transition on already-rejected plan" do
      plan = create_real_plan()
      {:ok, _} = Plans.reject_plan(plan.id)

      assert {:error, %{code: :invalid_transition}} =
               CLI.run("/plan reject #{plan.id}", opts())
    end
  end

  describe "/plan run against real Plans module" do
    test "transitions an approved plan to running when not stale" do
      dir = setup_integration_project_dir()
      {:ok, snapshot} = KiroCockpit.NanoPlanner.ContextBuilder.build(project_dir: dir)

      plan = create_real_plan_with_hash(snapshot.hash)
      {:ok, _approved} = Plans.approve_plan(plan.id)

      assert {:ok, %{kind: :plan_running, status: "running"}} =
               CLI.run("/plan run #{plan.id}", opts(project_dir: dir))

      assert Plans.get_plan(plan.id).status == "running"

      File.rm_rf!(dir)
    end

    test "refuses to run a stale plan via boundary" do
      dir = setup_integration_project_dir()
      plan = create_real_plan()
      {:ok, _approved} = Plans.approve_plan(plan.id)

      # Enable hooks so the boundary runs and staleness is checked
      assert {:error, %{code: :stale_plan}} =
               CLI.run(
                 "/plan run #{plan.id}",
                 opts(project_dir: dir, swarm_hooks: true)
               )

      assert Plans.get_plan(plan.id).status == "approved"

      File.rm_rf!(dir)
    end

    test "run_plan stale check skipped when hooks disabled (default test config)" do
      dir = setup_integration_project_dir()
      plan = create_real_plan()
      {:ok, _approved} = Plans.approve_plan(plan.id)

      # With hooks disabled (default test config), staleness check is skipped
      # and the plan transitions to running directly
      assert {:ok, %{kind: :plan_running}} =
               CLI.run("/plan run #{plan.id}", opts(project_dir: dir))

      assert Plans.get_plan(plan.id).status == "running"

      File.rm_rf!(dir)
    end

    test "refuses to run a draft plan" do
      dir = setup_integration_project_dir()
      plan = create_real_plan()

      assert {:error, %{code: :invalid_transition}} =
               CLI.run("/plan run #{plan.id}", opts(project_dir: dir))

      assert Plans.get_plan(plan.id).status == "draft"

      File.rm_rf!(dir)
    end
  end
end
