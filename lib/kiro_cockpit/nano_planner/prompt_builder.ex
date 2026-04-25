defmodule KiroCockpit.NanoPlanner.PromptBuilder do
  @moduledoc """
  Prompt template loading and interpolation for NanoPlanner (§6, §15).

  Pure, deterministic module — reads prompt templates from `priv/prompts`,
  interpolates `{{placeholder}}` values safely, and validates that no
  unreplaced placeholders remain in the output.

  ## Templates

    - **Runtime wrapper** (§6): `priv/prompts/nano_runtime_wrapper.md`
      Placeholders: `{{user_request}}`, `{{session_summary}}`,
      `{{project_snapshot}}`, `{{kiro_plan_summary}}`, `{{mode}}`

    - **Executor prompt** (§15): `priv/prompts/kiro_executor_system_prompt.md`
      Placeholders: `{{objective}}`, `{{phases}}`, `{{files}}`,
      `{{acceptance_criteria}}`, `{{risks}}`, `{{validation_steps}}`,
      `{{project_snapshot_hash}}`, `{{active_task}}`,
      `{{permission_policy}}`, `{{project_rules}}`, `{{gold_memories}}`

    - **System prompt**: `priv/prompts/nano_planner_system_prompt.md`
      Static system prompt with no placeholders.
  """

  @runtime_wrapper_path "priv/prompts/nano_runtime_wrapper.md"
  @executor_prompt_path "priv/prompts/kiro_executor_system_prompt.md"
  @system_prompt_path "priv/prompts/nano_planner_system_prompt.md"

  @placeholder_regex ~r/\{\{(\w+)\}\}/

  @type prompt_result :: {:ok, String.t()} | {:error, term()}

  # ── Public API ──────────────────────────────────────────────────────

  @doc """
  Builds the runtime planner prompt from a user request and context.

  Interpolates values into the `nano_runtime_wrapper.md` template (§6).

  ## Options

    - `:user_request` — the user's task description (required)
    - `:session_summary` — recent session history summary
    - `:project_snapshot` — `%ProjectSnapshot{}` struct or markdown string
    - `:kiro_plan_summary` — existing app plan summary text
    - `:mode` — planning mode (e.g. `"nano"`, `"nano_deep"`, `"nano_fix"`)

  Returns `{:ok, prompt}` or `{:error, reason}`.
  """
  @spec build_runtime_prompt(keyword() | map()) :: prompt_result()
  def build_runtime_prompt(opts) when is_map(opts), do: build_runtime_prompt(Map.to_list(opts))

  def build_runtime_prompt(opts) when is_list(opts) do
    with {:ok, template} <- load_template(@runtime_wrapper_path) do
      replacements = %{
        "user_request" => Keyword.get(opts, :user_request, ""),
        "session_summary" => Keyword.get(opts, :session_summary, ""),
        "project_snapshot" => format_snapshot(Keyword.get(opts, :project_snapshot)),
        "kiro_plan_summary" => Keyword.get(opts, :kiro_plan_summary, ""),
        "mode" => format_mode(Keyword.get(opts, :mode))
      }

      interpolate_and_validate(template, replacements)
    end
  end

  @doc """
  Builds the executor prompt from a validated approved plan and optional context.

  Interpolates values into the `kiro_executor_system_prompt.md` template (§15).

  ## Parameters

    - `plan` — a validated/normalized plan map (from `PlanSchema.validate!/1`)
    - `opts` — keyword list with optional context overrides:
      - `:active_task` — current Swarm task description
      - `:permission_policy` — current wrapper policy string
      - `:project_rules` — relevant project rules
      - `:gold_memories` — relevant Gold memory entries

  Returns `{:ok, prompt}` or `{:error, reason}`.
  """
  @spec build_executor_prompt(map(), keyword()) :: prompt_result()
  def build_executor_prompt(plan, opts \\ []) do
    with {:ok, template} <- load_template(@executor_prompt_path) do
      replacements = %{
        "objective" => get_plan_field(plan, :objective, ""),
        "phases" => format_phases(get_plan_field(plan, :phases, [])),
        "files" => format_files_from_plan(plan),
        "acceptance_criteria" =>
          format_list_field(get_plan_field(plan, :acceptance_criteria, [])),
        "risks" => format_risks(get_plan_field(plan, :risks, [])),
        "validation_steps" => format_validation_steps(plan),
        "project_snapshot_hash" => get_plan_field(plan, :project_snapshot_hash, ""),
        "active_task" => Keyword.get(opts, :active_task, ""),
        "permission_policy" => Keyword.get(opts, :permission_policy, ""),
        "project_rules" => Keyword.get(opts, :project_rules, ""),
        "gold_memories" => Keyword.get(opts, :gold_memories, "")
      }

      interpolate_and_validate(template, replacements)
    end
  end

  @doc """
  Returns the content of the NanoPlanner system prompt.

  This is a static prompt with no placeholders, used as the system message
  when invoking the planner model.
  """
  @spec system_prompt() :: {:ok, String.t()} | {:error, term()}
  def system_prompt do
    load_template(@system_prompt_path)
  end

  @doc """
  Returns the path to the NanoPlanner system prompt file.
  """
  @spec system_prompt_path() :: String.t()
  def system_prompt_path, do: @system_prompt_path

  @doc """
  Returns the path to the runtime wrapper template.
  """
  @spec runtime_wrapper_path() :: String.t()
  def runtime_wrapper_path, do: @runtime_wrapper_path

  @doc """
  Returns the path to the executor prompt template.
  """
  @spec executor_prompt_path() :: String.t()
  def executor_prompt_path, do: @executor_prompt_path

  @doc """
  Checks a rendered prompt for unreplaced `{{placeholder}}` patterns.

  Returns `:ok` if none found, or `{:error, {:unreplaced_placeholders, [names]}}`.
  """
  @spec check_unreplaced(String.t()) :: :ok | {:error, {:unreplaced_placeholders, [String.t()]}}
  def check_unreplaced(rendered) when is_binary(rendered) do
    unreplaced =
      Regex.scan(@placeholder_regex, rendered)
      |> Enum.map(fn [_, name] -> name end)
      |> Enum.uniq()
      |> Enum.sort()

    case unreplaced do
      [] -> :ok
      names -> {:error, {:unreplaced_placeholders, names}}
    end
  end

  # ── Template loading ────────────────────────────────────────────────

  defp load_template(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, {:template_not_found, path, reason}}
    end
  end

  # ── Interpolation ───────────────────────────────────────────────────

  defp interpolate_and_validate(template, replacements) do
    rendered = interpolate(template, replacements)

    case check_unreplaced(rendered) do
      :ok ->
        {:ok, rendered}

      {:error, {:unreplaced_placeholders, names}} ->
        {:error, {:unreplaced_placeholders, names}}
    end
  end

  defp interpolate(template, replacements) when is_binary(template) and is_map(replacements) do
    Regex.replace(@placeholder_regex, template, fn _match, name ->
      Map.get(replacements, name, "")
    end)
  end

  # ── Formatting helpers ─────────────────────────────────────────────

  defp format_snapshot(nil), do: "(no project snapshot available)"

  defp format_snapshot(%KiroCockpit.ProjectSnapshot{} = snapshot) do
    KiroCockpit.ProjectSnapshot.to_markdown(snapshot)
  end

  defp format_snapshot(snapshot) when is_binary(snapshot), do: snapshot

  defp format_snapshot(snapshot) when is_map(snapshot) do
    # Best-effort markdown rendering of a raw map
    entries =
      snapshot
      |> Enum.sort_by(fn {k, _v} -> to_string(k) end)
      |> Enum.map_join("\n", fn {k, v} -> "- **#{k}**: #{inspect(v)}" end)

    "# Project Snapshot\n\n#{entries}"
  end

  defp format_snapshot(_), do: "(invalid project snapshot)"

  defp format_mode(nil), do: "nano"
  defp format_mode(mode) when is_atom(mode), do: to_string(mode)
  defp format_mode(mode) when is_binary(mode), do: mode
  defp format_mode(_), do: "nano"

  defp format_phases(phases) when is_list(phases) do
    phases
    |> Enum.sort_by(&get_plan_field(&1, :number, 0))
    |> Enum.map_join("\n\n", fn phase ->
      number = get_plan_field(phase, :number, "?")
      title = get_plan_field(phase, :title, "Untitled Phase")
      steps_text = format_steps(get_plan_field(phase, :steps, []))

      "### Phase #{number}: #{title}\n#{steps_text}"
    end)
  end

  defp format_phases(_), do: "(no phases specified)"

  defp format_steps(steps) do
    steps
    |> Enum.with_index(1)
    |> Enum.map_join("\n", &format_step/1)
  end

  defp format_step({step, i}) do
    step_title = get_plan_field(step, :title, "Step #{i}")
    details = get_plan_field(step, :details) || get_plan_field(step, :description)
    perm = get_plan_field(step, :permission) || get_plan_field(step, :permission_level)

    parts = ["  #{i}. #{step_title}"]
    parts = if details, do: parts ++ ["     Details: #{details}"], else: parts
    parts = if perm, do: parts ++ ["     Permission: #{perm}"], else: parts
    Enum.join(parts, "\n")
  end

  defp format_files_from_plan(plan) do
    phases = get_plan_field(plan, :phases, [])

    files =
      phases
      |> Enum.flat_map(&extract_phase_files/1)
      |> Enum.uniq()
      |> Enum.sort()

    case files do
      [] -> "(no files identified)"
      list -> Enum.join(list, "\n")
    end
  end

  defp extract_phase_files(phase) do
    (get_plan_field(phase, :steps) || [])
    |> Enum.flat_map(&extract_step_files/1)
  end

  defp extract_step_files(step) do
    case get_plan_field(step, :files) do
      files when is_list(files) -> files
      files when is_map(files) -> Map.keys(files)
      _ -> []
    end
  end

  defp format_list_field(items) when is_list(items) do
    items
    |> Enum.map_join("\n", fn
      item when is_binary(item) -> "- #{item}"
      item -> "- #{inspect(item)}"
    end)
  end

  defp format_list_field(_), do: "(none specified)"

  defp format_risks(risks) when is_list(risks) do
    risks
    |> Enum.map_join("\n", fn
      %{"risk" => risk, "mitigation" => mit} ->
        "- **Risk**: #{risk}\n  **Mitigation**: #{mit}"

      risk when is_binary(risk) ->
        "- #{risk}"

      other ->
        "- #{inspect(other)}"
    end)
  end

  defp format_risks(_), do: "(no risks identified)"

  defp format_validation_steps(plan) do
    phases = get_plan_field(plan, :phases, [])

    validations =
      phases
      |> Enum.flat_map(fn phase ->
        (get_plan_field(phase, :steps) || [])
        |> Enum.filter(fn step -> get_plan_field(step, :validation) != nil end)
        |> Enum.map(fn step -> get_plan_field(step, :validation) end)
      end)

    case validations do
      [] -> "(no specific validation steps required)"
      steps -> Enum.map_join(steps, "\n", &"- #{&1}")
    end
  end

  # ── Key helpers ─────────────────────────────────────────────────────

  # Supports both atom and string keys, preferring atom.
  defp get_plan_field(map, key, default \\ nil) when is_map(map) do
    Map.get(map, key, Map.get(map, to_string(key), default))
  end
end
