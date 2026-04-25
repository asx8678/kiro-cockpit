defmodule KiroCockpitWeb.TelemetryTest do
  @moduledoc """
  Guards against telemetry-taxonomy drift in the Phase 1 metrics seed
  (`plan2.md` §25.3 R8).

  `KiroCockpitWeb.Telemetry.metrics/0` builds every domain `event_name:`
  through `KiroCockpit.Telemetry.event/3`, which validates against the
  closed sets of contexts/actions/phases. If anyone adds a near-duplicate
  metric (e.g. `:tool_dispatch` vs `:tool_run_dispatch`), `event/3`
  raises and these tests fail loudly — instead of producing a metric
  that never receives events.
  """
  use ExUnit.Case, async: true

  alias KiroCockpit.Telemetry, as: KCT

  test "metrics/0 returns the configured definitions without raising" do
    metrics = KiroCockpitWeb.Telemetry.metrics()

    assert is_list(metrics)
    assert length(metrics) > 0
  end

  test "every domain event_name is a canonical [:kiro_cockpit, ctx, action, phase] tuple" do
    metrics = KiroCockpitWeb.Telemetry.metrics()
    contexts = KCT.contexts()
    phases = [:start, :stop, :exception]

    domain_events =
      metrics
      |> Enum.map(& &1.event_name)
      |> Enum.filter(fn
        [:kiro_cockpit, ctx, _action, _phase] -> ctx in contexts
        _ -> false
      end)

    assert domain_events != [], "expected at least one canonical kiro_cockpit domain metric"

    for event_name <- domain_events do
      assert [:kiro_cockpit, context, action, phase] = event_name
      assert context in contexts, "non-canonical context: #{inspect(event_name)}"
      assert action in KCT.actions(context), "non-canonical action: #{inspect(event_name)}"
      assert phase in phases, "non-canonical phase: #{inspect(event_name)}"

      # Round-trip through event/3 — the single source of truth — to
      # guarantee the metric definition cannot drift from the builder.
      assert KCT.event(context, action, phase) == event_name
    end
  end
end
