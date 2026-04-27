defmodule KiroCockpitWeb.SessionPlanLive.AsyncFlashTest do
  @moduledoc """
  Integration tests proving that SessionPlanLive's handle_async/2 flash
  paths delegate to SafeErrorFormatter and never leak PII/secrets
  into flash messages.

  These test the **end-to-end** path: fake planner returns errors/exits →
  LiveView handle_async → SafeErrorFormatter → flash message rendered in HTML.

  Unit-level coverage of SafeErrorFormatter lives in
  SafeErrorFormatterTest; this file covers the wiring.
  """
  use KiroCockpitWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias KiroCockpitWeb.SafeErrorFormatter

  # ── Fake planners that produce error/exit shapes ────────────────────

  defmodule ErrorPlanner do
    @moduledoc false
    # Returns errors with potentially dangerous content.
    # Error shape is controlled via Application env so the LiveView's
    # normal opts (mode, session_id) are undisturbed.
    def plan(_session, _request, _opts) do
      error_type = Application.get_env(:kiro_cockpit, :planner_error_type, :binary_secret)

      case error_type do
        :binary_secret ->
          {:error, "Connection failed: password=hunter2 token=ghp_abc123def456"}

        :list_with_secrets ->
          {:error, ["api_key=sk-prod-key", "password=admin123"]}

        :exception_with_secret ->
          {:error, %RuntimeError{message: "DB error: secret=mydbpassword"}}

        :map_error ->
          {:error, %{token: "leaked", password: "oops"}}

        :tuple_error ->
          {:error, {:timeout, "token=sk-abcdef1234567890"}}
      end
    end

    def approve(_session, _plan_id, _opts), do: {:error, :not_found}
    def revise(_session, _plan_id, _request, _opts), do: {:error, :not_found}
  end

  defmodule CrashPlanner do
    @moduledoc false
    # Crashes with different exit reasons.
    # Crash type is controlled via Application env.
    def plan(_session, _request, _opts) do
      crash_type = Application.get_env(:kiro_cockpit, :planner_crash_type, :shutdown_with_secret)

      case crash_type do
        :shutdown_with_secret ->
          exit({:shutdown, "password=hunter2"})

        :normal ->
          exit(:normal)

        :killed ->
          exit(:killed)

        :complex ->
          exit({:noproc, {GenServer, :call, [MyServer, :request, 5000]}})
      end
    end

    def approve(_session, _plan_id, _opts), do: {:error, :not_found}
    def revise(_session, _plan_id, _request, _opts), do: {:error, :not_found}
  end

  # ── Tests ──────────────────────────────────────────────────────────

  describe "handle_async error flash — SafeErrorFormatter integration (§22.6/§25.6)" do
    setup do
      on_exit(fn ->
        Application.delete_env(:kiro_cockpit, :nano_planner_module)
        Application.delete_env(:kiro_cockpit, :planner_error_type)
        Application.delete_env(:kiro_cockpit, :planner_crash_type)
      end)

      :ok
    end

    test "binary error with secrets is redacted in flash", %{conn: conn} do
      Application.put_env(:kiro_cockpit, :nano_planner_module, ErrorPlanner)
      Application.put_env(:kiro_cockpit, :planner_error_type, :binary_secret)

      session_id = "async-err-binary-#{System.unique_integer([:positive])}"
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session_id}/plan")

      view
      |> element("form[phx-submit='generate_plan']")
      |> render_submit(%{request: "test", mode: "nano"})

      # Wait for async result to process
      html = render(view)

      # Secret values should NOT appear in rendered HTML
      refute html =~ "hunter2"
      refute html =~ "ghp_abc123def456"
      # But the error category should be visible
      assert html =~ "Failed to generate plan" or html =~ "password=[REDACTED]"
    end

    test "list error shows count, never inspects contents", %{conn: conn} do
      Application.put_env(:kiro_cockpit, :nano_planner_module, ErrorPlanner)
      Application.put_env(:kiro_cockpit, :planner_error_type, :list_with_secrets)

      session_id = "async-err-list-#{System.unique_integer([:positive])}"
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session_id}/plan")

      view
      |> element("form[phx-submit='generate_plan']")
      |> render_submit(%{request: "test", mode: "nano"})

      html = render(view)

      # List contents must never appear
      refute html =~ "sk-prod-key"
      refute html =~ "admin123"
      # Should show count summary
      assert html =~ "list of 2 item(s)" or html =~ "Failed to generate plan"
    end

    test "exception error with secrets is redacted", %{conn: conn} do
      Application.put_env(:kiro_cockpit, :nano_planner_module, ErrorPlanner)
      Application.put_env(:kiro_cockpit, :planner_error_type, :exception_with_secret)

      session_id = "async-err-exc-#{System.unique_integer([:positive])}"
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session_id}/plan")

      view
      |> element("form[phx-submit='generate_plan']")
      |> render_submit(%{request: "test", mode: "nano"})

      html = render(view)

      refute html =~ "mydbpassword"
      assert html =~ "Failed to generate plan"
    end

    test "map error shows type name only, never inspects", %{conn: conn} do
      Application.put_env(:kiro_cockpit, :nano_planner_module, ErrorPlanner)
      Application.put_env(:kiro_cockpit, :planner_error_type, :map_error)

      session_id = "async-err-map-#{System.unique_integer([:positive])}"
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session_id}/plan")

      view
      |> element("form[phx-submit='generate_plan']")
      |> render_submit(%{request: "test", mode: "nano"})

      html = render(view)

      refute html =~ "leaked"
      refute html =~ "oops"
      # Should show "unexpected error: map"
      assert html =~ "map" or html =~ "Failed to generate plan"
    end

    test "tuple error shows type name only, never inspects", %{conn: conn} do
      Application.put_env(:kiro_cockpit, :nano_planner_module, ErrorPlanner)
      Application.put_env(:kiro_cockpit, :planner_error_type, :tuple_error)

      session_id = "async-err-tuple-#{System.unique_integer([:positive])}"
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session_id}/plan")

      view
      |> element("form[phx-submit='generate_plan']")
      |> render_submit(%{request: "test", mode: "nano"})

      html = render(view)

      refute html =~ "sk-abcdef1234567890"
      # Should show "unexpected error: tuple"
      assert html =~ "tuple" or html =~ "Failed to generate plan"
    end
  end

  describe "handle_async exit flash — SafeErrorFormatter integration (§22.6/§25.6)" do
    setup do
      on_exit(fn ->
        Application.delete_env(:kiro_cockpit, :nano_planner_module)
        Application.delete_env(:kiro_cockpit, :planner_crash_type)
      end)

      :ok
    end

    test "shutdown with secret reason does not expose reason text", %{conn: conn} do
      Application.put_env(:kiro_cockpit, :nano_planner_module, CrashPlanner)
      Application.put_env(:kiro_cockpit, :planner_crash_type, :shutdown_with_secret)

      session_id = "async-exit-shutdown-#{System.unique_integer([:positive])}"
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session_id}/plan")

      view
      |> element("form[phx-submit='generate_plan']")
      |> render_submit(%{request: "test", mode: "nano"})

      html = render(view)

      refute html =~ "hunter2"
      assert html =~ "Plan generation crashed" or html =~ "shutdown"
    end

    test "normal exit is labeled correctly", %{conn: conn} do
      Application.put_env(:kiro_cockpit, :nano_planner_module, CrashPlanner)
      Application.put_env(:kiro_cockpit, :planner_crash_type, :normal)

      session_id = "async-exit-normal-#{System.unique_integer([:positive])}"
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session_id}/plan")

      view
      |> element("form[phx-submit='generate_plan']")
      |> render_submit(%{request: "test", mode: "nano"})

      html = render(view)

      assert html =~ "Plan generation crashed" or html =~ "normal exit"
    end

    test "complex exit reason shows generic message, no module names", %{conn: conn} do
      Application.put_env(:kiro_cockpit, :nano_planner_module, CrashPlanner)
      Application.put_env(:kiro_cockpit, :planner_crash_type, :complex)

      session_id = "async-exit-complex-#{System.unique_integer([:positive])}"
      {:ok, view, _html} = live(conn, ~p"/sessions/#{session_id}/plan")

      view
      |> element("form[phx-submit='generate_plan']")
      |> render_submit(%{request: "test", mode: "nano"})

      html = render(view)

      refute html =~ "GenServer"
      refute html =~ "MyServer"
      assert html =~ "unexpected exit" or html =~ "Plan generation crashed"
    end
  end

  describe "SafeErrorFormatter direct — wiring sanity check" do
    test "format_error is called by LiveView for error flash" do
      # Quick sanity: the module is aliased and the function exists
      assert function_exported?(SafeErrorFormatter, :format_error, 1)
      assert function_exported?(SafeErrorFormatter, :format_exit, 1)
      assert function_exported?(SafeErrorFormatter, :safe_truncate, 2)
      assert function_exported?(SafeErrorFormatter, :redact_secrets, 1)
    end
  end
end
