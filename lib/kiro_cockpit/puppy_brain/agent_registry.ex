defmodule KiroCockpit.PuppyBrain.AgentRegistry do
  @moduledoc """
  Agent registry for PuppyBrain (§26.2, §28.1).

  Manages agent profiles (planner, executor, reviewer, QA, security,
  docs). The `PromptAssembler` selects the active agent profile before
  assembling a prompt; the registry provides lookup and enumeration.

  ## Built-in profiles

  Six profiles ship with the registry (see `builtins/0`):

    * `:nano_planner`  — read-only discovery, planning/researching
    * `:executor`      — read/write/shell, acting/verifying
    * `:reviewer`       — read-only, verifying
    * `:qa`             — read + shell_read, verifying/debugging
    * `:security`       — read-only, verifying
    * `:docs`           — read + write (docs only), documenting

  ## Hard policy (§25.3)

  Even if an agent profile grants mutating tools, the Swarm runtime
  enforces hard policy invariants. A planning agent may **never** write
  regardless of its profile. The `can_mutate?/2` function checks
  profile capability; actual permission is enforced at the hook layer.

  ## Pure module

  No DB, no side effects beyond filesystem reads for system prompt paths.
  """

  alias KiroCockpit.PuppyBrain.AgentProfile

  @type t :: %__MODULE__{
          profiles: %{atom() => AgentProfile.t()}
        }

  defstruct profiles: %{}

  # ── Public API ──────────────────────────────────────────────────────

  @doc """
  Creates a new empty agent registry.
  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Creates a registry pre-loaded with built-in agent profiles.
  """
  @spec with_builtins() :: t()
  def with_builtins do
    Enum.reduce(builtins(), new(), fn profile, registry ->
      {:ok, reg} = register(registry, profile)
      reg
    end)
  end

  @doc """
  Returns the list of built-in agent profiles.
  """
  @spec builtins() :: [AgentProfile.t()]
  def builtins do
    [
      AgentProfile.new(
        name: :nano_planner,
        description:
          "Read-only NanoPlanner used to draft approval-gated plans. " <>
            "Discovery only: must not modify files, run shells, or call MCP tools.",
        system_prompt_path: "priv/prompts/nano_planner_system_prompt.md",
        allowed_tools: [:read, :grep],
        allowed_categories: ["researching", "planning"],
        purpose: :planning,
        model_preferences: %{
          reasoning_effort: "high",
          verbosity: "medium",
          structured_output: true
        }
      ),
      AgentProfile.new(
        name: :executor,
        description:
          "Execution agent controlled by approved NanoPlanner plans. " <>
            "Tools expose read/write/shell capability, but Swarm hooks gate mutations.",
        system_prompt_path: "priv/prompts/kiro_executor_system_prompt.md",
        allowed_tools: [:read, :write, :shell_read, :shell_write],
        allowed_categories: ["acting", "verifying"],
        purpose: :execution,
        model_preferences: %{
          reasoning_effort: "medium",
          verbosity: "low",
          structured_output: false
        }
      ),
      AgentProfile.new(
        name: :reviewer,
        description:
          "Read-only architecture reviewer. Cannot mutate files. " <>
            "Produces plan evidence and Silver findings.",
        allowed_tools: [:read, :grep],
        allowed_categories: ["verifying"],
        purpose: :verification,
        model_preferences: %{
          reasoning_effort: "high",
          verbosity: "medium",
          structured_output: true
        }
      ),
      AgentProfile.new(
        name: :qa,
        description:
          "QA reviewer with test-run capability. Can run read-only shells " <>
            "(tests, diffs, logs) but cannot write.",
        allowed_tools: [:read, :grep, :shell_read],
        allowed_categories: ["verifying", "debugging"],
        purpose: :verification,
        model_preferences: %{
          reasoning_effort: "medium",
          verbosity: "medium",
          structured_output: true
        }
      ),
      AgentProfile.new(
        name: :security,
        description:
          "Security reviewer. Read-only access for threat modeling, " <>
            "permission audits, and compliance checks.",
        allowed_tools: [:read, :grep],
        allowed_categories: ["verifying"],
        purpose: :verification,
        model_preferences: %{
          reasoning_effort: "high",
          verbosity: "low",
          structured_output: true
        }
      ),
      AgentProfile.new(
        name: :docs,
        description:
          "Documentation agent. May write docs when approved by the plan. " <>
            "Cannot modify source code.",
        allowed_tools: [:read, :grep, :write],
        allowed_categories: ["documenting"],
        purpose: :documentation,
        model_preferences: %{
          reasoning_effort: "low",
          verbosity: "medium",
          structured_output: false
        }
      )
    ]
  end

  @doc """
  Registers an agent profile in the registry.

  Returns `{:ok, registry}` or `{:error, reason}`.
  """
  @spec register(t(), AgentProfile.t()) :: {:ok, t()} | {:error, term()}
  def register(%__MODULE__{profiles: profiles} = registry, %AgentProfile{} = profile) do
    name = profile.name

    if Map.has_key?(profiles, name) do
      {:error, {:already_registered, name}}
    else
      {:ok, %{registry | profiles: Map.put(profiles, name, profile)}}
    end
  end

  @doc """
  Looks up an agent profile by name.
  """
  @spec lookup(t(), atom()) :: {:ok, AgentProfile.t()} | {:error, :not_found}
  def lookup(%__MODULE__{profiles: profiles}, name) when is_atom(name) do
    case Map.fetch(profiles, name) do
      {:ok, profile} -> {:ok, profile}
      :error -> {:error, :not_found}
    end
  end

  @doc """
  Lists all registered agent profile names.
  """
  @spec list_names(t()) :: [atom()]
  def list_names(%__MODULE__{profiles: profiles}), do: Map.keys(profiles) |> Enum.sort()

  @doc """
  Lists all registered agent profiles.
  """
  @spec list_all(t()) :: [AgentProfile.t()]
  def list_all(%__MODULE__{profiles: profiles}), do: Map.values(profiles)

  @doc """
  Selects an agent profile appropriate for the given purpose.

  Returns the first profile matching the purpose, or `{:error, :not_found}`.
  """
  @spec select_for_purpose(t(), AgentProfile.purpose()) ::
          {:ok, AgentProfile.t()} | {:error, :not_found}
  def select_for_purpose(%__MODULE__{profiles: profiles}, purpose) do
    profiles
    |> Map.values()
    |> Enum.find(fn profile -> profile.purpose == purpose end)
    |> case do
      nil -> {:error, :not_found}
      profile -> {:ok, profile}
    end
  end

  @doc """
  Returns agents whose allowed categories include the given category.
  """
  @spec for_category(t(), String.t()) :: [AgentProfile.t()]
  def for_category(%__MODULE__{profiles: profiles}, category) do
    profiles
    |> Map.values()
    |> Enum.filter(&AgentProfile.allows_category?(&1, category))
  end

  @doc """
  Produces debug metadata for all registered profiles.
  """
  @spec to_metadata(t()) :: [map()]
  def to_metadata(%__MODULE__{profiles: profiles}) do
    profiles
    |> Map.values()
    |> Enum.map(&AgentProfile.to_metadata/1)
    |> Enum.sort_by(& &1.name)
  end
end
