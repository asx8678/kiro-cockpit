defmodule KiroCockpitWeb.Telemetry do
  @moduledoc """
  Telemetry metrics collection for KiroCockpitWeb.

  Event taxonomy: `[:kiro_cockpit, <context>, <action>, :start | :stop | :exception]`.
  See `KiroCockpit.Telemetry` for the canonical event builder, span/execute
  helpers, and the closed sets of contexts and actions.

  Application-level metrics below are a Phase 1 seed for the planned ACP,
  session, and event-store contexts (`plan2.md` §25.3 R8). They define
  counter/summary shapes only — no events fire until those features land,
  at which point the metrics begin populating without further wiring.

  Every domain `event_name:` is built through `KiroCockpit.Telemetry.event/3`
  rather than written as a literal list. This routes the metric definition
  through the closed-set validator, so a typo or near-duplicate (e.g.
  `:tool_dispatch` vs `:tool_run_dispatch`) raises at supervisor init
  instead of silently producing a metric that never receives events.
  """
  use Supervisor
  import Telemetry.Metrics

  alias KiroCockpit.Telemetry, as: KCT

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.socket_connected.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.channel_join.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),
      summary("kiro_cockpit.repo.query.total_time", unit: {:native, :millisecond}),
      summary("kiro_cockpit.repo.query.decode_time", unit: {:native, :millisecond}),
      summary("kiro_cockpit.repo.query.query_time", unit: {:native, :millisecond}),
      summary("kiro_cockpit.repo.query.queue_time", unit: {:native, :millisecond}),
      summary("kiro_cockpit.repo.query.idle_time", unit: {:native, :millisecond}),

      # ACP context (seed) — prompt/turn/update lifecycle for the Kiro
      # ACP client. Populated once `KiroCockpit.ACP.*` modules emit events.
      counter("kiro_cockpit.acp.prompt.stop.count",
        event_name: KCT.event(:acp, :prompt, :stop)
      ),
      summary("kiro_cockpit.acp.prompt.stop.duration",
        event_name: KCT.event(:acp, :prompt, :stop),
        measurement: :duration,
        unit: {:native, :millisecond}
      ),
      counter("kiro_cockpit.acp.prompt.exception.count",
        event_name: KCT.event(:acp, :prompt, :exception)
      ),
      counter("kiro_cockpit.acp.turn.stop.count",
        event_name: KCT.event(:acp, :turn, :stop)
      ),
      summary("kiro_cockpit.acp.turn.stop.duration",
        event_name: KCT.event(:acp, :turn, :stop),
        measurement: :duration,
        unit: {:native, :millisecond}
      ),
      counter("kiro_cockpit.acp.update.stop.count",
        event_name: KCT.event(:acp, :update, :stop)
      ),
      counter("kiro_cockpit.acp.callback.stop.count",
        event_name: KCT.event(:acp, :callback, :stop)
      ),

      # Session context (seed) — cockpit session lifecycle.
      counter("kiro_cockpit.session.create.stop.count",
        event_name: KCT.event(:session, :create, :stop)
      ),
      counter("kiro_cockpit.session.resume.stop.count",
        event_name: KCT.event(:session, :resume, :stop)
      ),
      counter("kiro_cockpit.session.archive.stop.count",
        event_name: KCT.event(:session, :archive, :stop)
      ),

      # EventStore context (seed) — raw ACP event persistence.
      counter("kiro_cockpit.event_store.append.stop.count",
        event_name: KCT.event(:event_store, :append, :stop)
      ),
      summary("kiro_cockpit.event_store.append.stop.duration",
        event_name: KCT.event(:event_store, :append, :stop),
        measurement: :duration,
        unit: {:native, :millisecond}
      ),
      counter("kiro_cockpit.event_store.read.stop.count",
        event_name: KCT.event(:event_store, :read, :stop)
      ),
      summary("kiro_cockpit.event_store.read.stop.duration",
        event_name: KCT.event(:event_store, :read, :stop),
        measurement: :duration,
        unit: {:native, :millisecond}
      ),

      # BEAM VM — keep last so the previous Phoenix/Repo block stays grouped.
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io")
    ]
  end

  defp periodic_measurements do
    [
      # A module, function and arguments to be invoked periodically.
      # This function must call :telemetry.execute/3 and a metric will be
      # added and eventually plotted in the dashboard.
      # {KiroCockpitWeb, :count_users, []}
    ]
  end
end
