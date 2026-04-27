defmodule KiroCockpit.PuppyBrain.RuleLoader do
  @moduledoc "Loads hard, global, project and .kiro rules in policy-safe order."

  alias KiroCockpit.PuppyBrain.AgentRegistry

  @type rule :: %{source: atom(), text: String.t(), hard?: boolean()}

  @spec load(atom(), keyword()) :: [rule()]
  def load(agent_id, opts \\ []) do
    profile = AgentRegistry.fetch!(agent_id)

    hard = Enum.map(profile.hard_rules, &%{source: :hard_policy, text: &1, hard?: true})
    global = opts |> Keyword.get(:global_rules, []) |> wrap(:global)
    project = opts |> Keyword.get(:project_rules, []) |> sanitize_project_rules() |> wrap(:project)
    kiro = opts |> Keyword.get(:kiro_rules, []) |> wrap(:kiro)

    hard ++ global ++ project ++ kiro
  end

  defp wrap(rules, source), do: Enum.map(rules, &%{source: source, text: to_string(&1), hard?: false})

  defp sanitize_project_rules(rules) do
    Enum.reject(rules, fn rule ->
      rule = String.downcase(to_string(rule))
      String.contains?(rule, "ignore hard safety") or
        String.contains?(rule, "override hard safety") or
        String.contains?(rule, "disable policy")
    end)
  end
end
