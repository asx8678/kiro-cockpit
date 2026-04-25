defmodule KiroCockpit.CLI.Commands.Nano do
  @moduledoc """
  CLI handler for `/nano`, `/nano-deep`, and `/nano-fix` (plan2.md §12).

  Thin wrapper around `KiroCockpit.NanoPlanner.plan/3` that:

    * resolves the planning mode from the slash-command,
    * forwards `:session` and any planner opts to the service,
    * normalises the result into a stable CLI payload shape.

  This module does **not** know about IO, prompts, or rendering. The
  caller decides how to display the returned `%{kind: ...}` payload.
  """

  alias KiroCockpit.CLI.Result
  alias KiroCockpit.NanoPlanner

  @typedoc "Supported planning modes."
  @type mode :: :nano | :nano_deep | :nano_fix

  @doc """
  Runs a NanoPlanner planning request for the given mode.

  Required opts:

    * `:session` — opaque session reference passed to NanoPlanner.

  Optional opts (forwarded to the planner):

    * `:nano_planner_module` (default `KiroCockpit.NanoPlanner`) —
      injected for tests. Must implement `plan/3`.
    * Any other opt accepted by `KiroCockpit.NanoPlanner.plan/3`
      (e.g. `:project_dir`, `:session_id`, `:planner_timeout`,
      `:kiro_session_module`). The dispatcher always sets `:mode`
      from the parsed slash-command and ignores any caller-provided
      `:mode`.

  Returns `{:ok, %{kind: :plan_created, plan: plan, mode: mode,
  message: String.t()}}` or `{:error, %{code: atom, message:
  String.t(), ...}}`.
  """
  @spec run(mode(), String.t(), keyword()) :: KiroCockpit.CLI.result()
  def run(mode, task, opts) when mode in [:nano, :nano_deep, :nano_fix] and is_binary(task) do
    case String.trim(task) do
      "" ->
        Result.error(:missing_argument, "task is required for /#{mode_to_slash(mode)}",
          mode: mode
        )

      cleaned_task ->
        do_run(mode, cleaned_task, opts)
    end
  end

  # ── Internals ────────────────────────────────────────────────────────

  defp do_run(mode, task, opts) do
    {planner, planner_opts} = pop_planner(opts)
    {session, planner_opts} = Keyword.pop(planner_opts, :session)

    # /nano-fix is unambiguous — caller cannot override the mode.
    planner_opts = Keyword.put(planner_opts, :mode, mode)

    case planner.plan(session, task, planner_opts) do
      {:ok, plan} -> success(plan, mode)
      {:error, reason} -> failure(reason, mode)
    end
  end

  defp success(plan, mode) do
    Result.ok(:plan_created, %{
      plan: plan,
      mode: mode,
      plan_id: plan.id,
      status: plan.status,
      message: "NanoPlanner created plan #{plan.id} (mode: #{plan.mode})"
    })
  end

  # Defensive: should be impossible since we set mode ourselves.
  defp failure({:invalid_mode, bad}, mode) do
    Result.error(:invalid_mode, "invalid mode: #{inspect(bad)}", mode: mode)
  end

  defp failure({:invalid_model_output, detail}, mode) do
    Result.error(:invalid_model_output, "model output could not be parsed: #{detail}", mode: mode)
  end

  defp failure({:invalid_plan, detail}, mode) do
    Result.error(:invalid_plan, "planner produced an invalid plan: #{detail}", mode: mode)
  end

  defp failure({:persist_failed, reason}, mode) do
    Result.error(:persist_failed, "could not persist plan: #{inspect(reason)}", mode: mode)
  end

  defp failure(:session_unavailable, mode) do
    Result.error(
      :session_unavailable,
      "Kiro session is unavailable — start a session before planning",
      mode: mode
    )
  end

  defp failure(:session_id_required, mode) do
    Result.error(
      :session_id_required,
      "no active session id — pass `--session-id` or open a session first",
      mode: mode
    )
  end

  defp failure(:project_dir_required, mode) do
    Result.error(
      :project_dir_required,
      "no project directory available — pass `--project-dir` or set the session cwd",
      mode: mode
    )
  end

  defp failure(reason, mode) do
    Result.error(:planner_failed, "planner failed: #{inspect(reason)}", mode: mode)
  end

  defp pop_planner(opts) do
    Keyword.pop(opts, :nano_planner_module, NanoPlanner)
  end

  defp mode_to_slash(:nano), do: "nano"
  defp mode_to_slash(:nano_deep), do: "nano-deep"
  defp mode_to_slash(:nano_fix), do: "nano-fix"
end
