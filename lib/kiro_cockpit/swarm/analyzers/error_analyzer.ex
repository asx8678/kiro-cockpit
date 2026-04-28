defmodule KiroCockpit.Swarm.Analyzers.ErrorAnalyzer do
  @moduledoc "Detects failures/errors and creates high-priority Silver findings."

  alias KiroCockpit.Swarm.DataPipeline.Finding

  def analyze(event) do
    text = inspect(event)

    if String.match?(String.downcase(text), ~r/(error|failed|exception|stderr|blocked)/) do
      [
        Finding.new(%{
          tag: :error,
          type: :feedback,
          priority: 90,
          summary: "High-priority failure detected",
          evidence: text,
          session_id: get(event, :session_id),
          plan_id: get(event, :plan_id),
          task_id: get(event, :task_id)
        })
      ]
    else
      []
    end
  end

  defp get(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
end
