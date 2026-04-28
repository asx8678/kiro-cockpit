defmodule KiroCockpit.Swarm.Analyzers.DreamAnalyzer do
  @moduledoc "Tags reusable patterns and file/module relationships for memory."

  alias KiroCockpit.Swarm.DataPipeline.Finding

  def analyze(%{relationship: relationship} = event),
    do: relationship_finding(event, relationship)

  def analyze(%{"relationship" => relationship} = event),
    do: relationship_finding(event, relationship)

  def analyze(event) do
    text = inspect(event)

    if String.contains?(String.downcase(text), "relationship") do
      relationship_finding(event, text)
    else
      []
    end
  end

  defp relationship_finding(event, relationship) do
    [
      Finding.new(%{
        tag: :relationship,
        type: :reference,
        priority: 72,
        summary: "Reusable relationship: #{relationship}",
        evidence: inspect(event),
        session_id: get(event, :session_id),
        plan_id: get(event, :plan_id),
        task_id: get(event, :task_id)
      })
    ]
  end

  defp get(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
end
