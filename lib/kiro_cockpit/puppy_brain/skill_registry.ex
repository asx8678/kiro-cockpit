defmodule KiroCockpit.PuppyBrain.SkillRegistry do
  @moduledoc """
  Skill registry for PuppyBrain (§26.10, §28.1).

  Reusable workflow cards that NanoPlanner can reference during planning.
  Each skill has signal keywords, recommended agents, prerequisite reads,
  steps, risks, and validation criteria.

  ## Skill schema

      %{
        name: "phoenix-liveview-dashboard",
        description: "Build a Phoenix LiveView dashboard...",
        applies_when: ["Phoenix", "LiveView", "dashboard"],
        recommended_agents: [:architecture_reviewer, :qa_reviewer],
        read_first: ["lib/*_web/router.ex", "lib/**/*live*.ex"],
        steps: ["inspect routes", "add LiveView", ...],
        risks: ["event payload drift", ...],
        validation: ["LiveView tests", ...]
      }

  ## Lookup

  Skills are matched by name (exact) or by signal overlap with the
  user request / project context. Signal matching uses simple keyword
  intersection; no LLM involvement.

  ## Pure module

  No DB, no agents, no side effects. Skills are registered in process
  dictionary or passed explicitly for testability.
  """

  @type skill :: %{
          name: String.t(),
          description: String.t(),
          applies_when: [String.t()],
          recommended_agents: [atom()],
          read_first: [String.t()],
          steps: [String.t()],
          risks: [String.t()],
          validation: [String.t()]
        }

  @type t :: %__MODULE__{
          skills: %{String.t() => skill()},
          signal_index: %{String.t() => [String.t()]}
        }

  defstruct skills: %{}, signal_index: %{}

  # ── Public API ──────────────────────────────────────────────────────

  @doc """
  Creates a new empty skill registry.
  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Creates a registry pre-loaded with built-in skills (§26.10).
  """
  @spec with_builtins() :: t()
  def with_builtins do
    Enum.reduce(builtin_skills(), new(), fn skill, reg ->
      {:ok, next} = register(reg, skill)
      next
    end)
  end

  defp builtin_skills do
    [
      builtin_skill(:phoenix_liveview_dashboard),
      builtin_skill(:acp_json_rpc_debugging),
      builtin_skill(:permission_model_hardening),
      builtin_skill(:postgres_migration_review),
      builtin_skill(:security_threat_model),
      builtin_skill(:long_turn_regression_test)
    ]
  end

  @doc """
  Registers a skill in the registry.

  Returns `{:ok, registry}` on success, or `{:error, reason}` if the
  skill is invalid or already registered.
  """
  @spec register(t(), skill()) :: {:ok, t()} | {:error, term()}
  def register(%__MODULE__{} = registry, %{} = skill) do
    with {:ok, name} <- validate_skill(skill),
         :ok <- check_not_registered(registry, name) do
      skills = Map.put(registry.skills, name, skill)
      signal_index = build_signal_index(skills)
      {:ok, %__MODULE__{registry | skills: skills, signal_index: signal_index}}
    end
  end

  @doc """
  Looks up a skill by exact name.
  """
  @spec lookup(t(), String.t()) :: {:ok, skill()} | {:error, :not_found}
  def lookup(%__MODULE__{skills: skills}, name) when is_binary(name) do
    case Map.fetch(skills, name) do
      {:ok, skill} -> {:ok, skill}
      :error -> {:error, :not_found}
    end
  end

  @doc """
  Finds skills matching the given signals (keywords from user request
  or project context).

  Returns a list of `{skill, match_count}` tuples sorted by descending
  match count. Skills with zero signal overlap are excluded.
  """
  @spec match_signals(t(), [String.t()]) :: [{skill(), non_neg_integer()}]
  def match_signals(%__MODULE__{skills: skills}, signals) when is_list(signals) do
    normalized = Enum.map(signals, &normalize_signal/1)

    skills
    |> Map.values()
    |> Enum.map(fn skill ->
      skill_signals = Enum.map(skill.applies_when, &normalize_signal/1)
      overlap = Enum.count(skill_signals, &(&1 in normalized))
      {skill, overlap}
    end)
    |> Enum.filter(fn {_skill, count} -> count > 0 end)
    |> Enum.sort_by(fn {_skill, count} -> -count end)
  end

  @doc """
  Returns all registered skill names.
  """
  @spec list_names(t()) :: [String.t()]
  def list_names(%__MODULE__{skills: skills}), do: Map.keys(skills) |> Enum.sort()

  @doc """
  Returns all registered skills.
  """
  @spec list_all(t()) :: [skill()]
  def list_all(%__MODULE__{skills: skills}), do: Map.values(skills)

  @doc """
  Formats matching skills into a prompt section.
  """
  @spec to_prompt_section(t(), [String.t()]) :: String.t()
  def to_prompt_section(%__MODULE__{} = registry, signals) do
    matched = match_signals(registry, signals)

    case matched do
      [] ->
        "(no matching skills)"

      skills ->
        items =
          skills
          |> Enum.map(fn {skill, _count} ->
            "- **#{skill.name}**: #{skill.description}"
          end)
          |> Enum.join("\n")

        "# Matching Skills\n\n#{items}"
    end
  end

  # ── Private: validation ─────────────────────────────────────────────

  defp validate_skill(%{name: name}) when is_binary(name) and name != "", do: {:ok, name}
  defp validate_skill(_), do: {:error, :skill_name_required}

  defp check_not_registered(%__MODULE__{skills: skills}, name) do
    if Map.has_key?(skills, name), do: {:error, {:already_registered, name}}, else: :ok
  end

  # ── Private: signal index ──────────────────────────────────────────

  defp build_signal_index(skills) do
    skills
    |> Map.values()
    |> Enum.flat_map(fn skill ->
      skill.applies_when
      |> Enum.map(&normalize_signal/1)
      |> Enum.map(fn sig -> {sig, skill.name} end)
    end)
    |> Enum.group_by(fn {sig, _name} -> sig end, fn {_sig, name} -> name end)
  end

  defp normalize_signal(signal) do
    signal
    |> String.downcase()
    |> String.trim()
  end

  # ── Private: built-in skills (§26.10) ───────────────────────────────

  defp builtin_skill(:phoenix_liveview_dashboard) do
    %{
      name: "phoenix-liveview-dashboard",
      description: "Build a Phoenix LiveView dashboard with event cards and tests.",
      applies_when: ["Phoenix", "LiveView", "dashboard"],
      recommended_agents: [:reviewer, :qa],
      read_first: ["lib/*_web/router.ex", "lib/**/*live*.ex"],
      steps: ["inspect routes", "add LiveView", "add components", "test mount/render"],
      risks: ["event payload drift", "noisy timeline"],
      validation: ["LiveView tests", "event normalization unit tests"]
    }
  end

  defp builtin_skill(:acp_json_rpc_debugging) do
    %{
      name: "acp-json-rpc-debugging",
      description: "Debug ACP JSON-RPC communication issues between client and agent.",
      applies_when: ["ACP", "JSON-RPC", "debug", "agent"],
      recommended_agents: [:reviewer],
      read_first: ["lib/kiro_cockpit/acp/*.ex"],
      steps: [
        "check JSON-RPC message framing",
        "verify request/response IDs",
        "inspect port process logs",
        "test with fake agent"
      ],
      risks: ["stale port references", "encoding mismatches"],
      validation: ["JSON-RPC unit tests", "fake agent round-trip test"]
    }
  end

  defp builtin_skill(:permission_model_hardening) do
    %{
      name: "permission-model-hardening",
      description: "Review and harden the permission escalation model and policy gates.",
      applies_when: ["permission", "security", "policy", "escalation"],
      recommended_agents: [:security, :reviewer],
      read_first: [
        "lib/kiro_cockpit/permissions.ex",
        "lib/kiro_cockpit/swarm/tasks/task_scope.ex"
      ],
      steps: [
        "audit permission levels",
        "check category-tool matrix",
        "review stale-plan hash gate",
        "add regression tests"
      ],
      risks: ["privilege escalation", "policy bypass"],
      validation: ["permission boundary tests", "category enforcement tests"]
    }
  end

  defp builtin_skill(:postgres_migration_review) do
    %{
      name: "postgres-migration-review",
      description: "Review PostgreSQL migrations for safety, reversibility, and performance.",
      applies_when: ["postgres", "migration", "database", "ecto"],
      recommended_agents: [:reviewer, :qa],
      read_first: ["priv/repo/migrations/*.ex", "lib/kiro_cockpit/repo.ex"],
      steps: [
        "check migration direction",
        "verify rollback safety",
        "analyze index impact",
        "review data transformations"
      ],
      risks: ["data loss", "locking", "irreversible operations"],
      validation: ["migration rollback test", "explain analyze on dev"]
    }
  end

  defp builtin_skill(:security_threat_model) do
    %{
      name: "security-threat-model",
      description: "Produce a lightweight threat model for a feature or component.",
      applies_when: ["security", "threat", "review", "audit"],
      recommended_agents: [:security],
      read_first: ["lib/kiro_cockpit/permissions.ex", "lib/kiro_cockpit/swarm/action_boundary.ex"],
      steps: [
        "identify trust boundaries",
        "list data flows",
        "enumerate threats (STRIDE)",
        "assess risk per threat",
        "recommend mitigations"
      ],
      risks: ["incomplete threat enumeration", "mitigation gaps"],
      validation: ["threat model peer review", "security checklist"]
    }
  end

  defp builtin_skill(:long_turn_regression_test) do
    %{
      name: "long-turn-regression-test",
      description:
        "Test long-running Kiro ACP turns for stability, timeout, and cancel handling.",
      applies_when: ["ACP", "long-turn", "timeout", "regression", "cancel"],
      recommended_agents: [:qa],
      read_first: [
        "test/kiro_cockpit/kiro_session_long_turn_test.exs",
        "lib/kiro_cockpit/kiro_session.ex"
      ],
      steps: [
        "reproduce long-turn scenario",
        "verify cancel propagation",
        "check turn_end handling",
        "test timeout recovery"
      ],
      risks: ["flaky timing", "port process leaks"],
      validation: ["long-turn test suite", "port process count check"]
    }
  end
end
