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

      snapshot =
        ProjectSnapshot.new(project_dir,
          root_tree: root_tree,
          detected_stack: detected_stack,
          config_excerpts: config_excerpts,
          existing_plans: existing_plans,
          session_summary: session_summary
        )

      finalize_snapshot(snapshot, max_total, max_file_chars)
    end
  end

  @doc """
  Lists files and directories under `dir` up to `max_lines` lines.

  Uses `File.ls!/1` recursively, producing a simple indented tree.
  Returns a newline-joined string. Gracefully handles missing dirs.
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
      lines = do_list_tree(dir, "", 0)
      {:ok, lines}
    else
      {:error, :not_a_directory}
    end
  end

  defp do_list_tree(dir, prefix, depth) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.sort()
        |> Enum.flat_map(&tree_entry(dir, prefix, depth, &1))

      {:error, _} ->
        []
    end
  end

  defp tree_entry(dir, prefix, depth, entry) do
    path = Path.join(dir, entry)
    line = "#{prefix}#{entry}"

    if File.dir?(path) and depth < 10 do
      [line | do_list_tree(path, "#{prefix}  ", depth + 1)]
    else
      [line]
    end
  end

  defp collect_safe_paths(project_dir) do
    # 1. Top-level safe files
    top_level =
      @safe_files
      |> Enum.map(fn name -> Path.join(project_dir, name) end)
      |> Enum.filter(&File.regular?/1)

    # 2. Files under safe directories (e.g. .kiro/*)
    dir_files =
      @safe_dirs
      |> Enum.flat_map(fn dir_name ->
        full_dir = Path.join(project_dir, dir_name)

        if File.dir?(full_dir) do
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
        |> Enum.filter(&File.regular?/1)
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

    cond do
      File.regular?(path) -> [path]
      File.dir?(path) -> collect_dir_files(path)
      true -> []
    end
  end

  defp read_and_truncate(path, max_chars) do
    case File.read(path) do
      {:ok, content} ->
        truncated = String.slice(content, 0, max_chars)
        {:ok, truncated}

      {:error, _} ->
        :error
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
