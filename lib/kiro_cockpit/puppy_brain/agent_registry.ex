defmodule KiroCockpit.PuppyBrain.AgentRegistry do
  @moduledoc """
  Small registry of PuppyBrain agent profiles used by prompt/tool assembly.
  """

  @profiles %{
    nano_planner: %{
      id: :nano_planner,
      name: "Nano Planner",
      purpose: :planner,
      hard_rules: [
        "HARD SAFETY: Planning mode is read-only; do not request write/shell execution.",
        "HARD SAFETY: Project rules may add constraints but must never weaken wrapper policy."
      ],
      default_tools: [:read, :grep, :list_files]
    },
    executor: %{
      id: :executor,
      name: "Kiro Executor",
      purpose: :executor,
      hard_rules: [
        "HARD SAFETY: Execute only approved active task scope.",
        "HARD SAFETY: Validate changes with focused tests before completion."
      ],
      default_tools: [:read, :grep, :write, :shell]
    },
    steering: %{
      id: :steering,
      name: "Swarm Steering",
      purpose: :steering,
      hard_rules: ["HARD SAFETY: Prefer conservative guidance when relevance is uncertain."],
      default_tools: []
    },
    scorer: %{
      id: :scorer,
      name: "Findings Scorer",
      purpose: :scorer,
      hard_rules: ["HARD SAFETY: Promote memory only when threshold evidence is met."],
      default_tools: []
    }
  }

  @spec get(atom()) :: {:ok, map()} | {:error, :unknown_agent}
  def get(id) when is_atom(id), do: Map.fetch(@profiles, id) |> normalize_fetch()

  @spec fetch!(atom()) :: map()
  def fetch!(id) do
    case get(id) do
      {:ok, profile} -> profile
      {:error, :unknown_agent} -> raise ArgumentError, "unknown PuppyBrain agent #{inspect(id)}"
    end
  end

  defp normalize_fetch({:ok, profile}), do: {:ok, profile}
  defp normalize_fetch(:error), do: {:error, :unknown_agent}
end
