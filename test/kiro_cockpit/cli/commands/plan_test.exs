defmodule KiroCockpit.CLI.Commands.PlanTest do
  @moduledoc """
  Unit tests for `KiroCockpit.CLI.Commands.Plan`.

  Pure: both the planner and plans modules are injected via opts so
  no DB and no Kiro subprocess are involved.
  """

  use ExUnit.Case, async: true

  alias KiroCockpit.CLI.Commands.Plan

  defmodule FakePlans do
    @moduledoc false

    def get_plan(id) do
      record(:get_plan, [id])
      Process.get({:get_plan, id}, default_plan(id))
    end

    def list_plans(session_id, opts) do
      record(:list_plans, [session_id, opts])

      Process.get(:list_result, [
        default_plan("p1", session_id),
        default_plan("p2", session_id)
      ])
    end

    def reject_plan(id, reason) do
      record(:reject_plan, [id, reason])

      Process.get(
        :reject_result,
        {:ok, %{default_plan(id) | status: "rejected"}}
      )
    end

    def update_status(id, status, payload) do
      record(:update_status, [id, status, payload])

      Process.get(
        :update_result,
        {:ok, %{default_plan(id) | status: status}}
      )
    end

    def run_plan(id, opts) do
      record(:run_plan, [id, opts])

      Process.get(
        :run_plan_result,
        {:ok, %{default_plan(id) | status: "running"}}
      )
    end

    defp default_plan(id, session_id \\ "sess-1") do
      %{
        id: id,
        session_id: session_id,
        mode: "nano",
        status: "draft",
        plan_steps: [],
        plan_events: []
      }
    end

    defp record(key, args) do
      log = Process.get({:fakeplans, key}, [])
      Process.put({:fakeplans, key}, log ++ [args])
    end
  end

  defmodule FakePlanner do
    @moduledoc false

    def approve(_session, plan_id, opts) do
      record(:approve, [plan_id, opts])

      Process.get(:approve_result, {
        :ok,
        %{
          plan: %{id: plan_id, status: "approved", mode: "nano", plan_steps: [], plan_events: []},
          prompt_result: %{"ok" => true}
        }
      })
    end

    def revise(_session, plan_id, request, opts) do
      record(:revise, [plan_id, request, opts])

      Process.get(:revise_result, {
        :ok,
        %{
          id: "new-#{plan_id}",
          status: "draft",
          mode: "nano",
          user_request: request,
          plan_steps: [],
          plan_events: []
        }
      })
    end

    defp record(key, args) do
      log = Process.get({:fakeplanner, key}, [])
      Process.put({:fakeplanner, key}, log ++ [args])
    end
  end

  defp opts(extra \\ []) do
    Keyword.merge(
      [
        plans_module: FakePlans,
        nano_planner_module: FakePlanner,
        session: :s,
        session_id: "sess-1"
      ],
      extra
    )
  end

  defp planner_calls(key), do: Process.get({:fakeplanner, key}, [])
  defp plans_calls(key), do: Process.get({:fakeplans, key}, [])
  defp run_plan_calls(), do: Process.get({:fakeplans, :run_plan}, [])

  setup do
    Process.put({:fakeplans, :get_plan}, [])
    Process.put({:fakeplans, :list_plans}, [])
    Process.put({:fakeplans, :reject_plan}, [])
    Process.put({:fakeplans, :update_status}, [])
    Process.put({:fakeplans, :run_plan}, [])
    Process.put({:fakeplanner, :approve}, [])
    Process.put({:fakeplanner, :revise}, [])
    :ok
  end

  # ── list/1 ───────────────────────────────────────────────────────────

  describe "list/1" do
    test "lists plans for a session" do
      assert {:ok, %{kind: :plans_listed, count: 2, session_id: "sess-1"}} =
               Plan.list(opts())

      assert [["sess-1", []]] = plans_calls(:list_plans)
    end

    test "passes :status filter through to plans_module" do
      Plan.list(opts(status: "approved"))
      assert [["sess-1", [status: "approved"]]] = plans_calls(:list_plans)
    end

    test "errors when :session_id is missing" do
      assert {:error, %{code: :session_id_required, message: msg}} =
               Plan.list(plans_module: FakePlans)

      assert msg =~ "no `:session_id` provided"
    end
  end

  # ── show/2 ───────────────────────────────────────────────────────────

  describe "show/2" do
    test "returns :plan_shown when plan exists" do
      assert {:ok, %{kind: :plan_shown, plan_id: "abc", status: "draft", mode: "nano"}} =
               Plan.show("abc", opts())
    end

    test "returns :not_found when plan is missing" do
      Process.put({:get_plan, "missing"}, nil)

      assert {:error, %{code: :not_found, plan_id: "missing"}} =
               Plan.show("missing", opts())
    end
  end

  # ── approve/2 ────────────────────────────────────────────────────────

  describe "approve/2" do
    test "delegates to planner.approve and returns :plan_approved" do
      assert {:ok, %{kind: :plan_approved, plan_id: "abc", status: "approved"}} =
               Plan.approve("abc", opts())

      assert [["abc", _opts]] = planner_calls(:approve)
    end

    test "maps :not_found" do
      Process.put(:approve_result, {:error, :not_found})

      assert {:error, %{code: :not_found, plan_id: "abc"}} =
               Plan.approve("abc", opts())
    end

    test "maps :stale_plan" do
      Process.put(:approve_result, {:error, :stale_plan})

      assert {:error, %{code: :stale_plan, plan_id: "abc", message: msg}} =
               Plan.approve("abc", opts())

      assert msg =~ "stale"
    end

    test "maps {:swarm_blocked, reason, messages} to :stale_plan" do
      Process.put(:approve_result, {:error, {:swarm_blocked, "branch drift detected", []}})

      assert {:error, %{code: :stale_plan, plan_id: "abc", message: msg}} =
               Plan.approve("abc", opts())

      assert msg =~ "stale"
      assert msg =~ "branch drift detected"
    end

    test "maps :stale_plan_unknown" do
      Process.put(:approve_result, {:error, :stale_plan_unknown})

      assert {:error, %{code: :stale_plan_unknown, plan_id: "abc", message: msg}} =
               Plan.approve("abc", opts())

      assert msg =~ "staleness cannot be determined"
    end

    test "maps :invalid_transition" do
      Process.put(:approve_result, {:error, :invalid_transition})

      assert {:error, %{code: :invalid_transition, plan_id: "abc"}} =
               Plan.approve("abc", opts())
    end

    test "maps {:prompt_failed, plan, reason} keeping the approved plan" do
      approved_plan = %{
        id: "abc",
        status: "approved",
        mode: "nano",
        plan_steps: [],
        plan_events: []
      }

      Process.put(:approve_result, {:error, {:prompt_failed, approved_plan, :timeout}})

      assert {:error, %{code: :prompt_failed, plan: ^approved_plan, plan_id: "abc"}} =
               Plan.approve("abc", opts())
    end

    test "maps unknown errors to :approve_failed" do
      Process.put(:approve_result, {:error, :unknown_thing})

      assert {:error, %{code: :approve_failed, plan_id: "abc"}} =
               Plan.approve("abc", opts())
    end
  end

  # ── revise/3 ─────────────────────────────────────────────────────────

  describe "revise/3" do
    test "delegates to planner.revise and returns :plan_revised" do
      assert {:ok, %{kind: :plan_revised, previous_plan_id: "abc", plan_id: "new-abc"}} =
               Plan.revise("abc", "add tests", opts())

      assert [["abc", "add tests", _opts]] = planner_calls(:revise)
    end

    test "rejects empty revision request" do
      assert {:error, %{code: :missing_argument, plan_id: "abc"}} =
               Plan.revise("abc", "", opts())

      assert {:error, %{code: :missing_argument}} =
               Plan.revise("abc", "   ", opts())

      assert planner_calls(:revise) == []
    end

    test "maps :not_found" do
      Process.put(:revise_result, {:error, :not_found})

      assert {:error, %{code: :not_found, plan_id: "abc"}} =
               Plan.revise("abc", "do better", opts())
    end

    test "maps {:invalid_plan, _}" do
      Process.put(:revise_result, {:error, {:invalid_plan, "missing keys"}})

      assert {:error, %{code: :invalid_plan, plan_id: "abc", message: msg}} =
               Plan.revise("abc", "do better", opts())

      assert msg =~ "missing keys"
    end

    test "maps {:invalid_model_output, _}" do
      Process.put(:revise_result, {:error, {:invalid_model_output, "JSON parse error"}})

      assert {:error, %{code: :invalid_model_output, plan_id: "abc"}} =
               Plan.revise("abc", "do better", opts())
    end

    test "maps {:persist_failed, _}" do
      Process.put(:revise_result, {:error, {:persist_failed, :db_down}})

      assert {:error, %{code: :persist_failed, plan_id: "abc"}} =
               Plan.revise("abc", "do better", opts())
    end

    test "maps {:supersede_failed, _}" do
      Process.put(:revise_result, {:error, {:supersede_failed, :db_down}})

      assert {:error, %{code: :supersede_failed, plan_id: "abc"}} =
               Plan.revise("abc", "do better", opts())
    end

    test "maps unknown errors to :revise_failed" do
      Process.put(:revise_result, {:error, :unknown})

      assert {:error, %{code: :revise_failed, plan_id: "abc"}} =
               Plan.revise("abc", "do better", opts())
    end
  end

  # ── reject/3 ─────────────────────────────────────────────────────────

  describe "reject/3" do
    test "delegates to plans.reject_plan with reason" do
      assert {:ok, %{kind: :plan_rejected, plan_id: "abc", reason: "no thanks"}} =
               Plan.reject("abc", "no thanks", opts())

      assert [["abc", "no thanks"]] = plans_calls(:reject_plan)
    end

    test "delegates to plans.reject_plan with nil reason" do
      assert {:ok, %{kind: :plan_rejected, plan_id: "abc", reason: nil}} =
               Plan.reject("abc", nil, opts())

      assert [["abc", nil]] = plans_calls(:reject_plan)
    end

    test "message includes the reason when provided" do
      assert {:ok, %{message: msg}} = Plan.reject("abc", "duplicate", opts())
      assert msg =~ "duplicate"
    end

    test "message omits reason when nil" do
      assert {:ok, %{message: msg}} = Plan.reject("abc", nil, opts())
      refute msg =~ "reason:"
    end

    test "maps :invalid_transition" do
      Process.put(:reject_result, {:error, :invalid_transition})

      assert {:error, %{code: :invalid_transition, plan_id: "abc"}} =
               Plan.reject("abc", nil, opts())
    end

    test "maps Ecto.NoResultsError raised by reject_plan to :not_found" do
      Process.put(
        :reject_result,
        {:error, %Ecto.Changeset{}}
      )

      assert {:error, %{code: :reject_failed, plan_id: "abc"}} =
               Plan.reject("abc", nil, opts())
    end
  end

  # ── run/2 ────────────────────────────────────────────────────────────

  describe "run/2" do
    test "transitions an approved plan to running via run_plan" do
      Process.put(
        :run_plan_result,
        {:ok, %{id: "abc", status: "running", mode: "nano", plan_steps: [], plan_events: []}}
      )

      assert {:ok, %{kind: :plan_running, plan_id: "abc", status: "running"}} =
               Plan.run("abc", opts())

      assert [["abc", opts]] = run_plan_calls()
      assert Keyword.get(opts, :project_dir) != nil
    end

    test "refuses to run a stale plan" do
      Process.put(:run_plan_result, {:error, :stale_plan})

      assert {:error, %{code: :stale_plan, plan_id: "abc", message: msg}} =
               Plan.run("abc", opts())

      assert msg =~ "stale"
    end

    test "refuses to run when staleness is unknown" do
      Process.put(:run_plan_result, {:error, :stale_plan_unknown})

      assert {:error, %{code: :stale_plan_unknown, plan_id: "abc", message: msg}} =
               Plan.run("abc", opts())

      assert msg =~ "staleness cannot be determined"
    end

    test "refuses to run a plan not in approved status" do
      Process.put(:run_plan_result, {:error, :invalid_transition})

      assert {:error, %{code: :invalid_transition, plan_id: "abc"}} =
               Plan.run("abc", opts())
    end

    test "returns :not_found when plan does not exist" do
      Process.put(:run_plan_result, {:error, :not_found})

      assert {:error, %{code: :not_found, plan_id: "missing"}} =
               Plan.run("missing", opts())
    end

    test "maps other errors to :run_failed" do
      Process.put(:run_plan_result, {:error, :db_down})

      assert {:error, %{code: :run_failed, plan_id: "abc", message: msg}} =
               Plan.run("abc", opts())

      assert msg =~ "db_down"
    end

    test "passes project_dir and context_builder_module through to run_plan" do
      Process.put(
        :run_plan_result,
        {:ok, %{id: "abc", status: "running", mode: "nano", plan_steps: [], plan_events: []}}
      )

      Plan.run("abc", opts(project_dir: "/my/project", context_builder_module: SomeBuilder))

      assert [["abc", run_opts]] = run_plan_calls()
      assert Keyword.get(run_opts, :project_dir) == "/my/project"
      assert Keyword.get(run_opts, :context_builder_module) == SomeBuilder
    end
  end
end
