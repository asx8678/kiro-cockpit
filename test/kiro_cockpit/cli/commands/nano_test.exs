defmodule KiroCockpit.CLI.Commands.NanoTest do
  @moduledoc """
  Unit tests for `KiroCockpit.CLI.Commands.Nano`.

  Pure: the planner module is injected via opts so no DB and no Kiro
  subprocess are involved.
  """

  use ExUnit.Case, async: true

  alias KiroCockpit.CLI.Commands.Nano

  defmodule FakePlanner do
    @moduledoc false

    def plan(session, request, opts) do
      Process.put(:nano_calls, [{session, request, opts} | Process.get(:nano_calls, [])])

      Process.get(:nano_result, {:ok, fake_plan(opts[:mode] || :nano)})
    end

    defp fake_plan(mode) do
      %{
        id: "plan-1",
        mode: Atom.to_string(mode),
        status: "draft",
        plan_steps: [],
        plan_events: []
      }
    end
  end

  defp fake_opts(extra \\ []) do
    Keyword.merge(
      [nano_planner_module: FakePlanner, session: :fake_session],
      extra
    )
  end

  defp last_call do
    Process.get(:nano_calls, []) |> List.first()
  end

  setup do
    Process.put(:nano_calls, [])
    :ok
  end

  # ── Happy paths ──────────────────────────────────────────────────────

  describe "run/3 — happy paths" do
    test ":nano forwards mode :nano to planner" do
      assert {:ok, %{kind: :plan_created, mode: :nano, plan_id: "plan-1", status: "draft"}} =
               Nano.run(:nano, "build a thing", fake_opts())

      assert {_session, "build a thing", opts} = last_call()
      assert opts[:mode] == :nano
    end

    test ":nano_deep forwards mode :nano_deep to planner" do
      assert {:ok, %{kind: :plan_created, mode: :nano_deep}} =
               Nano.run(:nano_deep, "deep refactor", fake_opts())

      assert {_session, _request, opts} = last_call()
      assert opts[:mode] == :nano_deep
    end

    test ":nano_fix forwards mode :nano_fix to planner" do
      assert {:ok, %{kind: :plan_created, mode: :nano_fix}} =
               Nano.run(:nano_fix, "fix the bug", fake_opts())

      assert {_session, _request, opts} = last_call()
      assert opts[:mode] == :nano_fix
    end

    test "passes session through to the planner" do
      Nano.run(:nano, "x", fake_opts(session: :my_session))
      assert {:my_session, "x", _} = last_call()
    end

    test "forwards arbitrary planner opts (e.g. :project_dir)" do
      Nano.run(:nano, "x", fake_opts(project_dir: "/tmp/project"))
      assert {_, _, opts} = last_call()
      assert opts[:project_dir] == "/tmp/project"
    end

    test "callee-provided :mode is ALWAYS overridden by the dispatched mode" do
      # Defensive: we never let a caller smuggle a different mode in.
      Nano.run(:nano_fix, "x", fake_opts(mode: :nano))
      assert {_, _, opts} = last_call()
      assert opts[:mode] == :nano_fix
    end

    test "result message includes plan id and mode" do
      assert {:ok, %{message: msg}} = Nano.run(:nano, "build", fake_opts())
      assert msg =~ "plan-1"
      assert msg =~ "nano"
    end
  end

  # ── Argument validation ─────────────────────────────────────────────

  describe "run/3 — argument validation" do
    test "rejects empty task" do
      assert {:error, %{code: :missing_argument, mode: :nano}} = Nano.run(:nano, "", fake_opts())
    end

    test "rejects whitespace-only task" do
      assert {:error, %{code: :missing_argument}} = Nano.run(:nano, "   \n  ", fake_opts())
    end

    test "trims surrounding whitespace from task" do
      Nano.run(:nano, "   build a thing   ", fake_opts())
      assert {_, "build a thing", _} = last_call()
    end
  end

  # ── Error mapping ────────────────────────────────────────────────────

  describe "run/3 — error mapping" do
    test "maps {:invalid_model_output, _}" do
      Process.put(:nano_result, {:error, {:invalid_model_output, "JSON parse error"}})

      assert {:error, %{code: :invalid_model_output, message: msg, mode: :nano}} =
               Nano.run(:nano, "x", fake_opts())

      assert msg =~ "JSON parse error"
    end

    test "maps {:invalid_plan, _}" do
      Process.put(:nano_result, {:error, {:invalid_plan, "missing required keys"}})

      assert {:error, %{code: :invalid_plan, message: msg}} =
               Nano.run(:nano, "x", fake_opts())

      assert msg =~ "missing required keys"
    end

    test "maps {:persist_failed, _}" do
      Process.put(:nano_result, {:error, {:persist_failed, :db_down}})

      assert {:error, %{code: :persist_failed, message: msg}} =
               Nano.run(:nano, "x", fake_opts())

      assert msg =~ "db_down"
    end

    test "maps :session_unavailable" do
      Process.put(:nano_result, {:error, :session_unavailable})

      assert {:error, %{code: :session_unavailable, message: msg}} =
               Nano.run(:nano, "x", fake_opts())

      assert msg =~ "session is unavailable"
    end

    test "maps :session_id_required" do
      Process.put(:nano_result, {:error, :session_id_required})

      assert {:error, %{code: :session_id_required, message: msg}} =
               Nano.run(:nano, "x", fake_opts())

      assert msg =~ "no active session id"
    end

    test "maps :project_dir_required" do
      Process.put(:nano_result, {:error, :project_dir_required})

      assert {:error, %{code: :project_dir_required, message: msg}} =
               Nano.run(:nano, "x", fake_opts())

      assert msg =~ "no project directory available"
    end

    test "maps unknown error reasons to :planner_failed" do
      Process.put(:nano_result, {:error, :timeout})

      assert {:error, %{code: :planner_failed, message: msg}} =
               Nano.run(:nano, "x", fake_opts())

      assert msg =~ ":timeout"
    end

    test "maps {:invalid_mode, _} defensively" do
      Process.put(:nano_result, {:error, {:invalid_mode, "weird"}})

      assert {:error, %{code: :invalid_mode, message: msg}} =
               Nano.run(:nano, "x", fake_opts())

      assert msg =~ "weird"
    end
  end
end
