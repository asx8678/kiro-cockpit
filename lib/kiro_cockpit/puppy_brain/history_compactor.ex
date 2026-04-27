defmodule KiroCockpit.PuppyBrain.HistoryCompactor do
  @moduledoc "Compacts chat history while preserving safety-critical context." 

  def compact(events, opts \\ []) when is_list(events) do
    max_events = Keyword.get(opts, :max_events, 20)

    protected = Enum.filter(events, &protected?/1)
    recent = Enum.take(events, -max_events)

    (protected ++ recent)
    |> Enum.uniq_by(&event_key/1)
    |> preserve_tool_pairs(events)
  end

  defp protected?(event) do
    type = Map.get(event, :type) || Map.get(event, "type")
    type in [:active_plan, "active_plan", :active_task, "active_task", :permission_request, "permission_request"]
  end

  defp event_key(event), do: Map.get(event, :id) || Map.get(event, "id") || :erlang.phash2(event)

  defp preserve_tool_pairs(compacted, original) do
    ids = MapSet.new(Enum.map(compacted, &event_key/1))

    paired =
      Enum.flat_map(compacted, fn event ->
        case tool_pair_id(event) do
          nil -> []
          pair_id -> Enum.filter(original, &(tool_pair_id(&1) == pair_id))
        end
      end)

    (compacted ++ paired)
    |> Enum.uniq_by(&event_key/1)
    |> Enum.sort_by(fn event -> Enum.find_index(original, &(&1 == event)) || 0 end)
    |> Enum.reject(fn event -> MapSet.member?(ids, event_key(event)) == false and tool_pair_id(event) == nil end)
  end

  defp tool_pair_id(event), do: Map.get(event, :tool_call_id) || Map.get(event, "tool_call_id")
end
