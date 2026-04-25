defmodule KiroCockpit.Permissions do
  @moduledoc """
  Permission prediction, policy gating, and stale-plan hash detection.

  Pure, deterministic module — no DB, no UI, no side effects.

  ## Permission levels (escalation order)

      :read         – safe project inspection
      :write        – file creation/modification
      :shell_read   – read-only commands (git status, ls, mix test --dry-run)
      :shell_write  – commands that generate files, install deps, migrate DB
      :terminal     – long-running interactive process
      :external     – network, MCP, docs/search, browser
      :destructive  – rm, reset, kill, overwrites, data deletion

  ## Policies

      :read_only            – only `:read` allowed
      :auto_allow_readonly  – `:read` and `:shell_read` auto-approved; rest need approval
      :auto_allow_all       – everything auto-approved (use with caution)

  ## Stale-plan hash gate

  Compute a stable snapshot hash from project metadata and compare it with the
  hash stored when the plan was created. Mismatch → plan is stale → caller
  should regenerate by default.
  """

  @escalation_order [:read, :write, :shell_read, :shell_write, :terminal, :external, :destructive]

  # Explicit string→atom mapping so arbitrary LLM strings never pollute the atom table.
  @string_to_permission %{
    "read" => :read,
    "write" => :write,
    "shell_read" => :shell_read,
    "shell_write" => :shell_write,
    "terminal" => :terminal,
    "external" => :external,
    "destructive" => :destructive,
    "shell" => :shell_write,
    "shell_readonly" => :shell_read
  }

  @type permission ::
          :read | :write | :shell_read | :shell_write | :terminal | :external | :destructive
  @type policy :: :read_only | :auto_allow_readonly | :auto_allow_all
  @type policy_check_result :: :ok | {:needs_approval, [permission()]}

  # ── Escalation helpers ───────────────────────────────────────────────

  @doc "Returns the canonical escalation order of permission levels."
  @spec escalation_order() :: [permission()]
  def escalation_order, do: @escalation_order

  @doc "Returns the numeric rank (0-based) of a permission in the escalation order."
  @spec escalation_rank(permission() | String.t()) :: non_neg_integer()
  def escalation_rank(perm) when perm in @escalation_order do
    Enum.find_index(@escalation_order, &(&1 == perm))
  end

  def escalation_rank(perm) when is_binary(perm) do
    perm |> normalize_permission() |> escalation_rank()
  end

  @doc "Returns the set of permissions at or below the given level in escalation order."
  @spec at_or_below(permission()) :: [permission()]
  def at_or_below(perm) when perm in @escalation_order do
    Enum.take(@escalation_order, escalation_rank(perm) + 1)
  end

  # ── Normalization ────────────────────────────────────────────────────

  @doc """
  Normalizes a permission value to its canonical atom form.

  Accepts atoms, strings, and common aliases:
    - `"shell"` → `:shell_write`
    - `"shell_readonly"` → `:shell_read`
  """
  @spec normalize_permission(atom() | String.t()) :: permission()
  def normalize_permission(perm) when perm in @escalation_order, do: perm

  def normalize_permission(perm) when is_binary(perm) do
    case Map.get(@string_to_permission, String.downcase(perm)) do
      nil -> :read
      atom -> atom
    end
  end

  def normalize_permission(perm) when is_atom(perm) do
    if perm in @escalation_order, do: perm, else: :read
  end

  @doc "Normalizes a list of permissions (deduped, sorted by escalation order)."
  @spec normalize_permissions([atom() | String.t()]) :: [permission()]
  def normalize_permissions(perms) when is_list(perms) do
    perms
    |> Enum.map(&normalize_permission/1)
    |> Enum.uniq()
    |> Enum.sort_by(&escalation_rank/1)
  end

  # ── Permission prediction ────────────────────────────────────────────

  @doc """
  Predicts all permissions required by a plan map.

  Walks the plan structure collecting permissions from:
    - Top-level `permissions_needed` / `:permissions_needed`
    - Each phase's `permissions_needed` / `:permissions_needed`
    - Each step's `permission`, `permission_level`, `permissions`,
      `permissions_needed`, and heuristic from `files`/`validation`/`details`

  Returns a deduplicated, escalation-sorted list of permission atoms.
  """
  @spec predict_permissions(map()) :: [permission()]
  def predict_permissions(plan) when is_map(plan) do
    plan
    |> collect_all_permissions()
    |> normalize_permissions()
    |> ensure_read_baseline()
  end

  # Any plan that requires permissions implicitly requires :read
  # ("Begin with read-only inspection, then proceed phase by phase.")
  defp ensure_read_baseline([]), do: []

  defp ensure_read_baseline(perms) do
    if :read in perms, do: perms, else: [:read | perms]
  end

  defp collect_all_permissions(plan) do
    top_level = extract_permissions_from_map(plan)
    phases = get_field(plan, :phases) || get_field(plan, "phases") || []

    phase_perms =
      Enum.flat_map(List.wrap(phases), fn phase ->
        phase_perms = extract_permissions_from_map(phase)
        steps = get_field(phase, :steps) || get_field(phase, "steps") || []

        step_perms =
          Enum.flat_map(List.wrap(steps), fn step ->
            extract_permissions_from_step(step)
          end)

        phase_perms ++ step_perms
      end)

    top_level ++ phase_perms
  end

  defp extract_permissions_from_map(map) when is_map(map) do
    explicit =
      [:permissions_needed, :permissions, :permission, :permission_level]
      |> Enum.flat_map(fn key ->
        case get_field(map, key) do
          nil -> []
          perm when is_list(perm) -> perm
          perm -> [perm]
        end
      end)

    explicit ++ heuristic_permissions_from_map(map)
  end

  defp extract_permissions_from_map(_), do: []

  defp heuristic_permissions_from_map(map) do
    perms = []

    perms =
      if has_writing_content?(map) do
        [:write | perms]
      else
        perms
      end

    perms =
      if has_shell_content?(map) do
        [:shell_write | perms]
      else
        perms
      end

    perms
  end

  defp has_writing_content?(map) do
    files = get_field(map, :files) || get_field(map, "files")
    validation = get_field(map, :validation) || get_field(map, "validation")
    details = get_field(map, :details) || get_field(map, "details")

    write_keywords = ~w(create modify write add implement update edit insert generate)

    has_keyword_in?(files, write_keywords) or
      has_keyword_in?(validation, write_keywords) or
      has_keyword_in?(details, write_keywords)
  end

  defp has_shell_content?(map) do
    validation = get_field(map, :validation) || get_field(map, "validation")
    details = get_field(map, :details) || get_field(map, "details")

    shell_keywords = ~w(run execute command shell test migrate install build)

    has_keyword_in?(validation, shell_keywords) or
      has_keyword_in?(details, shell_keywords)
  end

  defp has_keyword_in?(nil, _keywords), do: false

  defp has_keyword_in?(value, keywords) when is_list(value) do
    value_str = Enum.join(value, " ")
    has_keyword_in?(value_str, keywords)
  end

  defp has_keyword_in?(value, keywords) when is_binary(value) do
    lower = String.downcase(value)
    Enum.any?(keywords, &String.contains?(lower, &1))
  end

  defp has_keyword_in?(_, _), do: false

  defp extract_permissions_from_step(step) when is_map(step) do
    explicit = extract_permissions_from_map(step)

    # A step with no explicit permissions and no heuristic hits is a read step
    if explicit == [], do: [:read], else: explicit
  end

  defp extract_permissions_from_step(_), do: []

  # ── Policy gating ────────────────────────────────────────────────────

  @doc """
  Returns the set of permissions auto-allowed under a given policy.
  """
  @spec auto_allowed(policy()) :: [permission()]
  def auto_allowed(:read_only), do: [:read]
  def auto_allowed(:auto_allow_readonly), do: [:read, :shell_read]
  def auto_allowed(:auto_allow_all), do: escalation_order()

  @doc """
  Checks whether a plan's required permissions exceed the current policy.

  Returns `:ok` if all permissions are auto-allowed, or
  `{:needs_approval, permissions}` listing the permissions requiring approval.
  """
  @spec check_policy([permission()], policy()) :: policy_check_result()
  def check_policy(required_perms, policy) when is_list(required_perms) and is_atom(policy) do
    allowed = auto_allowed(policy) |> MapSet.new()
    required = MapSet.new(required_perms)
    needing_approval = MapSet.difference(required, allowed) |> MapSet.to_list()

    case needing_approval do
      [] -> :ok
      perms -> {:needs_approval, Enum.sort_by(perms, &escalation_rank/1)}
    end
  end

  @doc """
  Convenience: returns `true` if any permission in `required` needs approval
  under the given policy.
  """
  @spec requires_approval?([permission()], policy()) :: boolean()
  def requires_approval?(required_perms, policy) do
    match?({:needs_approval, _}, check_policy(required_perms, policy))
  end

  @doc """
  Full gate check: predicts permissions from a plan and checks against policy.

  Returns `{:ok, permissions}` if all clear, or
  `{:needs_approval, permissions, needing_approval}` tuple.
  """
  @spec gate_plan(map(), policy()) ::
          {:ok, [permission()]} | {:needs_approval, [permission()], [permission()]}
  def gate_plan(plan, policy) do
    required = predict_permissions(plan)

    case check_policy(required, policy) do
      :ok -> {:ok, required}
      {:needs_approval, needing} -> {:needs_approval, required, needing}
    end
  end

  # ── Stale-plan hash gate ─────────────────────────────────────────────

  @doc """
  Computes a stable hash from a project snapshot map.

  Expects a map with keys like `:tree`, `:config`, `:files`, `:metadata`,
  or any combination. The hash is deterministic and order-independent for
  map keys. Uses `:erlang.phash2` for portability and speed.

  Returns a non-negative integer hash.
  """
  @spec compute_snapshot_hash(map()) :: non_neg_integer()
  def compute_snapshot_hash(snapshot) when is_map(snapshot) do
    normalized = normalize_snapshot_for_hash(snapshot)
    :erlang.phash2(normalized)
  end

  defp normalize_snapshot_for_hash(snapshot) do
    snapshot
    |> Enum.sort_by(fn {k, _v} -> to_string(k) end)
    |> Enum.map(fn {k, v} -> {to_string(k), normalize_hash_value(v)} end)
  end

  defp normalize_hash_value(v) when is_map(v) do
    v
    |> Enum.sort_by(fn {k, _v} -> to_string(k) end)
    |> Enum.map(fn {k, val} -> {to_string(k), normalize_hash_value(val)} end)
  end

  defp normalize_hash_value(v) when is_list(v) do
    Enum.map(v, &normalize_hash_value/1)
  end

  defp normalize_hash_value(v) when is_atom(v), do: to_string(v)
  # Preserve original string case so hash-sensitive values (e.g. commit SHAs,
  # file paths on case-sensitive filesystems) produce distinct hashes.
  defp normalize_hash_value(v) when is_binary(v), do: v
  defp normalize_hash_value(v) when is_number(v), do: v
  defp normalize_hash_value(v), do: inspect(v)

  @doc """
  Compares a current snapshot hash against a plan's stored snapshot hash.

  Returns `:fresh` if they match, `:stale` if they differ, or `:no_baseline`
  if the plan has no stored hash (first run / legacy plan).

  ## Parameters

    - `current_hash` — hash of the current project state
    - `plan` — plan map that may contain `:project_snapshot_hash` or
      `"project_snapshot_hash"` key

  ## Default behavior

  Stale plans should be **regenerated** by default. The caller decides the
  actual UX; this function just provides the signal.
  """
  @spec stale?(non_neg_integer(), map()) :: :fresh | :stale | :no_baseline
  def stale?(current_hash, plan) when is_integer(current_hash) and is_map(plan) do
    case get_field(plan, :project_snapshot_hash) || get_field(plan, "project_snapshot_hash") do
      nil -> :no_baseline
      ^current_hash -> :fresh
      _other -> :stale
    end
  end

  @doc """
  Convenience: computes a snapshot hash and checks staleness in one call.

  Returns `{:fresh, hash}`, `{:stale, hash, plan_hash}`, or `{:no_baseline, hash}`.
  """
  @spec check_stale(map(), map()) ::
          {:fresh, non_neg_integer()}
          | {:stale, non_neg_integer(), non_neg_integer()}
          | {:no_baseline, non_neg_integer()}
  def check_stale(current_snapshot, plan) when is_map(current_snapshot) and is_map(plan) do
    current_hash = compute_snapshot_hash(current_snapshot)

    case stale?(current_hash, plan) do
      :fresh -> {:fresh, current_hash}
      :stale -> {:stale, current_hash, get_plan_hash(plan)}
      :no_baseline -> {:no_baseline, current_hash}
    end
  end

  defp get_plan_hash(plan) do
    get_field(plan, :project_snapshot_hash) || get_field(plan, "project_snapshot_hash")
  end

  # ── Key normalization helper ─────────────────────────────────────────

  defp get_field(map, key) when is_map(map) do
    # Use Map.get/3 default instead of || to preserve false values.
    Map.get(map, key, Map.get(map, to_string(key)))
  end
end
