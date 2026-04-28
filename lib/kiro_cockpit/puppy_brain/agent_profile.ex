defmodule KiroCockpit.PuppyBrain.AgentProfile do
  @moduledoc """
  Agent profile struct for PuppyBrain (§26.2, §28.1).

  Each agent has an identity, tool scope, allowed task categories,
  and model preferences. Profiles are immutable data — the
  `AgentRegistry` stores and looks them up; the `PromptAssembler`
  consumes them when assembling prompts.

  ## Built-in profiles

  The registry ships with these profiles (see `AgentRegistry.builtins/0`):

    * `:nano_planner`  — read-only discovery, planning categories
    * `:executor`      — read/write/shell, acting categories
    * `:reviewer`      — read-only, verifying categories
    * `:qa`            — read-only + test runs, verifying/debugging
    * `:security`      — read-only, verifying categories
    * `:docs`          — read + doc writes, documenting categories

  ## Hard policy

  The `can_mutate?/1` flag is derived from `allowed_tools`. An agent
  with `:write`, `:shell_write`, `:destructive`, or `:terminal` in its
  tool set is considered mutating. Hard policy invariants (§25.3) may
  override profile-level tool grants — for example, a planning agent
  may never write even if its profile were altered.
  """

  @type tool ::
          :read
          | :write
          | :shell_read
          | :shell_write
          | :terminal
          | :external
          | :destructive
          | :subagent
          | :memory_write
          | :grep

  @type purpose :: :planning | :execution | :verification | :debugging | :documentation

  @type t :: %__MODULE__{
          name: atom(),
          description: String.t(),
          system_prompt_path: String.t() | nil,
          allowed_tools: [tool()],
          allowed_categories: [String.t()],
          purpose: purpose(),
          model_preferences: map(),
          can_mutate: boolean()
        }

  @enforce_keys [:name, :description, :allowed_tools, :allowed_categories, :purpose]
  defstruct [
    :name,
    :description,
    :system_prompt_path,
    :allowed_tools,
    :allowed_categories,
    :purpose,
    :model_preferences,
    :can_mutate
  ]

  @mutating_tools ~w(write shell_write terminal destructive memory_write)a

  @doc """
  Creates a new agent profile with computed `can_mutate` flag.
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    name = Keyword.fetch!(opts, :name)
    description = Keyword.fetch!(opts, :description)
    allowed_tools = Keyword.fetch!(opts, :allowed_tools)
    allowed_categories = Keyword.fetch!(opts, :allowed_categories)
    purpose = Keyword.fetch!(opts, :purpose)

    profile = %__MODULE__{
      name: name,
      description: description,
      system_prompt_path: Keyword.get(opts, :system_prompt_path),
      allowed_tools: allowed_tools,
      allowed_categories: allowed_categories,
      purpose: purpose,
      model_preferences: Keyword.get(opts, :model_preferences, %{}),
      can_mutate: compute_can_mutate(allowed_tools)
    }

    profile
  end

  @doc """
  Returns `true` if the agent profile includes any mutating tools.
  """
  @spec can_mutate?(t()) :: boolean()
  def can_mutate?(%__MODULE__{can_mutate: can_mutate}), do: can_mutate

  @doc """
  Returns `true` if the agent is allowed to use the given tool.
  """
  @spec has_tool?(t(), tool()) :: boolean()
  def has_tool?(%__MODULE__{allowed_tools: tools}, tool), do: tool in tools

  @doc """
  Returns `true` if the agent is allowed for the given task category.
  """
  @spec allows_category?(t(), String.t()) :: boolean()
  def allows_category?(%__MODULE__{allowed_categories: cats}, category) do
    category in cats
  end

  @doc """
  Serializes the profile to a map suitable for debug metadata.
  """
  @spec to_metadata(t()) :: map()
  def to_metadata(%__MODULE__{} = profile) do
    %{
      name: profile.name,
      description: profile.description,
      allowed_tools: profile.allowed_tools,
      allowed_categories: profile.allowed_categories,
      purpose: profile.purpose,
      can_mutate: profile.can_mutate
    }
  end

  # ── Private ─────────────────────────────────────────────────────────

  defp compute_can_mutate(allowed_tools) do
    Enum.any?(allowed_tools, &(&1 in @mutating_tools))
  end
end
