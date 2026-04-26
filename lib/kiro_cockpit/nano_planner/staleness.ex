defmodule KiroCockpit.NanoPlanner.Staleness do
  @moduledoc """
  Fail-closed stale-plan context for NanoPlanner (§32.3).

  Before any mutating action (approve, run), compute the current project
  snapshot hash and compare it against the plan's stored hash. If they
  differ, the plan is stale. If the snapshot cannot be computed for any
  reason (missing project dir, session state unavailable, snapshot build
  failure), the operation **must** fail closed — i.e. block by default —
  rather than silently succeeding.

  ## Return values

    * `:ok`                          — hashes match; plan is fresh
    * `{:error, :stale_plan}`        — hashes differ; project changed
    * `{:error, :stale_plan_unknown}` — cannot determine staleness;
      the operation must be blocked

  ## Injectable modules

  The `:context_builder_module` opt (default `ContextBuilder`) allows
  swapping the snapshot builder for tests that need to simulate build
  failures.
  """

  alias KiroCockpit.NanoPlanner.ContextBuilder
  alias KiroCockpit.Plans.Plan

  @default_context_builder ContextBuilder

  @doc """
  Checks whether a plan is still fresh relative to the current project state.

  ## Parameters

    * `plan`        — a `%Plan{}` with a `project_snapshot_hash` field
    * `project_dir` — trusted path to the project root (must be a real dir)
    * `opts`        — keyword options

  ## Options

    * `:context_builder_module` — module implementing `build/1`
      (default `KiroCockpit.NanoPlanner.ContextBuilder`)

  Returns `:ok` when the current snapshot hash matches the plan hash,
  `{:error, :stale_plan}` on mismatch, or `{:error, :stale_plan_unknown}`
  when the snapshot cannot be computed.
  """
  @spec check(Plan.t(), String.t() | nil, keyword()) ::
          :ok | {:error, :stale_plan} | {:error, :stale_plan_unknown}
  def check(plan, project_dir, opts \\ [])

  def check(_plan, nil, _opts), do: {:error, :stale_plan_unknown}
  def check(_plan, "", _opts), do: {:error, :stale_plan_unknown}

  def check(plan, project_dir, opts) when is_binary(project_dir) do
    cb_mod = Keyword.get(opts, :context_builder_module, @default_context_builder)

    case cb_mod.build(staleness_opts(project_dir, opts)) do
      {:ok, current_snapshot} ->
        if current_snapshot.hash == plan.project_snapshot_hash do
          :ok
        else
          {:error, :stale_plan}
        end

      {:error, _reason} ->
        {:error, :stale_plan_unknown}
    end
  end

  @doc """
  Returns a trusted stale-plan context map suitable for injection into
  hook boundaries or action metadata.

  Returns `%{stale_plan?: false}` when the plan is fresh, or
  `%{stale_plan?: true, reason: atom}` when stale or unknown.

  The context is computed from trusted inputs only — it never trusts
  event payload/metadata for stale-plan state.
  """
  @spec trusted_context(Plan.t(), String.t() | nil, keyword()) :: map()
  def trusted_context(plan, project_dir, opts \\ []) do
    case check(plan, project_dir, opts) do
      :ok -> %{stale_plan?: false}
      {:error, reason} -> %{stale_plan?: true, reason: reason}
    end
  end

  # ── Private ──────────────────────────────────────────────────────────

  defp staleness_opts(project_dir, opts) do
    [
      project_dir: project_dir,
      max_tree_lines: Keyword.get(opts, :max_tree_lines),
      max_file_chars_per_file: Keyword.get(opts, :max_file_chars_per_file),
      max_total_context_chars: Keyword.get(opts, :max_total_context_chars)
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end
end
