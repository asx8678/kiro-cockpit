defmodule KiroCockpit.CLI.Commands.Plan do
  @moduledoc """
  CLI handler for `/plans` and `/plan {show,approve,revise,reject,run}`
  (plan2.md §12).

  Each public function maps to one CLI verb and delegates to the
  appropriate application service:

    * `list/1`    → `Plans.list_plans/2`
    * `show/2`    → `Plans.get_plan/1`
    * `approve/2` → `NanoPlanner.approve/3` (DB approval + execution
                    prompt to Kiro)
    * `revise/3`  → `NanoPlanner.revise/4` (new draft + supersede old)
    * `reject/3`  → `Plans.reject_plan/2`
    * `run/2`     → `Plans.update_status/3` to `"running"`

  All result payloads carry a stable `:kind`/`:code` atom for
  scripting; human-readable `:message` is for display only.

  ## /plan run rationale

  `Plans.update_status/3` already enforces a safe set of transitions
  (`running`, `completed`, `failed`, `superseded`). To keep the
  approval gate meaningful, this module additionally refuses to run a
  plan that is not in `"approved"` status — a draft must be approved
  first (via `/plan approve` or the LiveView surface). This makes
  `/plan run` an explicit, auditable transition rather than a hidden
  alias for `/plan approve`.
  """

  alias KiroCockpit.CLI.Result
  alias KiroCockpit.NanoPlanner
  alias KiroCockpit.Plans

  @doc """
  Lists plans for a session.

  Required opts:

    * `:session_id` — session id whose plans to list.

  Optional opts:

    * `:status` — filter by plan status (forwarded to `list_plans/2`).
    * `:plans_module` (default `KiroCockpit.Plans`) — injected for
      tests. Must implement `list_plans/2`.

  Returns `{:ok, %{kind: :plans_listed, session_id: id, plans: [...],
  count: n, message: ...}}`.
  """
  @spec list(keyword()) :: KiroCockpit.CLI.result()
  def list(opts) do
    {plans_mod, opts} = pop_plans(opts)

    case Keyword.fetch(opts, :session_id) do
      :error ->
        Result.error(:session_id_required, "no `:session_id` provided to /plans")

      {:ok, session_id} ->
        list_opts = Keyword.take(opts, [:status])
        plans = plans_mod.list_plans(session_id, list_opts)

        Result.ok(:plans_listed, %{
          session_id: session_id,
          plans: plans,
          count: length(plans),
          message: "Listed #{length(plans)} plan(s) for session #{session_id}"
        })
    end
  end

  @doc """
  Shows a plan by id.

  Optional opts:

    * `:plans_module` (default `KiroCockpit.Plans`) — injected for
      tests. Must implement `get_plan/1`.

  Returns `{:ok, %{kind: :plan_shown, plan: plan, ...}}` or an error
  with code `:not_found` if the plan does not exist.
  """
  @spec show(String.t(), keyword()) :: KiroCockpit.CLI.result()
  def show(id, opts) do
    {plans_mod, _} = pop_plans(opts)

    case plans_mod.get_plan(id) do
      nil ->
        Result.error(:not_found, "plan not found: #{id}", plan_id: id)

      plan ->
        Result.ok(:plan_shown, %{
          plan: plan,
          plan_id: plan.id,
          status: plan.status,
          mode: plan.mode,
          message: "Plan #{plan.id} (mode: #{plan.mode}, status: #{plan.status})"
        })
    end
  end

  @doc """
  Approves a draft plan and triggers Kiro execution.

  Required opts:

    * `:session` — session reference to forward to NanoPlanner.

  Optional opts (forwarded to the planner):

    * `:nano_planner_module` (default `KiroCockpit.NanoPlanner`) —
      injected for tests. Must implement `approve/3`.
    * Any other opt accepted by `NanoPlanner.approve/3`
      (e.g. `:kiro_session_module`, `:project_dir`,
      `:planner_timeout`).
  """
  @spec approve(String.t(), keyword()) :: KiroCockpit.CLI.result()
  def approve(id, opts) do
    {planner, planner_opts} = pop_planner(opts)
    {session, planner_opts} = Keyword.pop(planner_opts, :session)

    case planner.approve(session, id, planner_opts) do
      {:ok, %{plan: plan, prompt_result: prompt_result}} ->
        Result.ok(:plan_approved, %{
          plan: plan,
          plan_id: plan.id,
          status: plan.status,
          prompt_result: prompt_result,
          message: "Plan #{plan.id} approved and execution prompt sent to Kiro"
        })

      {:error, :not_found} ->
        Result.error(:not_found, "plan not found: #{id}", plan_id: id)

      {:error, :stale_plan} ->
        Result.error(
          :stale_plan,
          "plan #{id} is stale — the project has changed since it was generated; revise or regenerate",
          plan_id: id
        )

      {:error, :invalid_transition} ->
        Result.error(
          :invalid_transition,
          "plan #{id} is not in `draft` status — cannot approve",
          plan_id: id
        )

      {:error, {:prompt_failed, plan, reason}} ->
        Result.error(
          :prompt_failed,
          "plan #{plan.id} was approved but the execution prompt failed: #{inspect(reason)}",
          plan_id: plan.id,
          plan: plan
        )

      {:error, reason} ->
        Result.error(:approve_failed, "could not approve plan: #{inspect(reason)}", plan_id: id)
    end
  end

  @doc """
  Revises a plan: creates a new draft and supersedes the old one.

  Required opts:

    * `:session` — session reference to forward to NanoPlanner.

  Optional opts (forwarded to the planner):

    * `:nano_planner_module` (default `KiroCockpit.NanoPlanner`) —
      injected for tests. Must implement `revise/4`.
  """
  @spec revise(String.t(), String.t(), keyword()) :: KiroCockpit.CLI.result()
  def revise(id, request, opts) do
    case String.trim(request) do
      "" ->
        Result.error(:missing_argument, "revise requires a non-empty request", plan_id: id)

      cleaned_request ->
        do_revise(id, cleaned_request, opts)
    end
  end

  defp do_revise(id, request, opts) do
    {planner, planner_opts} = pop_planner(opts)
    {session, planner_opts} = Keyword.pop(planner_opts, :session)

    case planner.revise(session, id, request, planner_opts) do
      {:ok, new_plan} ->
        Result.ok(:plan_revised, %{
          plan: new_plan,
          plan_id: new_plan.id,
          previous_plan_id: id,
          status: new_plan.status,
          message: "Plan #{id} revised → new draft #{new_plan.id}"
        })

      {:error, :not_found} ->
        Result.error(:not_found, "plan not found: #{id}", plan_id: id)

      {:error, {:invalid_model_output, detail}} ->
        Result.error(
          :invalid_model_output,
          "model output could not be parsed: #{detail}",
          plan_id: id
        )

      {:error, {:invalid_plan, detail}} ->
        Result.error(:invalid_plan, "revised plan was invalid: #{detail}", plan_id: id)

      {:error, {:persist_failed, reason}} ->
        Result.error(:persist_failed, "could not persist revised plan: #{inspect(reason)}",
          plan_id: id
        )

      {:error, {:supersede_failed, reason}} ->
        Result.error(
          :supersede_failed,
          "revised plan was created but old plan could not be superseded: #{inspect(reason)}",
          plan_id: id
        )

      {:error, reason} ->
        Result.error(:revise_failed, "could not revise plan: #{inspect(reason)}", plan_id: id)
    end
  end

  @doc """
  Rejects a plan, optionally with a reason.

  Optional opts:

    * `:plans_module` (default `KiroCockpit.Plans`) — injected for
      tests. Must implement `reject_plan/2`.
  """
  @spec reject(String.t(), String.t() | nil, keyword()) :: KiroCockpit.CLI.result()
  def reject(id, reason, opts) do
    {plans_mod, _} = pop_plans(opts)

    case plans_mod.reject_plan(id, reason) do
      {:ok, plan} ->
        Result.ok(:plan_rejected, %{
          plan: plan,
          plan_id: plan.id,
          status: plan.status,
          reason: reason,
          message: "Plan #{plan.id} rejected" <> if(reason, do: " (reason: #{reason})", else: "")
        })

      {:error, :invalid_transition} ->
        Result.error(
          :invalid_transition,
          "plan #{id} is in a terminal status — cannot reject",
          plan_id: id
        )

      {:error, %Ecto.Changeset{} = changeset} ->
        Result.error(:reject_failed, "could not reject plan: invalid changeset",
          plan_id: id,
          changeset: changeset
        )

      {:error, reason_term} ->
        Result.error(:reject_failed, "could not reject plan: #{inspect(reason_term)}",
          plan_id: id
        )
    end
  rescue
    Ecto.NoResultsError ->
      Result.error(:not_found, "plan not found: #{id}", plan_id: id)
  end

  @doc """
  Marks an approved plan as `running`.

  This is an explicit status transition — it does NOT generate a new
  prompt and does NOT bypass approval. To go from draft to running,
  use `/plan approve` (which approves and dispatches the execution
  prompt) or `/plan approve` followed by `/plan run`.

  Optional opts:

    * `:plans_module` (default `KiroCockpit.Plans`) — injected for
      tests. Must implement `get_plan/1` and `update_status/3`.
  """
  @spec run(String.t(), keyword()) :: KiroCockpit.CLI.result()
  def run(id, opts) do
    {plans_mod, _} = pop_plans(opts)

    case plans_mod.get_plan(id) do
      nil ->
        Result.error(:not_found, "plan not found: #{id}", plan_id: id)

      %{status: "approved"} ->
        case plans_mod.update_status(id, "running", %{"source" => "cli"}) do
          {:ok, running_plan} ->
            Result.ok(:plan_running, %{
              plan: running_plan,
              plan_id: running_plan.id,
              status: running_plan.status,
              message: "Plan #{running_plan.id} transitioned to running"
            })

          {:error, reason} ->
            Result.error(:run_failed, "could not transition plan to running: #{inspect(reason)}",
              plan_id: id
            )
        end

      %{status: status} ->
        Result.error(
          :invalid_transition,
          "plan #{id} is in `#{status}` status — only `approved` plans can be run",
          plan_id: id,
          status: status
        )
    end
  end

  # ── Internals ───────────────────────────────────────────────────────

  defp pop_planner(opts), do: Keyword.pop(opts, :nano_planner_module, NanoPlanner)
  defp pop_plans(opts), do: Keyword.pop(opts, :plans_module, Plans)
end
