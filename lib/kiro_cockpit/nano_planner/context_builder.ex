defmodule KiroCockpit.NanoPlanner.ContextBuilder do
  @moduledoc """
  Read-only project discovery for NanoPlanner (plan2.md §8).

  Scans the project directory without ever writing to it, collects a
  compact context that includes:

    1. Root file tree (capped at `max_tree_lines`)
    2. Detected project stack/type
    3. Safe config file excerpts
    4. Existing `kiro_plan.md` summary
    5. Recent session history summary

  Enforces a context budget so the assembled markdown stays within
  `max_total_context_chars` (default 40 000). Each file excerpt is
  individually capped at `max_file_chars_per_file` (default 6 000).

  Returns a `%KiroCockpit.ProjectSnapshot{}` with a stable hash for
  stale-plan detection (§16).
  """

  alias KiroCockpit.ProjectSnapshot

  @default_max_tree_lines 200
  @default_max_file_chars_per_file 6_000
  @default_max_total_context_chars 40_000
  @max_fingerprint_entries 1_000
  @max_fingerprint_depth 8

  @safe_files ~w(
    README.md
    AGENTS.md
    AGENT.md
    package.json
    pyproject.toml
    mix.exs
    Cargo.toml
    go.mod
    deno.json
    pnpm-lock.yaml
    uv.lock
    config/config.exs
  )

  @safe_dirs ~w(.kiro)

  @safe_globs ~w(lib/*_web/router.ex)

  @ignored_entries MapSet.new(~w(
    .git
    _build
    deps
    node_modules
    cover
    coverage
    .elixir_ls
    .DS_Store
  ))

  @ignored_relative_dirs MapSet.new(~w(priv/static/cache))

  # Stack detection heuristics: {marker_file, stack_label}
  @stack_markers [
    {"mix.exs", "elixir/phoenix"},
    {"package.json", "node"},
    {"pyproject.toml", "python"},
    {"Cargo.toml", "rust"},
    {"go.mod", "go"},
    {"deno.json", "deno"}
  ]

  @type opts :: [
          {:project_dir, String.t()}
          | {:max_tree_lines, pos_integer()}
          | {:max_file_chars_per_file, pos_integer()}
          | {:max_total_context_chars, pos_integer()}
          | {:session_summary, String.t()}
        ]

  @doc """
  Builds a `ProjectSnapshot` for the given project directory.

  Options:

    * `:project_dir` — root of the project to scan (required)
    * `:max_tree_lines` — cap on tree listing lines (default 200)
    * `:max_file_chars_per_file` — cap per file excerpt (default 6 000)
    * `:max_total_context_chars` — total context budget (default 40 000)
    * `:session_summary` — optional session history summary to include

  Returns `{:ok, %ProjectSnapshot{}}` or `{:error, reason}`.
  """
  @spec build(opts()) :: {:ok, ProjectSnapshot.t()} | {:error, term()}
  def build(opts) do
    project_dir = Keyword.get(opts, :project_dir)

    max_tree_lines = Keyword.get(opts, :max_tree_lines, @default_max_tree_lines)
    max_file_chars = Keyword.get(opts, :max_file_chars_per_file, @default_max_file_chars_per_file)
    max_total = Keyword.get(opts, :max_total_context_chars, @default_max_total_context_chars)
    session_summary = Keyword.get(opts, :session_summary)

    with {:ok, project_dir} <- require_project_dir(project_dir),
         :ok <- validate_project_dir(project_dir) do
      root_tree = read_root_tree(project_dir, max_tree_lines)
      detected_stack = detect_stack(project_dir)
      config_excerpts = read_safe_files(project_dir, max_file_chars)
      existing_plans = read_kiro_plan(project_dir, max_file_chars)
      file_fingerprints = read_file_fingerprints(project_dir)

      snapshot =
        ProjectSnapshot.new(project_dir,
          root_tree: root_tree,
          detected_stack: detected_stack,
          config_excerpts: config_excerpts,
          file_fingerprints: file_fingerprints,
          existing_plans: existing_plans,
          session_summary: session_summary
        )

      finalize_snapshot(snapshot, max_total, max_file_chars)
    end
  end

  @doc """
  Lists top-level files and directories under `dir` up to `max_lines` lines.

  Per plan2.md §8 this is intentionally shallow: NanoPlanner needs a compact
  root overview, not an expensive recursive crawl. Known build/cache/vendor
  directories are omitted. Returns a newline-joined string and gracefully handles
  missing dirs.
  """
  @spec read_root_tree(String.t(), pos_integer()) :: String.t()
  def read_root_tree(dir, max_lines \\ @default_max_tree_lines) do
    case list_tree(dir) do
      {:ok, lines} ->
        lines
        |> Enum.take(max_lines)
        |> Enum.join("\n")

      {:error, _} ->
        "(could not read directory)"
    end
  end

  @doc """
  Detects the project stack from marker files in the project root.

  Returns a list of detected stack labels (e.g. `["elixir/phoenix", "node"]`).
  """
  @spec detect_stack(String.t()) :: [String.t()]
  def detect_stack(project_dir) do
    @stack_markers
    |> Enum.filter(fn {marker, _label} ->
      File.exists?(Path.join(project_dir, marker))
    end)
    |> Enum.map(fn {_marker, label} -> label end)
  end

  @doc """
  Reads safe config/rule files from the project directory.

  Reads each file in `@safe_files`, plus files under `@safe_dirs`,
  plus files matching `@safe_globs`. Each file content is truncated
  to `max_chars`. Returns a map of `{relative_path => content}`.
  """
  @spec read_safe_files(String.t(), pos_integer()) :: %{String.t() => String.t()}
  def read_safe_files(project_dir, max_chars \\ @default_max_file_chars_per_file) do
    safe_paths = collect_safe_paths(project_dir)

    safe_paths
    |> Enum.reduce(%{}, fn path, acc ->
      rel = Path.relative_to(path, project_dir)

      case read_and_truncate(path, max_chars) do
        {:ok, content} -> Map.put(acc, rel, content)
        :error -> acc
      end
    end)
  end

  @doc """
  Reads the `kiro_plan.md` file if present in the project root.

  Returns `nil` when absent. Content is truncated to `max_chars`.
  """
  @spec read_kiro_plan(String.t(), pos_integer()) :: String.t() | nil
  def read_kiro_plan(project_dir, max_chars \\ @default_max_file_chars_per_file) do
    path = Path.join(project_dir, "kiro_plan.md")

    case read_and_truncate(path, max_chars) do
      {:ok, content} -> content
      :error -> nil
    end
  end

  # --- Private helpers ---

  defp require_project_dir(nil), do: {:error, :project_dir_required}
  defp require_project_dir(""), do: {:error, :project_dir_required}
  defp require_project_dir(dir), do: {:ok, dir}

  defp validate_project_dir(dir) do
    cond do
      not File.exists?(dir) ->
        {:error, {:project_dir_not_found, dir}}

      not File.dir?(dir) ->
        {:error, {:project_dir_not_directory, dir}}

      true ->
        :ok
    end
  end

  defp list_tree(dir) do
    if File.dir?(dir) do
      lines =
        dir
        |> list_visible_entries()
        |> Enum.map(&format_root_entry(dir, &1))

      {:ok, lines}
    else
      {:error, :not_a_directory}
    end
  end

  defp list_visible_entries(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.reject(&ignored_entry?/1)
        |> Enum.sort()

      {:error, _} ->
        []
    end
  end

  defp format_root_entry(dir, entry) do
    path = Path.join(dir, entry)

    if directory_without_following_symlink?(path) do
      "#{entry}/"
    else
      entry
    end
  end

  defp read_file_fingerprints(project_dir) do
    project_dir
    |> collect_fingerprints("", 0, %{}, 0)
    |> elem(0)
  end

  defp collect_fingerprints(_dir, _relative_dir, _depth, acc, count)
       when count >= @max_fingerprint_entries do
    {acc, count}
  end

  defp collect_fingerprints(_dir, _relative_dir, depth, acc, count)
       when depth > @max_fingerprint_depth do
    {acc, count}
  end

  defp collect_fingerprints(dir, relative_dir, depth, acc, count) do
    dir
    |> list_visible_entries()
    |> Enum.reduce_while({acc, count}, fn entry, state ->
      reduce_fingerprint_entry(dir, relative_dir, depth, entry, state)
    end)
  end

  defp reduce_fingerprint_entry(_dir, _relative_dir, _depth, _entry, {acc, count})
       when count >= @max_fingerprint_entries do
    {:halt, {acc, count}}
  end

  defp reduce_fingerprint_entry(dir, relative_dir, depth, entry, {acc, count}) do
    entry_path = Path.join(dir, entry)
    relative_path = Path.join(relative_dir, entry)

    if ignored_relative_path?(relative_path) do
      {:cont, {acc, count}}
    else
      {:cont, fingerprint_entry(entry_path, relative_path, depth, acc, count)}
    end
  end

  defp fingerprint_entry(path, relative_path, depth, acc, count) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular} = stat} ->
        {Map.put(acc, relative_path, file_fingerprint(stat)), count + 1}

      {:ok, %File.Stat{type: :symlink} = stat} ->
        {Map.put(acc, relative_path, symlink_fingerprint(stat)), count + 1}

      {:ok, %File.Stat{type: :directory}} ->
        collect_fingerprints(path, relative_path, depth + 1, acc, count)

      {:ok, _stat} ->
        {acc, count}

      {:error, _reason} ->
        {acc, count}
    end
  end

  defp file_fingerprint(%File.Stat{} = stat) do
    "file:size=#{stat.size}:mtime=#{stat.mtime}"
  end

  defp symlink_fingerprint(%File.Stat{} = stat) do
    "symlink:size=#{stat.size}:mtime=#{stat.mtime}"
  end

  defp directory_without_following_symlink?(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> true
      _ -> false
    end
  end

  defp ignored_entry?(entry), do: MapSet.member?(@ignored_entries, entry)

  defp ignored_relative_path?(relative_path) do
    Enum.any?(@ignored_relative_dirs, fn ignored_dir ->
      relative_path == ignored_dir or String.starts_with?(relative_path, "#{ignored_dir}/")
    end)
  end

  defp collect_safe_paths(project_dir) do
    # 1. Top-level safe files
    top_level =
      @safe_files
      |> Enum.map(fn name -> Path.join(project_dir, name) end)
      |> Enum.filter(&safe_project_regular_file?(project_dir, &1))

    # 2. Files under safe directories (e.g. .kiro/*)
    dir_files =
      @safe_dirs
      |> Enum.flat_map(fn dir_name ->
        full_dir = Path.join(project_dir, dir_name)

        if directory_without_following_symlink?(full_dir) do
          collect_dir_files(full_dir)
        else
          []
        end
      end)

    # 3. Glob-matched safe files (e.g. lib/*_web/router.ex)
    glob_files =
      @safe_globs
      |> Enum.flat_map(fn glob ->
        project_dir
        |> Path.join(glob)
        |> Path.wildcard()
        |> Enum.filter(&safe_project_regular_file?(project_dir, &1))
      end)

    # Deduplicate by resolved path
    (top_level ++ dir_files ++ glob_files)
    |> Enum.uniq()
  end

  defp collect_dir_files(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.sort()
        |> Enum.flat_map(&dir_entry(dir, &1))

      {:error, _} ->
        []
    end
  end

  defp dir_entry(dir, entry) do
    path = Path.join(dir, entry)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> [path]
      {:ok, %File.Stat{type: :directory}} -> collect_dir_files(path)
      _ -> []
    end
  end

  defp safe_project_regular_file?(project_dir, path) do
    path
    |> Path.relative_to(project_dir)
    |> safe_relative_regular_file?(project_dir)
  end

  defp safe_relative_regular_file?(relative_path, project_dir) do
    path_parts = Path.split(relative_path)

    cond do
      Path.type(relative_path) == :absolute -> false
      Enum.any?(path_parts, &(&1 in [".", ".."])) -> false
      path_parts == [] -> false
      true -> regular_file_from_safe_parts?(project_dir, path_parts)
    end
  end

  defp regular_file_from_safe_parts?(base_dir, [filename]) do
    case File.lstat(Path.join(base_dir, filename)) do
      {:ok, %File.Stat{type: :regular}} -> true
      _ -> false
    end
  end

  defp regular_file_from_safe_parts?(base_dir, [dir | rest]) do
    case File.lstat(Path.join(base_dir, dir)) do
      {:ok, %File.Stat{type: :directory}} ->
        base_dir
        |> Path.join(dir)
        |> regular_file_from_safe_parts?(rest)

      _ ->
        false
    end
  end

  defp read_and_truncate(path, max_chars) do
    with {:ok, %File.Stat{type: :regular}} <- File.lstat(path),
         {:ok, content} <- File.read(path) do
      truncated = String.slice(content, 0, max_chars)
      {:ok, truncated}
    else
      _ -> :error
    end
  end

  defp enforce_budget(markdown, max_total) do
    if String.length(markdown) <= max_total do
      {:ok, markdown}
    else
      {:error, :budget_exceeded}
    end
  end

  defp finalize_snapshot(snapshot, max_total, max_file_chars) do
    markdown = ProjectSnapshot.to_markdown(snapshot)

    case enforce_budget(markdown, max_total) do
      {:ok, trimmed} ->
        {:ok, %{snapshot | total_chars: String.length(trimmed)}}

      {:error, :budget_exceeded} ->
        trim_to_budget(snapshot, max_total, max_file_chars)
    end
  end

  # When the full context exceeds the budget, progressively remove verbose
  # fields until the rendered snapshot fits. If even the minimal section
  # skeleton is too large for an unusually tiny budget, return an error rather
  # than claiming the budget was enforced.
  defp trim_to_budget(snapshot, max_total, max_file_chars) do
    candidates = [
      snapshot,
      %{snapshot | config_excerpts: truncate_excerpts(snapshot.config_excerpts, max_file_chars)},
      %{snapshot | config_excerpts: %{}},
      %{snapshot | config_excerpts: %{}, existing_plans: nil, session_summary: nil},
      %{
        snapshot
        | root_tree: "(omitted due to context budget)",
          config_excerpts: %{},
          existing_plans: nil,
          session_summary: nil
      }
    ]

    candidates
    |> Enum.map(&put_rendered_total_chars/1)
    |> Enum.find(&(&1.total_chars <= max_total))
    |> case do
      nil -> {:error, :budget_exceeded}
      trimmed_snapshot -> {:ok, trimmed_snapshot}
    end
  end

  defp truncate_excerpts(excerpts, max_file_chars) do
    half_chars = max(div(max_file_chars, 2), 500)

    excerpts
    |> Enum.map(fn {path, content} -> {path, String.slice(content, 0, half_chars)} end)
    |> Map.new()
  end

  defp put_rendered_total_chars(snapshot) do
    %{snapshot | total_chars: snapshot |> ProjectSnapshot.to_markdown() |> String.length()}
  end
end
