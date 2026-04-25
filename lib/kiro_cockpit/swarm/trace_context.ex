defmodule KiroCockpit.Swarm.TraceContext do
  @moduledoc """
  Trace and span identifiers for correlating hook chains across the Swarm runtime.

  Every event flowing through the hook system carries a `TraceContext` so that
  downstream consumers (logging, telemetry, Bronze capture) can reconstruct
  the full execution path.

  §27.11 Invariant 8: every execution is traceable to plan_id and task_id —
  the trace context extends that traceability to the hook-chain level.
  """

  @type t :: %__MODULE__{
          trace_id: String.t(),
          span_id: String.t(),
          parent_span_id: String.t() | nil
        }

  @enforce_keys [:trace_id, :span_id]
  defstruct [:trace_id, :span_id, :parent_span_id]

  @doc """
  Generate a new root trace context with random trace and span IDs.
  """
  @spec new() :: t()
  def new do
    %__MODULE__{
      trace_id: generate_id(),
      span_id: generate_id()
    }
  end

  @doc """
  Create a child span from an existing context.

  The child shares the same `trace_id` (preserving the trace) but receives a
  new `span_id` and records the parent's `span_id` as `parent_span_id`.
  """
  @spec child_span(t()) :: t()
  def child_span(%__MODULE__{trace_id: trace_id, span_id: parent_span_id}) do
    %__MODULE__{
      trace_id: trace_id,
      span_id: generate_id(),
      parent_span_id: parent_span_id
    }
  end

  # -- Internals ------------------------------------------------------------

  @spec generate_id() :: String.t()
  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
