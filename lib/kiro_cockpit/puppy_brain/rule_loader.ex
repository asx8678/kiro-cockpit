defmodule KiroCockpit.PuppyBrain.RuleLoader do
  @moduledoc """
  Rule loading for PuppyBrain (§26.6, §25.3).

  Loads rule files in priority order (global → project → .kiro → extras),
  returning a structured list of `{source, content}` tuples.

  ## Priority order (later entries may extend, but never override hard policy)

      1. ~/.kiro_cockpit/AGENTS.md     (global user rules)
      2. ~/.kiro_cockpit/agent.md      (global user rules, alt name)
      3. <project>/AGENTS.md           (project-level rules)
      4. <project>/AGENT.md            (project-level rules, alt name)
      5. <project>/agents.md           (project-level rules, alt name)
      6. <project>/agent.md            (project-level rules, alt name)
      7. <project>/.kiro/rules/*       (kiro-specific rules)
      8. <project>/.kiro/steering/*    (kiro steering rules)
      9. <project>/README.md           (project readme)
     10. project config excerpts       (mix.exs, package.json, etc.)

  ## Hard policy invariant (§25.3)

  Project rules **cannot override hard policy invariants**. This module
  strips any rule content that attempts to disable or weaken the ten
  hard rules (R1–R10). The `load/2` function applies
  `enforce_hard_policy/1` to each loaded rule content, replacing
  violations with a `[HARD POLICY VIOLATION STRIPPED]` marker.

  ## Pure module

  No DB, no side effects beyond filesystem reads. All I/O is explicit
  via `File.read/1`.
  """

  @type source :: String.t()
  @type rule_content :: String.t()
  @type loaded_rule :: {source(), rule_content()}
  @type load_result :: {:ok, [loaded_rule()]} | {:error, term()}

  # Global rule files (resolved from home dir)
  @global_rule_files ~w(AGENTS.md agent.md)

  # Project-level rule files (resolved from project dir)
  @project_rule_files ~w(AGENTS.md AGENT.md agents.md agent.md)

  # Kiro-specific rule directories
  @kiro_rule_dirs ~w(.kiro/rules .kiro/steering)

  # Extra project context files
  @project_context_files ~w(README.md)

  @project_config_files ~w(mix.exs package.json pyproject.toml Cargo.toml go.mod)

  # Maximum rule file size (characters) — prevents loading enormous files
  @max_rule_chars 50_000

  # ── Hard policy patterns ────────────────────────────────────────────

  # Patterns that attempt to override or weaken hard policy invariants.
  # These are regex patterns matched against each rule content.
  # When matched, the offending line is replaced with a stripped marker.
  @hard_policy_override_patterns [
    # Attempts to disable or weaken "no mutating before approval" (R1)
    ~r/allow\s+(?:unapproved\s+)?(?:mutat\w+|writes?|edits?|shell\s+commands?)\s+before\s+(?:plan\s+)?approval/im,
    # Attempts to bypass task requirement (R2)
    ~r/(?:skip|bypass|ignore|disable)\s+(?:the\s+)?(?:task|swarm\s+task)\s+(?:requirement|enforcement|check|gate)/im,
    # Attempts to allow planning tasks to write (R3)
    ~r/planning\s+(?:tasks?\s+)?(?:may|can|should)\s+(?:write|edit|run\s+(?:mutating|shell))/im,
    # Attempts to allow debugging beyond diagnostics (R4)
    ~r/debugging\s+(?:tasks?\s+)?may\s+(?:write|edit|run\s+(?:non-?diagnostic|mutating|implement))/im,
    # Attempts to write outside plan scope (R5)
    ~r/acting\s+(?:tasks?\s+)?may\s+write\s+(?:outside|beyond)\s+(?:the\s+)?(?:approved\s+)?plan\s+scope/im,
    # Attempts to skip audit events (R9)
    ~r/(?:skip|bypass|suppress|discard)\s+(?:blocked\s+)?(?:actions?\s+)?(?:audit|events?)/im
  ]

  @strip_marker "[HARD POLICY VIOLATION STRIPPED]"

  # ── Public API ──────────────────────────────────────────────────────

  @doc """
  Loads all rule files for the given project directory.

  Returns `{:ok, rules}` where `rules` is a list of `{source, content}`
  tuples in priority order (global first, then project, then .kiro, then
  extras). Missing files are silently skipped. Each content is run
  through `enforce_hard_policy/1` to strip hard-policy violations.

  ## Options

    * `:home_dir` — override the home directory (default: `System.user_home()`)
    * `:max_rule_chars` — max chars per file (default: 50_000)
    * `:enforce_hard_policy` — whether to strip violations (default: `true`)
  """
  @spec load(String.t(), keyword()) :: load_result()
  def load(project_dir, opts \\ []) do
    home_dir = Keyword.get(opts, :home_dir, System.user_home())
    max_chars = Keyword.get(opts, :max_rule_chars, @max_rule_chars)
    enforce? = Keyword.get(opts, :enforce_hard_policy, true)

    with {:ok, _} <- validate_project_dir(project_dir) do
      rules =
        []
        |> load_global_rules(home_dir, max_chars)
        |> load_project_rules(project_dir, max_chars)
        |> load_kiro_rules(project_dir, max_chars)
        |> load_project_context(project_dir, max_chars)
        |> load_project_config(project_dir, max_chars)
        |> maybe_enforce_hard_policy(enforce?)

      {:ok, rules}
    end
  end

  @doc """
  Enforces hard policy invariants on rule content.

  Scans each line of each rule content for patterns that attempt to
  override or weaken the ten hard policy invariants (§25.3 R1–R10).
  Violating lines are replaced with `[HARD POLICY VIOLATION STRIPPED]`.

  Returns the rules list with stripped content.
  """
  @spec enforce_hard_policy([loaded_rule()]) :: [loaded_rule()]
  def enforce_hard_policy(rules) do
    Enum.map(rules, fn {source, content} ->
      {source, strip_violations(content)}
    end)
  end

  @doc """
  Returns the list of hard policy override regex patterns used for stripping.

  Useful for testing and debug UI display.
  """
  @spec hard_policy_patterns() :: [Regex.t()]
  def hard_policy_patterns, do: @hard_policy_override_patterns

  @doc """
  Checks if a single line violates hard policy.
  """
  @spec line_violates_hard_policy?(String.t()) :: boolean()
  def line_violates_hard_policy?(line) do
    Enum.any?(@hard_policy_override_patterns, &Regex.match?(&1, line))
  end

  @doc """
  Formats loaded rules into a single markdown block for prompt inclusion.
  """
  @spec to_prompt_section([loaded_rule()]) :: String.t()
  def to_prompt_section([]), do: "(no project rules loaded)"

  def to_prompt_section(rules) do
    sections =
      rules
      |> Enum.map(fn {source, content} ->
        "### Rules: #{source}\n#{content}"
      end)
      |> Enum.join("\n\n")

    "# Project Rules\n\n#{sections}"
  end

  # ── Private: validation ─────────────────────────────────────────────

  defp validate_project_dir(dir) do
    cond do
      is_nil(dir) or dir == "" -> {:error, :project_dir_required}
      not File.exists?(dir) -> {:error, {:project_dir_not_found, dir}}
      not File.dir?(dir) -> {:error, {:project_dir_not_directory, dir}}
      true -> {:ok, dir}
    end
  end

  # ── Private: loading helpers ────────────────────────────────────────

  defp load_global_rules(acc, home_dir, max_chars) do
    global_dir = Path.join(home_dir, ".kiro_cockpit")

    acc ++
      (@global_rule_files
       |> Enum.map(fn name -> {Path.join(global_dir, name), "global:#{name}"} end)
       |> load_files(max_chars))
  end

  defp load_project_rules(acc, project_dir, max_chars) do
    acc ++
      (@project_rule_files
       |> Enum.map(fn name -> {Path.join(project_dir, name), "project:#{name}"} end)
       |> load_files(max_chars))
  end

  defp load_kiro_rules(acc, project_dir, max_chars) do
    kiro_rules =
      @kiro_rule_dirs
      |> Enum.flat_map(fn dir_name ->
        full_dir = Path.join(project_dir, dir_name)

        if File.dir?(full_dir) do
          full_dir
          |> list_dir_sorted()
          |> Enum.map(fn file_name ->
            {Path.join(full_dir, file_name), "kiro:#{dir_name}/#{file_name}"}
          end)
        else
          []
        end
      end)
      |> load_files(max_chars)

    acc ++ kiro_rules
  end

  defp load_project_context(acc, project_dir, max_chars) do
    acc ++
      (@project_context_files
       |> Enum.map(fn name -> {Path.join(project_dir, name), "context:#{name}"} end)
       |> load_files(max_chars))
  end

  defp load_project_config(acc, project_dir, max_chars) do
    config_rules =
      @project_config_files
      |> Enum.map(fn name -> {Path.join(project_dir, name), "config:#{name}"} end)
      |> load_files(max_chars)
      # Config excerpts get truncated more aggressively
      |> Enum.map(fn {source, content} ->
        {source, String.slice(content, 0, div(max_chars, 5))}
      end)

    acc ++ config_rules
  end

  defp load_files(file_specs, max_chars) do
    file_specs
    |> Enum.filter(fn {path, _source} -> File.regular?(path) end)
    |> Enum.map(fn {path, source} ->
      case File.read(path) do
        {:ok, content} ->
          truncated = String.slice(content, 0, max_chars)
          {source, truncated}

        {:error, _} ->
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp list_dir_sorted(dir) do
    case File.ls(dir) do
      {:ok, entries} -> Enum.sort(entries)
      {:error, _} -> []
    end
  end

  # ── Private: hard policy enforcement ────────────────────────────────

  defp maybe_enforce_hard_policy(rules, true), do: enforce_hard_policy(rules)
  defp maybe_enforce_hard_policy(rules, false), do: rules

  defp strip_violations(content) do
    content
    |> String.split("\n")
    |> Enum.map(fn line ->
      if line_violates_hard_policy?(line), do: @strip_marker, else: line
    end)
    |> Enum.join("\n")
  end
end
