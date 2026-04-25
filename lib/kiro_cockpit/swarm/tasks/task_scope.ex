defmodule KiroCockpit.Swarm.Tasks.TaskScope do
  @moduledoc """
  Permission and file-scope checks for swarm tasks.

  Per §27.5, each task category deterministically gates which actions
  are allowed. This module provides pure functions for:

  - Checking whether a permission is allowed by a task's category
  - Checking whether a file path is within a task's file scope
  - Checking whether an action is permitted by a task's permission scope

  ## Category gating (§27.5)

      researching  → read, grep, config, docs/search if approved
      planning     → read, grep, skills, ask user, read-only reviewers
      acting       → actions inside active task permission scope
      verifying    → tests, diffs, logs, reads, non-mutating shell
      debugging    → read, grep, git diff/log, logs, targeted diagnostics
      documenting  → read, doc writes if approved

  ## Composition rule (§4.5, §10.3)

  Permissions narrow, never widen. When composing permission layers,
  **intersect** — don't union. A mode granting `:read` to something
  a category denies is still denied.
  """

  alias KiroCockpit.Swarm.Tasks.Task

  @type permission ::
          :read | :write | :shell_read | :shell_write | :terminal | :external | :destructive

  # Category → set of permissions allowed by that category alone.
  # These are the *maximum* — the task's permission_scope may further narrow.
  @category_permissions %{
    "researching" => MapSet.new([:read, :shell_read]),
    "planning" => MapSet.new([:read, :shell_read]),
    "acting" => MapSet.new([:read, :write, :shell_read, :shell_write]),
    "verifying" => MapSet.new([:read, :shell_read]),
    "debugging" => MapSet.new([:read, :shell_read]),
    "documenting" => MapSet.new([:read, :write])
  }

  # Categories that allow write-level actions (subject to permission_scope narrowing).
  @write_capable_categories ~w(acting documenting)

  # -------------------------------------------------------------------
  # Permission checks
  # -------------------------------------------------------------------

  @doc """
  Checks whether a task's category and permission scope allow the given permission.

  Per §4.5/§10.3, permissions narrow: the category acts as a hard ceiling,
  and the task's `permission_scope` further restricts. The result is the
  **intersection** of category-allowed permissions and the task's permission_scope.

  Returns `{:ok, :allowed}` or `{:error, reason}`.

  ## Examples

      iex> task = %Task{category: "researching", permission_scope: ["read"]}
      iex> TaskScope.permission_allowed?(task, :read)
      {:ok, :allowed}

      iex> task = %Task{category: "researching", permission_scope: ["read"]}
      iex> TaskScope.permission_allowed?(task, :write)
      {:error, :category_denied}
  """
  @spec permission_allowed?(Task.t(), permission()) ::
          {:ok, :allowed} | {:error, :category_denied | :scope_denied}
  def permission_allowed?(%Task{category: category, permission_scope: scope}, permission)
      when is_atom(permission) do
    category_perms = Map.get(@category_permissions, category, MapSet.new())

    cond do
      not MapSet.member?(category_perms, permission) ->
        {:error, :category_denied}

      scope != [] and not permission_in_scope?(scope, permission) ->
        {:error, :scope_denied}

      true ->
        {:ok, :allowed}
    end
  end

  @doc """
  Returns the effective set of allowed permissions for a task.

  This is the intersection of the category's hard ceiling and the
  task's `permission_scope`. If `permission_scope` is empty, the
  category ceiling is used as-is (empty scope = unconstrained within
  category — the broadest interpretation).
  """
  @spec effective_permissions(Task.t()) :: MapSet.t(permission())
  def effective_permissions(%Task{category: category, permission_scope: scope}) do
    category_perms = Map.get(@category_permissions, category, MapSet.new())

    if scope == [] do
      category_perms
    else
      scope_atoms = scope |> Enum.map(&to_permission_atom/1) |> MapSet.new()
      MapSet.intersection(category_perms, scope_atoms)
    end
  end

  @doc """
  Returns the permissions allowed by a category (hard ceiling).

  Useful for displaying what a category can do before a task is created.
  """
  @spec category_permissions(String.t()) :: MapSet.t(permission())
  def category_permissions(category) do
    Map.get(@category_permissions, category, MapSet.new())
  end

  @doc """
  Checks whether a category allows writes at all (before scope narrowing).

  Per §27.5, `researching` and `planning` block writes entirely;
  `debugging` and `verifying` block writes; only `acting` and
  `documenting` may write (subject to scope).
  """
  @spec category_allows_write?(String.t()) :: boolean()
  def category_allows_write?(category) when category in @write_capable_categories, do: true
  def category_allows_write?(_category), do: false

  # -------------------------------------------------------------------
  # File scope checks
  # -------------------------------------------------------------------

  @doc """
  Checks whether a file path is within a task's `files_scope`.

  File patterns support simple glob-style matching:

  - Exact match: `"lib/kiro_cockpit/event_store.ex"`
  - Directory prefix: `"lib/kiro_cockpit/event_store/"`
  - Glob wildcard: `"test/**/*_test.exs"` (simplified `**` matching)

  Returns `{:ok, :allowed}` or `{:error, :out_of_scope}`.

  If `files_scope` is empty, all files are allowed (unconstrained).
  """
  @spec file_allowed?(Task.t(), String.t()) ::
          {:ok, :allowed} | {:error, :out_of_scope}
  def file_allowed?(%Task{files_scope: []}, _path), do: {:ok, :allowed}

  def file_allowed?(%Task{files_scope: scope}, path) when is_binary(path) do
    if Enum.any?(scope, &match_pattern?(&1, path)) do
      {:ok, :allowed}
    else
      {:error, :out_of_scope}
    end
  end

  @doc """
  Checks whether a task's category permits writing to the given file path.

  Combines `category_allows_write?/1` with `file_allowed?/2`.
  """
  @spec category_and_file_allowed?(Task.t(), String.t()) ::
          {:ok, :allowed} | {:error, :category_denied | :out_of_scope}
  def category_and_file_allowed?(%Task{category: category} = task, path) do
    if category_allows_write?(category) do
      case file_allowed?(task, path) do
        {:ok, :allowed} -> {:ok, :allowed}
        {:error, :out_of_scope} -> {:error, :out_of_scope}
      end
    else
      {:error, :category_denied}
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

  defp permission_in_scope?(scope, permission) do
    Enum.any?(scope, fn s -> to_permission_atom(s) == permission end)
  end

  @permission_atoms %{
    "read" => :read,
    "write" => :write,
    "shell_read" => :shell_read,
    "shell_write" => :shell_write,
    "terminal" => :terminal,
    "external" => :external,
    "destructive" => :destructive
  }

  @spec to_permission_atom(String.t()) :: permission() | nil
  defp to_permission_atom(str) when is_binary(str) do
    Map.get(@permission_atoms, str)
  end

  defp to_permission_atom(atom) when is_atom(atom) do
    if Map.has_key?(@permission_atoms, Atom.to_string(atom)), do: atom, else: nil
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
