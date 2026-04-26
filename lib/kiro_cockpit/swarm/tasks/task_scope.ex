defmodule KiroCockpit.Swarm.Tasks.TaskScope do
  @moduledoc """
  Permission and file-scope checks for swarm tasks.

  Per §27.5, each task category deterministically gates which actions
  are allowed. This module provides pure functions for:

  - Checking whether a permission is allowed by a task's category
  - Checking whether a file path is within a task's file scope
  - Checking whether an action is permitted by a task's permission scope

  All category gating decisions are delegated to `CategoryMatrix`,
  which is the single source of truth for the §32.2 permission matrix.

  ## Category gating (§27.5, §32.2)

      researching  → read, shell_read; external/subagent/memory_write: ask; writes: block
      planning     → read; external/subagent/memory_write: ask; writes/shell: block
      acting       → read: allow; all others: ask (policy/approval-gated)
      verifying    → read, shell_read: allow; shell_write/terminal/external/subagent/memory_write: ask; write/destructive: block
      debugging    → read, shell_read: allow; terminal/external/subagent/memory_write: ask; write/shell_write/destructive: block
      documenting  → read, shell_read; write/external/subagent/memory_write: ask; shell_write/terminal/destructive: block

  ## Composition rule (§4.5, §10.3)

  Permissions narrow, never widen. When composing permission layers,
  **intersect** — don't union. A mode granting `:read` to something
  a category denies is still denied.
  """

  alias KiroCockpit.Permissions
  alias KiroCockpit.Swarm.Tasks.{CategoryMatrix, Task}

  @type permission ::
          :read
          | :write
          | :shell_read
          | :shell_write
          | :terminal
          | :external
          | :destructive
          | :subagent
          | :memory_write

  @type permission_error :: :category_denied | :scope_denied | :needs_approval

  # -------------------------------------------------------------------
  # Permission checks
  # -------------------------------------------------------------------

  @doc """
  Checks whether a task's category and permission scope allow the given permission.

  Per §4.5/§10.3, permissions narrow: the category acts as a hard ceiling,
  and the task's `permission_scope` further restricts. The result is the
  **intersection** of category-allowed permissions and the task's permission_scope.

  Returns `{:ok, :allowed}` or `{:error, reason}`.

  The `:needs_approval` error indicates the category would allow the action
  with approval/policy, but no explicit approval signal was supplied. Pass
  `approved: true` in opts to treat `:ask` verdicts as allowed.

  Additional opts are forwarded to `CategoryMatrix.decision/3` for
  conditional promotions (e.g. `root_cause_stated: true`).

  ## Examples

      iex> task = %Task{category: "researching", permission_scope: ["read"]}
      iex> TaskScope.permission_allowed?(task, :read)
      {:ok, :allowed}

      iex> task = %Task{category: "researching", permission_scope: ["read"]}
      iex> TaskScope.permission_allowed?(task, :write)
      {:error, :category_denied}

      iex> task = %Task{category: "acting", permission_scope: ["write"]}
      iex> TaskScope.permission_allowed?(task, :write)
      {:error, :needs_approval}

      iex> task = %Task{category: "acting", permission_scope: ["write"]}
      iex> TaskScope.permission_allowed?(task, :write, approved: true)
      {:ok, :allowed}
  """
  @spec permission_allowed?(Task.t(), permission(), keyword()) ::
          {:ok, :allowed} | {:error, permission_error()}
  def permission_allowed?(
        %Task{category: category, permission_scope: scope},
        permission,
        opts \\ []
      )
      when is_atom(permission) do
    approved = approval_satisfies?(category, permission, opts)
    matrix_decision = CategoryMatrix.decision(category, permission, opts)

    matrix_decision.verdict
    |> permission_result(scope, permission, approved)
  end

  @doc """
  Returns the effective set of auto-allowed permissions for a task.

  This is the intersection of the category's `:allow` verdict permissions
  and the task's `permission_scope`. If `permission_scope` is empty, the
  auto-allowed set is used as-is (empty scope = unconstrained within
  auto-allowed permissions).

  Note: this only returns permissions with `:allow` verdict. Permissions
  with `:ask` verdict are NOT included — they require approval.
  """
  @spec effective_permissions(Task.t()) :: MapSet.t(permission())
  def effective_permissions(%Task{category: category, permission_scope: scope}) do
    allow_perms =
      category
      |> CategoryMatrix.auto_allowed_permissions()
      |> MapSet.new()

    if scope == [] do
      allow_perms
    else
      scope_atoms = scope |> Enum.map(&to_permission_atom/1) |> MapSet.new()
      MapSet.intersection(allow_perms, scope_atoms)
    end
  end

  @doc """
  Returns the permissions allowed by a category (auto-allowed only).

  This is the set of permissions with `:allow` verdict for the category.
  Useful for displaying what a category can do without approval.

  For the full hard ceiling (including `:ask` permissions), see
  `CategoryMatrix.non_blocked_permissions/1`.
  """
  @spec category_permissions(String.t()) :: MapSet.t(permission())
  def category_permissions(category) do
    category
    |> CategoryMatrix.auto_allowed_permissions()
    |> MapSet.new()
  end

  @doc """
  Returns the full hard ceiling for a category — all non-blocked permissions.

  This includes both `:allow` and `:ask` verdict permissions. These are
  the permissions a category could potentially use (with approval where
  needed).
  """
  @spec category_ceiling(String.t()) :: MapSet.t(permission())
  def category_ceiling(category) do
    category
    |> CategoryMatrix.non_blocked_permissions()
    |> MapSet.new()
  end

  @doc """
  Checks whether a category allows writes at all (before scope narrowing).

  Per §27.5/§32.2, `researching` and `planning` block writes entirely;
  `verifying` and `debugging` block writes by default (with conditional
  exceptions); only `acting` and `documenting` may write (subject to
  approval/scope).

  A category "allows writes" if the write verdict is not `:block`.
  """
  @spec category_allows_write?(String.t()) :: boolean()
  def category_allows_write?(category) do
    case CategoryMatrix.decision(category, :write) do
      %CategoryMatrix.Decision{verdict: :block} -> false
      %CategoryMatrix.Decision{} -> true
    end
  end

  # -------------------------------------------------------------------
  # File scope checks
  # -------------------------------------------------------------------

  @doc """
  Checks whether a file path is within a task's `files_scope`.

  File patterns support simple glob-style matching:

  - Exact match: `\"lib/kiro_cockpit/event_store.ex\"`
  - Directory prefix: `\"lib/kiro_cockpit/event_store/\"`
  - Glob wildcard: `\"test/**/*_test.exs\"` (simplified `**` matching)

  Returns `{:ok, :allowed}` or `{:error, :out_of_scope}`.

  If `files_scope` is empty, all files are allowed (unconstrained).
  """
  @spec file_allowed?(Task.t(), String.t()) ::
          {:ok, :allowed} | {:error, :out_of_scope}
  def file_allowed?(%Task{files_scope: scope}, path) when is_binary(path) do
    case normalize_relative_path(path) do
      {:ok, normalized_path} ->
        normalized_scope = normalize_scope_patterns(scope)

        cond do
          scope == [] ->
            {:ok, :allowed}

          Enum.any?(normalized_scope, &match_pattern?(&1, normalized_path)) ->
            {:ok, :allowed}

          true ->
            {:error, :out_of_scope}
        end

      :error ->
        {:error, :out_of_scope}
    end
  end

  def file_allowed?(_task, _path), do: {:error, :out_of_scope}

  @doc """
  Checks whether a task permits writing to the given file path.

  This is the write-specific composition helper for §27.5/§32.2 enforcement:
  it first evaluates the category/permission matrix through
  `permission_allowed?/3` (preserving `:needs_approval` for unresolved `:ask`
  verdicts), then enforces file scope with `file_allowed?/2`. Documenting tasks
  only treat documentation-scoped paths as eligible for the write approval gate;
  code paths remain category-denied by default.
  """
  @spec category_and_file_allowed?(Task.t(), String.t(), keyword()) ::
          {:ok, :allowed}
          | {:error, :category_denied | :scope_denied | :needs_approval | :out_of_scope}
  def category_and_file_allowed?(task, path, opts \\ []) do
    opts = opts |> Keyword.put_new(:path, path) |> maybe_mark_docs_scoped(path)

    case permission_allowed?(task, :write, opts) do
      {:ok, :allowed} -> file_allowed?(task, path)
      {:error, reason} -> {:error, reason}
    end
  end

  # -------------------------------------------------------------------
  # Dependency helpers
  # -------------------------------------------------------------------

  @doc """
  Checks whether all dependencies of a task are completed.

  A task with empty `depends_on` is always ready. Otherwise, every
  task ID in `depends_on` must appear in the `completed_ids` set.
  """
  @spec dependencies_met?(Task.t(), MapSet.t(String.t())) :: boolean()
  def dependencies_met?(%Task{depends_on: []}, _completed_ids), do: true

  def dependencies_met?(%Task{depends_on: depends_on}, completed_ids) do
    depends_on_set = MapSet.new(depends_on)
    MapSet.subset?(depends_on_set, completed_ids)
  end

  # -------------------------------------------------------------------
  # Private helpers
  # -------------------------------------------------------------------

  defp approval_satisfies?("acting", :write, opts) do
    Keyword.get(opts, :approved, false) and Keyword.get(opts, :policy_allows_write, false)
  end

  defp approval_satisfies?(:acting, :write, opts) do
    Keyword.get(opts, :approved, false) and Keyword.get(opts, :policy_allows_write, false)
  end

  defp approval_satisfies?(_category, _permission, opts), do: Keyword.get(opts, :approved, false)

  defp permission_result(:block, _scope, _permission, _approved), do: {:error, :category_denied}

  defp permission_result(:allow, scope, permission, _approved), do: check_scope(scope, permission)

  defp permission_result(:ask, scope, permission, true), do: check_scope(scope, permission)

  defp permission_result(:ask, scope, permission, false) do
    case check_scope(scope, permission) do
      {:ok, :allowed} -> {:error, :needs_approval}
      {:error, :scope_denied} -> {:error, :scope_denied}
    end
  end

  defp maybe_mark_docs_scoped(opts, path) do
    if CategoryMatrix.docs_scoped_path?(path) do
      Keyword.put_new(opts, :docs_scoped, true)
    else
      opts
    end
  end

  defp normalize_scope_patterns(scope) do
    Enum.flat_map(scope, &normalize_scope_pattern/1)
  end

  defp normalize_scope_pattern(pattern) when is_binary(pattern) do
    case normalize_relative_path(pattern) do
      {:ok, normalized} ->
        if String.ends_with?(pattern, "/"), do: [normalized <> "/"], else: [normalized]

      :error ->
        []
    end
  end

  defp normalize_scope_pattern(_pattern), do: []

  defp normalize_relative_path(path) when is_binary(path) do
    segments = Path.split(path)

    if Path.type(path) == :relative and not Enum.any?(segments, &(&1 in [".", ".."])) do
      {:ok, path |> Path.expand("/workspace") |> Path.relative_to("/workspace")}
    else
      :error
    end
  end

  @spec check_scope([String.t()], permission()) ::
          {:ok, :allowed} | {:error, :scope_denied}
  defp check_scope([], _permission), do: {:ok, :allowed}

  defp check_scope(scope, permission) do
    if permission_in_scope?(scope, permission) do
      {:ok, :allowed}
    else
      {:error, :scope_denied}
    end
  end

  defp permission_in_scope?(scope, permission) do
    Enum.any?(scope, fn s -> to_permission_atom(s) == permission end)
  end

  defp to_permission_atom(str) when is_binary(str) do
    case Permissions.parse_permission(str) do
      {:ok, perm} -> perm
      {:error, _} -> nil
    end
  end

  defp to_permission_atom(atom) when is_atom(atom) do
    if Permissions.valid_permission?(atom), do: atom, else: nil
  end

  # Simplified glob matching for file scope patterns.
  # Supports:
  #   - exact match: "lib/foo.ex"
  #   - directory prefix (trailing slash): "lib/kiro_cockpit/"
  #   - glob wildcard: "test/**/*_test.exs"
  #
  # The `**` matches zero or more path segments.
  # A trailing `/` in the pattern means "anything under this directory".
  @spec match_pattern?(String.t(), String.t()) :: boolean()
  defp match_pattern?(pattern, path) do
    cond do
      # Directory prefix: "lib/kiro_cockpit/" matches anything under that dir
      String.ends_with?(pattern, "/") ->
        String.starts_with?(path, pattern)

      # Glob pattern with `*` or `**`
      String.contains?(pattern, "*") ->
        glob_match?(pattern, path)

      # Exact match
      true ->
        pattern == path
    end
  end

  # Convert a glob pattern with `**` to a regex.
  # `**` → `.*?` (match any path segments including /)
  # `*` → `[^/]*?` (match within a single segment)
  defp glob_match?(pattern, path) do
    regex_str =
      pattern
      |> Regex.escape()
      |> String.replace("\\*\\*", ".*?")
      |> String.replace("\\*", "[^/]*?")
      |> then(&"^#{&1}$")

    case Regex.compile(regex_str) do
      {:ok, regex} -> Regex.match?(regex, path)
      {:error, _} -> false
    end
  end
end
