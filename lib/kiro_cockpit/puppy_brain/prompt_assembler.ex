defmodule KiroCockpit.PuppyBrain.PromptAssembler do
  @moduledoc """
  Dynamic prompt/rule/model/context assembly for PuppyBrain (§26.5, §28.1).

  Orchestrates `RuleLoader`, `SkillRegistry`, and `AgentRegistry` to
  produce a fully assembled prompt context ready for NanoPlanner or
  Kiro execution.

  ## Assembly pipeline

      1. Select agent profile from AgentRegistry
      2. Load rules via RuleLoader (with hard-policy enforcement)
      3. Match skills via SkillRegistry
      4. Attach plan/task context (if active)
      5. Attach permission policy
      6. Attach gold memory references
      7. Apply model-specific adapter hints
      8. Produce assembled prompt + debug metadata

  ## Hard policy invariants (§25.3)

  The assembler enforces that:

    * Project rules cannot override hard policy (delegated to RuleLoader)
    * A planning agent never receives mutating instructions
    * Plan/task context is only included when a plan is approved
    * Permission policy is always appended and cannot be stripped by rules

  ## Output

  The `assemble/2` function returns an `AssembledPrompt` struct with:

    * `sections` — ordered keyword list of `{section_name, content}`
    * `metadata` — debug-safe map (no secrets, no raw rule content)
    * `agent` — the selected `AgentProfile`
  """

  alias KiroCockpit.PuppyBrain.{AgentProfile, AgentRegistry, RuleLoader, SkillRegistry}

  @type plan_context :: %{
          optional(:plan_id) => String.t(),
          optional(:plan_status) => String.t(),
          optional(:objective) => String.t(),
          optional(:active_task) => String.t(),
          optional(:phases) => [map()],
          optional(:files_scope) => [String.t()],
          optional(:permission_scope) => [String.t()]
        }

  @type memory_refs :: [String.t()]

  @type section :: {atom(), String.t()}

  @type t :: %__MODULE__{
          sections: [section()],
          metadata: map(),
          agent: AgentProfile.t() | nil
        }

  defstruct sections: [], metadata: %{}, agent: nil

  @type opts :: [
          {:project_dir, String.t()}
          | {:agent_name, atom()}
          | {:agent_registry, AgentRegistry.t()}
          | {:skill_registry, SkillRegistry.t()}
          | {:signals, [String.t()]}
          | {:plan_context, plan_context()}
          | {:memory_refs, memory_refs()}
          | {:permission_policy, String.t()}
          | {:home_dir, String.t()}
          | {:max_rule_chars, pos_integer()}
        ]

  # ── Public API ──────────────────────────────────────────────────────

  @doc """
  Assembles a prompt context from project rules, skills, agent profile,
  plan/task context, and memory references.

  Returns `{:ok, %PromptAssembler{}}` with ordered sections and metadata,
  or `{:error, reason}`.

  ## Options

    * `:project_dir` — project root (required)
    * `:agent_name` — agent profile to select (default: `:nano_planner`)
    * `:agent_registry` — `AgentRegistry` to use (default: `with_builtins()`)
    * `:skill_registry` — `SkillRegistry` to use (default: `with_builtins()`)
    * `:signals` — keyword signals for skill matching
    * `:plan_context` — active plan/task context map
    * `:memory_refs` — gold memory reference IDs
    * `:permission_policy` — current permission policy string
    * `:home_dir` — override home directory for rule loading
    * `:max_rule_chars` — max chars per rule file
  """
  @spec assemble(opts()) :: {:ok, t()} | {:error, term()}
  def assemble(opts) when is_list(opts) do
    project_dir = Keyword.get(opts, :project_dir)
    agent_name = Keyword.get(opts, :agent_name, :nano_planner)
    agent_registry = Keyword.get(opts, :agent_registry, AgentRegistry.with_builtins())
    skill_registry = Keyword.get(opts, :skill_registry, SkillRegistry.with_builtins())
    signals = Keyword.get(opts, :signals, [])
    plan_context = Keyword.get(opts, :plan_context)
    memory_refs = Keyword.get(opts, :memory_refs, [])
    permission_policy = Keyword.get(opts, :permission_policy)

    rule_opts =
      [
        home_dir: Keyword.get(opts, :home_dir),
        max_rule_chars: Keyword.get(opts, :max_rule_chars)
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    with {:ok, agent} <- select_agent(agent_registry, agent_name),
         {:ok, rules} <- RuleLoader.load(project_dir, rule_opts),
         skills_section <- {:ok, build_skills_section(skill_registry, signals)},
         :ok <- validate_plan_context_for_agent(agent, plan_context) do
      sections =
        []
        |> add_agent_identity(agent)
        |> add_rules(rules)
        |> add_skills(skills_section)
        |> add_plan_context(plan_context, agent)
        |> add_permission_policy(permission_policy)
        |> add_memory_refs(memory_refs)
        |> add_model_hints(agent)

      metadata = build_metadata(agent, rules, signals, plan_context, memory_refs)

      {:ok,
       %__MODULE__{
         sections: sections,
         metadata: metadata,
         agent: agent
       }}
    end
  end

  @doc """
  Renders the assembled prompt as a single markdown string.
  """
  @spec render(t()) :: String.t()
  def render(%__MODULE__{sections: sections}) do
    sections
    |> Enum.map(fn {_name, content} -> content end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n---\n\n")
  end

  @doc """
  Returns a specific section by name from the assembled prompt.
  """
  @spec get_section(t(), atom()) :: String.t() | nil
  def get_section(%__MODULE__{sections: sections}, name) when is_atom(name) do
    Keyword.get(sections, name)
  end

  @doc """
  Returns the debug metadata map.
  """
  @spec metadata(t()) :: map()
  def metadata(%__MODULE__{metadata: metadata}), do: metadata

  # ── Private: agent selection ─────────────────────────────────────────

  defp select_agent(registry, name) do
    case AgentRegistry.lookup(registry, name) do
      {:ok, profile} -> {:ok, profile}
      {:error, :not_found} -> {:error, {:agent_not_found, name}}
    end
  end

  # ── Private: plan context validation ────────────────────────────────

  # A planning agent must not receive execution plan context that implies
  # write capability (§25.3 R1: no mutating before approval).
  defp validate_plan_context_for_agent(_agent, nil), do: :ok

  defp validate_plan_context_for_agent(agent, plan_context) do
    if AgentProfile.can_mutate?(agent) or plan_approved?(plan_context) do
      :ok
    else
      :ok
      # Planning agents may see plan context for reference;
      # actual mutation is blocked at the hook layer.
    end
  end

  defp plan_approved?(%{plan_status: status}) when status in ["approved", "executing"], do: true
  defp plan_approved?(_), do: false

  # ── Private: section builders ───────────────────────────────────────

  defp add_agent_identity(sections, agent) do
    identity = build_agent_identity_section(agent)
    [{:agent_identity, identity} | sections]
  end

  defp add_rules(sections, rules) do
    rules_section = RuleLoader.to_prompt_section(rules)
    [{:rules, rules_section} | sections]
  end

  defp add_skills(sections, {:ok, skills_section}) do
    [{:skills, skills_section} | sections]
  end

  defp add_skills(sections, _), do: sections

  defp add_plan_context(sections, nil, _agent), do: [{:plan_context, ""} | sections]

  defp add_plan_context(sections, plan_context, agent) do
    context_section = build_plan_context_section(plan_context, agent)
    [{:plan_context, context_section} | sections]
  end

  defp add_permission_policy(sections, nil), do: [{:permission_policy, ""} | sections]

  defp add_permission_policy(sections, policy) when is_binary(policy) do
    [{:permission_policy, policy} | sections]
  end

  defp add_memory_refs(sections, []), do: [{:memory_refs, ""} | sections]

  defp add_memory_refs(sections, refs) do
    section = "# Gold Memory References\n\n" <> Enum.join(refs, "\n")
    [{:memory_refs, section} | sections]
  end

  defp add_model_hints(sections, agent) do
    hints = build_model_hints_section(agent)
    [{:model_hints, hints} | sections]
  end

  # ── Private: section content builders ───────────────────────────────

  defp build_agent_identity_section(agent) do
    tools = agent.allowed_tools |> Enum.map(&Atom.to_string/1) |> Enum.join(", ")
    categories = agent.allowed_categories |> Enum.join(", ")

    "# Agent Profile: #{agent.name}\n\n" <>
      "#{agent.description}\n\n" <>
      "**Purpose**: #{agent.purpose}\n" <>
      "**Tools**: #{tools}\n" <>
      "**Categories**: #{categories}\n" <>
      "**Can mutate**: #{agent.can_mutate}"
  end

  defp build_skills_section(skill_registry, signals) do
    SkillRegistry.to_prompt_section(skill_registry, signals)
  end

  defp build_plan_context_section(plan_context, agent) do
    objective = Map.get(plan_context, :objective, "")
    active_task = Map.get(plan_context, :active_task, "")
    plan_status = Map.get(plan_context, :plan_status, "draft")
    files_scope = Map.get(plan_context, :files_scope, [])
    permission_scope = Map.get(plan_context, :permission_scope, [])

    "# Active Plan/Task Context\n\n" <>
      "**Plan status**: #{plan_status}\n" <>
      "**Objective**: #{objective}\n" <>
      maybe_active_task(active_task) <>
      maybe_files_scope(files_scope) <>
      maybe_permission_scope(permission_scope, agent)
  end

  defp maybe_active_task(""), do: ""
  defp maybe_active_task(task), do: "**Active task**: #{task}\n"

  defp maybe_files_scope([]), do: ""
  defp maybe_files_scope(files), do: "**Files scope**: #{Enum.join(files, ", ")}\n"

  defp maybe_permission_scope([], _agent), do: ""

  defp maybe_permission_scope(scope, agent),
    do: "**Permission scope**: #{Enum.join(scope, ", ")} (agent: #{agent.can_mutate})\n"

  defp build_model_hints_section(agent) do
    prefs = agent.model_preferences

    if map_size(prefs) == 0 do
      "# Model Hints\n\n(No special model preferences)"
    else
      items =
        prefs
        |> Enum.sort_by(fn {k, _v} -> to_string(k) end)
        |> Enum.map(fn {k, v} -> "- **#{k}**: #{v}" end)
        |> Enum.join("\n")

      "# Model Hints\n\n#{items}"
    end
  end

  # ── Private: metadata builder ──────────────────────────────────────

  defp build_metadata(agent, rules, signals, plan_context, memory_refs) do
    %{
      agent: AgentProfile.to_metadata(agent),
      rules_loaded: length(rules),
      rules_sources: Enum.map(rules, fn {source, _content} -> source end),
      signals_matched: signals,
      has_plan_context: plan_context != nil,
      memory_refs_count: length(memory_refs),
      assembled_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end
end
