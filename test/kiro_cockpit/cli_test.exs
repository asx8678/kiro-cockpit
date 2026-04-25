defmodule KiroCockpit.CLITest do
  @moduledoc """
  Pure parser + dispatcher tests for `KiroCockpit.CLI`.

  These tests exercise the slash-command grammar in isolation. They
  do NOT require a database, a Kiro subprocess, or a running Phoenix
  endpoint — `parse/1` is pure and `dispatch/2` is fed fake service
  modules via opts.
  """

  use ExUnit.Case, async: true

  alias KiroCockpit.CLI

  # ── A tiny in-memory fake of NanoPlanner / Plans ─────────────────────

  defmodule FakeServices do
    @moduledoc false

    # Used as both `:nano_planner_module` and `:plans_module` so tests
    # can route a single dispatch through whichever leg they care about.
    # All entry points are pure functions over the process dictionary.

    def plan(_session, request, opts) do
      record(:plan, {request, opts})

      case Process.get(:fake_plan_result) do
        nil -> {:ok, fake_plan(%{user_request: request, mode: opts[:mode] || :nano})}
        result -> result
      end
    end

    def approve(_session, plan_id, opts) do
      record(:approve, {plan_id, opts})

      case Process.get(:fake_approve_result) do
        nil ->
          {:ok, %{plan: fake_plan(%{id: plan_id, status: "approved"}), prompt_result: %{}}}

        result ->
          result
      end
    end

    def revise(_session, plan_id, request, opts) do
      record(:revise, {plan_id, request, opts})

      case Process.get(:fake_revise_result) do
        nil ->
          {:ok,
           fake_plan(%{
             id: "revised-of-#{plan_id}",
             status: "draft",
             user_request: request
           })}

        result ->
          result
      end
    end

    def get_plan(plan_id) do
      case Process.get(:fake_get_plan_result) do
        nil -> fake_plan(%{id: plan_id})
        :nil_value -> nil
        plan -> plan
      end
    end

    def list_plans(session_id, opts) do
      record(:list_plans, {session_id, opts})

      Process.get(:fake_list_plans_result, [
        fake_plan(%{id: "p1", session_id: session_id}),
        fake_plan(%{id: "p2", session_id: session_id})
      ])
    end

    def reject_plan(plan_id, reason) do
      record(:reject_plan, {plan_id, reason})

      case Process.get(:fake_reject_plan_result) do
        nil -> {:ok, fake_plan(%{id: plan_id, status: "rejected"})}
        result -> result
      end
    end

    def update_status(plan_id, status, payload) do
      record(:update_status, {plan_id, status, payload})

      case Process.get(:fake_update_status_result) do
        nil -> {:ok, fake_plan(%{id: plan_id, status: status})}
        result -> result
      end
    end

    defp fake_plan(overrides) do
      defaults = %{
        id: "plan-abc",
        session_id: "sess-1",
        mode: "nano",
        status: "draft",
        user_request: "build it",
        plan_markdown: "# Plan",
        execution_prompt: "go",
        plan_steps: [],
        plan_events: []
      }

      Map.merge(defaults, normalize_overrides(overrides))
    end

    defp normalize_overrides(map) do
      Map.new(map, fn
        {:mode, v} when is_atom(v) -> {:mode, Atom.to_string(v)}
        {k, v} -> {k, v}
      end)
    end

    defp record(key, value) do
      calls = Process.get({:fake_calls, key}, [])
      Process.put({:fake_calls, key}, calls ++ [value])
    end
  end

  defp fake_opts(extra \\ []) do
    Keyword.merge(
      [
        nano_planner_module: FakeServices,
        plans_module: FakeServices,
        session: :fake_session,
        session_id: "sess-1"
      ],
      extra
    )
  end

  defp calls(key), do: Process.get({:fake_calls, key}, [])

  # ── parse/1 happy paths ──────────────────────────────────────────────

  describe "parse/1 — slash-command grammar" do
    test "/nano <task>" do
      assert {:ok, {:nano, :nano, "Add OAuth login"}} = CLI.parse("/nano Add OAuth login")
    end

    test "/nano-deep <task>" do
      assert {:ok, {:nano, :nano_deep, "Refactor session handling"}} =
               CLI.parse("/nano-deep Refactor session handling")
    end

    test "/nano-fix <problem>" do
      assert {:ok, {:nano, :nano_fix, "Turn ends too early"}} =
               CLI.parse("/nano-fix Turn ends too early")
    end

    test "/plans (no args)" do
      assert {:ok, {:plans}} = CLI.parse("/plans")
      assert {:ok, {:plans}} = CLI.parse("  /plans  ")
    end

    test "/plan show <id>" do
      assert {:ok, {:plan, :show, "abc-123"}} = CLI.parse("/plan show abc-123")
    end

    test "/plan approve <id>" do
      assert {:ok, {:plan, :approve, "abc-123"}} = CLI.parse("/plan approve abc-123")
    end

    test "/plan run <id>" do
      assert {:ok, {:plan, :run, "abc-123"}} = CLI.parse("/plan run abc-123")
    end

    test "/plan reject <id> with no reason" do
      assert {:ok, {:plan, :reject, "abc-123", nil}} = CLI.parse("/plan reject abc-123")
    end

    test "/plan reject <id> <reason ...> joins multi-word reason" do
      assert {:ok, {:plan, :reject, "abc-123", "user cancelled the task"}} =
               CLI.parse("/plan reject abc-123 user cancelled the task")
    end

    test "/plan revise <id> <request> joins multi-word request" do
      assert {:ok, {:plan, :revise, "abc-123", "add more tests for the auth path"}} =
               CLI.parse("/plan revise abc-123 add more tests for the auth path")
    end

    test "tolerates leading/trailing whitespace and trailing newline" do
      assert {:ok, {:nano, :nano, "do thing"}} = CLI.parse("  /nano do thing\n")
    end

    test "collapses multiple internal spaces in head split" do
      # The argument body is preserved verbatim after the first whitespace run.
      assert {:ok, {:nano, :nano, "do  it  twice"}} = CLI.parse("/nano  do  it  twice")
    end
  end

  # ── parse/1 error paths ──────────────────────────────────────────────

  describe "parse/1 — error paths" do
    test "rejects empty input" do
      assert {:error, :empty_input} = CLI.parse("")
      assert {:error, :empty_input} = CLI.parse("   ")
    end

    test "rejects input that does not start with /" do
      assert {:error, :unknown_command} = CLI.parse("nano build it")
    end

    test "rejects unknown top-level command" do
      assert {:error, {:unknown_subcommand, "explode"}} = CLI.parse("/explode now")
    end

    test "rejects unknown plan subcommand" do
      assert {:error, {:unknown_subcommand, "plan archive"}} = CLI.parse("/plan archive abc")
    end

    test "rejects /nano with no task" do
      assert {:error, {:missing_argument, :task}} = CLI.parse("/nano")
      assert {:error, {:missing_argument, :task}} = CLI.parse("/nano   ")
    end

    test "rejects /nano-deep with no task" do
      assert {:error, {:missing_argument, :task}} = CLI.parse("/nano-deep")
    end

    test "rejects /nano-fix with no problem" do
      assert {:error, {:missing_argument, :task}} = CLI.parse("/nano-fix")
    end

    test "rejects /plans with extra arguments" do
      assert {:error, {:unknown_subcommand, "now"}} = CLI.parse("/plans now")
    end

    test "rejects /plan with no subcommand" do
      assert {:error, {:missing_argument, :subcommand}} = CLI.parse("/plan")
      assert {:error, {:missing_argument, :subcommand}} = CLI.parse("/plan   ")
    end

    test "rejects /plan show with no id" do
      assert {:error, {:missing_argument, :id}} = CLI.parse("/plan show")
    end

    test "rejects /plan approve with no id" do
      assert {:error, {:missing_argument, :id}} = CLI.parse("/plan approve")
    end

    test "rejects /plan run with no id" do
      assert {:error, {:missing_argument, :id}} = CLI.parse("/plan run")
    end

    test "rejects /plan reject with no id" do
      assert {:error, {:missing_argument, :id}} = CLI.parse("/plan reject")
    end

    test "rejects /plan revise with no id" do
      assert {:error, {:missing_argument, :id}} = CLI.parse("/plan revise")
    end

    test "rejects /plan revise with id but no request" do
      assert {:error, {:missing_argument, :request}} = CLI.parse("/plan revise abc-123")
      assert {:error, {:missing_argument, :request}} = CLI.parse("/plan revise abc-123    ")
    end
  end

  # ── dispatch/2 — routes to the right service ─────────────────────────

  describe "dispatch/2 — routing" do
    setup do
      # Fresh process dictionary so previous tests do not leak.
      Process.put({:fake_calls, :plan}, [])
      Process.put({:fake_calls, :approve}, [])
      Process.put({:fake_calls, :revise}, [])
      Process.put({:fake_calls, :reject_plan}, [])
      Process.put({:fake_calls, :list_plans}, [])
      Process.put({:fake_calls, :update_status}, [])
      :ok
    end

    test "{:nano, mode, task} calls planner.plan/3 with mode forwarded" do
      assert {:ok, %{kind: :plan_created, mode: :nano_deep, plan_id: id}} =
               CLI.dispatch({:nano, :nano_deep, "deep dive"}, fake_opts())

      assert is_binary(id)
      assert [{"deep dive", opts}] = calls(:plan)
      assert opts[:mode] == :nano_deep
    end

    test "{:plans} calls plans_module.list_plans/2" do
      assert {:ok, %{kind: :plans_listed, count: 2, session_id: "sess-1"}} =
               CLI.dispatch({:plans}, fake_opts())

      assert [{"sess-1", []}] = calls(:list_plans)
    end

    test "{:plan, :show, id} returns :plan_shown when plan exists" do
      assert {:ok, %{kind: :plan_shown, plan_id: "abc"}} =
               CLI.dispatch({:plan, :show, "abc"}, fake_opts())
    end

    test "{:plan, :show, id} returns :not_found when get_plan returns nil" do
      Process.put(:fake_get_plan_result, :nil_value)

      assert {:error, %{code: :not_found, plan_id: "abc"}} =
               CLI.dispatch({:plan, :show, "abc"}, fake_opts())
    end

    test "{:plan, :approve, id} calls planner.approve/3" do
      assert {:ok, %{kind: :plan_approved}} =
               CLI.dispatch({:plan, :approve, "abc"}, fake_opts())

      assert [{"abc", _opts}] = calls(:approve)
    end

    test "{:plan, :revise, id, req} calls planner.revise/4" do
      assert {:ok, %{kind: :plan_revised, previous_plan_id: "abc"}} =
               CLI.dispatch({:plan, :revise, "abc", "do better"}, fake_opts())

      assert [{"abc", "do better", _opts}] = calls(:revise)
    end

    test "{:plan, :reject, id, reason} calls plans.reject_plan/2" do
      assert {:ok, %{kind: :plan_rejected, reason: "bad idea"}} =
               CLI.dispatch({:plan, :reject, "abc", "bad idea"}, fake_opts())

      assert [{"abc", "bad idea"}] = calls(:reject_plan)
    end

    test "{:plan, :reject, id, nil} calls plans.reject_plan/2 with nil reason" do
      assert {:ok, %{kind: :plan_rejected, reason: nil}} =
               CLI.dispatch({:plan, :reject, "abc", nil}, fake_opts())

      assert [{"abc", nil}] = calls(:reject_plan)
    end

    test "{:plan, :run, id} on approved plan calls update_status/3 with running" do
      Process.put(:fake_get_plan_result, %{
        id: "abc",
        status: "approved",
        mode: "nano",
        plan_steps: []
      })

      assert {:ok, %{kind: :plan_running, status: "running"}} =
               CLI.dispatch({:plan, :run, "abc"}, fake_opts())

      assert [{"abc", "running", %{"source" => "cli"}}] = calls(:update_status)
    end
  end

  # ── run/2 — convenience entrypoint ───────────────────────────────────

  describe "run/2 — combined parse + dispatch" do
    setup do
      Process.put({:fake_calls, :plan}, [])
      :ok
    end

    test "parses and dispatches in one shot" do
      assert {:ok, %{kind: :plan_created}} =
               CLI.run("/nano build a thing", fake_opts())

      assert [{"build a thing", _}] = calls(:plan)
    end

    test "wraps parse errors with :parse_error code" do
      assert {:error, %{code: :parse_error, reason: :unknown_command}} =
               CLI.run("nano oops", fake_opts())
    end

    test "wraps missing-argument parse errors" do
      assert {:error, %{code: :parse_error, reason: {:missing_argument, :task}}} =
               CLI.run("/nano", fake_opts())
    end

    test "wraps empty-input parse errors" do
      assert {:error, %{code: :parse_error, reason: :empty_input}} =
               CLI.run("   ", fake_opts())
    end
  end
end
