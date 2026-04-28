defmodule KiroCockpit.Swarm.Memory.Gold do
  @moduledoc "In-memory Gold memory helpers for retrieval/consolidation tests."

  def from_finding(finding) do
    %{
      id: Map.get(finding, :id),
      type: Map.get(finding, :type),
      tag: Map.get(finding, :tag),
      summary: Map.get(finding, :summary),
      evidence: Map.get(finding, :evidence),
      priority: Map.get(finding, :priority)
    }
  end

  def retrieve(memories, query) do
    q = String.downcase(to_string(query))

    Enum.filter(memories, fn memory ->
      memory
      |> Map.take([:summary, :evidence, :tag, :type])
      |> inspect()
      |> String.downcase()
      |> String.contains?(q)
    end)
  end

  def consolidate(memories) do
    Enum.uniq_by(memories, fn memory ->
      {Map.get(memory, :type), Map.get(memory, :tag), Map.get(memory, :summary)}
    end)
  end
end
