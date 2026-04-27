defmodule KiroCockpit.PuppyBrain.ModelProfile do
  @moduledoc "Maps PuppyBrain purposes to deterministic model/runtime settings." 

  @profiles %{
    planner: %{purpose: :planner, reasoning: :high, temperature: 0.2, response_format: :json_plan},
    executor: %{purpose: :executor, reasoning: :medium, temperature: 0.1, response_format: :text},
    steering: %{purpose: :steering, reasoning: :low, temperature: 0.0, response_format: :decision},
    scorer: %{purpose: :scorer, reasoning: :medium, temperature: 0.0, response_format: :score}
  }

  def for_purpose(purpose), do: Map.fetch(@profiles, purpose)
  def for_agent(%{purpose: purpose}), do: for_purpose(purpose)
end
