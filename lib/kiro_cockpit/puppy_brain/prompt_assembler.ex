defmodule KiroCockpit.PuppyBrain.PromptAssembler do
  @moduledoc "Assembles structured PuppyBrain prompts for planner/executor handoff."

  alias KiroCockpit.PuppyBrain.{AgentRegistry, ModelProfile, RuleLoader, SkillRegistry}

  def assemble(agent_id, request, opts \\ []) do
    profile = AgentRegistry.fetch!(agent_id)
    rules = RuleLoader.load(agent_id, opts)
    skills = SkillRegistry.select([request | Keyword.get(opts, :signals, [])])
    {:ok, model} = ModelProfile.for_agent(profile)

    active_plan = Keyword.get(opts, :active_plan)
    active_task = Keyword.get(opts, :active_task)
    memories = Keyword.get(opts, :memories, [])

    sections = [
      section("Agent", [profile.name, "purpose=#{profile.purpose}"]),
      section("Hard safety and rules", Enum.map(rules, &format_rule/1)),
      section("Selected skills", Enum.map(skills, &"#{&1.id}: #{&1.name}")),
      section("Active plan", format_context(active_plan)),
      section("Active task", format_context(active_task)),
      section("Memory references", Enum.map(memories, &to_string/1)),
      section("User request", [to_string(request)])
    ]

    %{
      prompt: Enum.join(sections, "\n\n"),
      metadata: %{
        agent_id: profile.id,
        model_profile: model,
        rule_sources: Enum.map(rules, & &1.source),
        skill_ids: Enum.map(skills, & &1.id),
        active_plan?: not is_nil(active_plan),
        active_task?: not is_nil(active_task),
        memories_count: length(memories)
      }
    }
  end

  defp format_rule(%{source: source, text: text, hard?: hard?}) do
    prefix = if hard?, do: "HARD", else: source |> Atom.to_string() |> String.upcase()
    "[#{prefix}] #{text}"
  end

  defp format_context(nil), do: ["none"]
  defp format_context(context) when is_map(context), do: Enum.map(context, fn {k, v} -> "#{k}: #{v}" end)
  defp format_context(context), do: [inspect(context)]

  defp section(title, lines), do: "## #{title}\n" <> Enum.join(List.wrap(lines), "\n")
end
