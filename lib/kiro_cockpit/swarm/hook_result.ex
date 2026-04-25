defmodule KiroCockpit.Swarm.HookResult do
  @moduledoc """
  Decision result returned by each hook in the chain.

  A hook returns one of three decisions (§27.1):

    - `:continue` — allow the next hook to run, event passes through unchanged
    - `:modify` — replace or enrich the event, then continue the chain
    - `:block` — stop the chain and return error/guidance with a reason

  The struct captures the possibly-modified event, accumulated messages, a
  reason (only for `:block`), and hook-specific metadata for downstream
  consumers (audit, telemetry, UI).
  """

  alias KiroCockpit.Swarm.Event

  @type decision :: :continue | :modify | :block

  @type t :: %__MODULE__{
          decision: decision(),
          event: Event.t(),
          messages: [String.t()],
          reason: String.t() | nil,
          hook_metadata: map()
        }

  @enforce_keys [:decision, :event]
  defstruct [:decision, :event, messages: [], reason: nil, hook_metadata: %{}]

  @doc """
  Create a `:continue` result — the event passes through, chain continues.
  """
  @spec continue(Event.t(), [String.t()], keyword()) :: t()
  def continue(event, messages \\ [], opts \\ []) do
    %__MODULE__{
      decision: :continue,
      event: event,
      messages: List.wrap(messages),
      hook_metadata: Keyword.get(opts, :hook_metadata, %{})
    }
  end

  @doc """
  Create a `:modify` result — the event is replaced/enriched, chain continues.

  The modified event is passed to the next hook in the chain.
  """
  @spec modify(Event.t(), [String.t()], keyword()) :: t()
  def modify(event, messages \\ [], opts \\ []) do
    %__MODULE__{
      decision: :modify,
      event: event,
      messages: List.wrap(messages),
      hook_metadata: Keyword.get(opts, :hook_metadata, %{})
    }
  end

  @doc """
  Create a `:block` result — stop the chain with a reason and guidance.

  `reason` is a human-readable string explaining why the action was blocked.
  """
  @spec block(Event.t(), String.t(), [String.t()], keyword()) :: t()
  def block(event, reason, messages \\ [], opts \\ []) when is_binary(reason) do
    %__MODULE__{
      decision: :block,
      event: event,
      reason: reason,
      messages: List.wrap(messages),
      hook_metadata: Keyword.get(opts, :hook_metadata, %{})
    }
  end

  @doc """
  Whether this result blocks further hook execution.
  """
  @spec blocked?(t()) :: boolean()
  def blocked?(%__MODULE__{decision: :block}), do: true
  def blocked?(%__MODULE__{}), do: false
end
