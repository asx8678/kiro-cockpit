defmodule KiroCockpit.Swarm.DataPipeline.FindingsScorer do
  @moduledoc "Applies deterministic Gold-promotion threshold to Silver findings."

  @threshold 70

  def promote?(%{priority: priority}, threshold \\ @threshold), do: priority >= threshold

  def promoted(findings, threshold \\ @threshold),
    do: Enum.filter(findings, &promote?(&1, threshold))
end
