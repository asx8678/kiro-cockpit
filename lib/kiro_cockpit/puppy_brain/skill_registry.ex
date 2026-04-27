defmodule KiroCockpit.PuppyBrain.SkillRegistry do
  @moduledoc "Selects reusable skills from request/project signals."

  @skills [
    %{id: :testing, name: "Testing", signals: ~w(test tests pytest mix coverage regression qa)},
    %{id: :security, name: "Security", signals: ~w(auth security permission owasp secret)},
    %{id: :performance, name: "Performance", signals: ~w(performance latency p95 load benchmark)},
    %{id: :liveview, name: "Phoenix LiveView", signals: ~w(liveview phoenix socket heex)}
  ]

  def select(signals) when is_list(signals) do
    haystack = signals |> Enum.map(&to_string/1) |> Enum.join(" ") |> String.downcase()
    Enum.filter(@skills, fn skill -> Enum.any?(skill.signals, &String.contains?(haystack, &1)) end)
  end
end
