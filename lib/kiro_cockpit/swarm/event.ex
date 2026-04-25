defmodule KiroCockpit.Swarm.Event do
  @moduledoc """
  Normalized event struct for the Swarm hook/action flow.

  Every action request and hook chain execution operates on this shape. The
  struct carries correlation IDs (session, plan, task, agent), the action
  being performed, permission context, payloads (normalized + raw), extensible
  metadata, and a trace context for full-chain correlation.

  §27.11 Invariant 8: every execution is traceable to plan_id and task_id.
  """

  alias KiroCockpit.Swarm.TraceContext

  @type permission :: atom()

  @type t :: %__MODULE__{
          session_id: String.t() | nil,
          plan_id: String.t() | nil,
          task_id: String.t() | nil,
          agent_id: String.t() | nil,
          action_name: atom(),
          permission_level: permission() | nil,
          payload: map(),
          raw_payload: map(),
          metadata: map(),
          trace_context: TraceContext.t() | nil
        }

  @enforce_keys [:action_name]
  defstruct [
    :session_id,
    :plan_id,
    :task_id,
    :agent_id,
    :action_name,
    :permission_level,
    :trace_context,
    payload: %{},
    raw_payload: %{},
    metadata: %{}
  ]

  @doc """
  Create a new event with the given action name and optional keyword fields.

  ## Examples

      iex> event = KiroCockpit.Swarm.Event.new(:file_write, session_id: "sess_1")
      iex> event.action_name
      :file_write
      iex> event.session_id
      "sess_1"
  """
  @spec new(atom(), keyword()) :: t()
  def new(action_name, opts \\ []) when is_atom(action_name) do
    %__MODULE__{
      action_name: action_name,
      session_id: Keyword.get(opts, :session_id),
      plan_id: Keyword.get(opts, :plan_id),
      task_id: Keyword.get(opts, :task_id),
      agent_id: Keyword.get(opts, :agent_id),
      permission_level: Keyword.get(opts, :permission_level),
      payload: Keyword.get(opts, :payload, %{}),
      raw_payload: Keyword.get(opts, :raw_payload, %{}),
      metadata: Keyword.get(opts, :metadata, %{}),
      trace_context: Keyword.get(opts, :trace_context)
    }
  end
end
