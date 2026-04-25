defmodule KiroCockpit.KiroSession.StreamEvent do
  @moduledoc """
  Normalized representation of an inbound ACP `session/update` notification.

  Raw `session/update` notifications carry a discriminator string at
  `params["update"]["sessionUpdate"]`. The payload shape varies per variant
  (chunk content vs tool calls vs mode/config updates vs `turn_end`). This
  struct flattens that into a stable Elixir-side shape without losing any
  information — `:raw` preserves the entire original `params` map.

  ## Why a struct + a single `normalize/3`

  The runtime kernel's job is to **normalize provider chunks at the transport
  boundary** (plan2.md §12.10) so downstream consumers (LiveView timeline,
  `EventStore`, future steering evaluator) see one stable shape regardless of
  whether Kiro CLI, a fake test agent, or some future ACP-compatible agent
  produced the bytes. Leaking raw `session/update` shapes past this boundary
  would force every downstream module to know about every ACP variant — that
  is exactly the anti-pattern §12.10 calls out.

  ## Fields

    * `:kind` — atomized `sessionUpdate` discriminator. One of:
      `:agent_message_chunk | :agent_thought_chunk | :user_message_chunk |
       :tool_call | :tool_call_update | :plan | :current_mode_update |
       :config_option_update | :turn_end | :unknown`.
    * `:type` — original `sessionUpdate` **string** from the wire payload,
      or `nil` if the notification did not carry one OR if the value was
      malformed (non-string). Malformed payloads are still preserved
      verbatim in `:raw`; we just don't pollute the public string-typed
      field with junk values.
    * `:session_id` — the ACP `sessionId` extracted from `params`.
    * `:sequence` — monotonically increasing integer assigned by the owning
      `KiroSession` GenServer at the moment of receipt.
    * `:occurred_at` — `DateTime` (UTC, microsecond) at receipt.
    * `:raw` — the full original `params` map (NOT just the inner `update`).
      Consumers that need every byte (e.g. `EventStore` replay) read this.

  ## Why no per-kind extracted fields

  Each variant has a different shape (`tool_call` has `toolCallId`, `plan` has
  `entries`, `turn_end` has `reason`, etc.). Pre-extracting them here would
  bake the ACP wire schema into our struct and create churn every time the
  protocol gains a field. Consumers that need a specific field read it from
  `raw["update"][...]`. The kind atom is enough for routing.
  """

  @typedoc "Atomized session/update discriminator."
  @type kind ::
          :agent_message_chunk
          | :agent_thought_chunk
          | :user_message_chunk
          | :tool_call
          | :tool_call_update
          | :plan
          | :current_mode_update
          | :config_option_update
          | :turn_end
          | :unknown

  @type t :: %__MODULE__{
          kind: kind(),
          type: String.t() | nil,
          session_id: String.t() | nil,
          sequence: non_neg_integer(),
          occurred_at: DateTime.t(),
          raw: map()
        }

  @enforce_keys [:kind, :sequence, :occurred_at, :raw]
  defstruct [:kind, :type, :session_id, :sequence, :occurred_at, :raw]

  @known %{
    "agent_message_chunk" => :agent_message_chunk,
    "agent_thought_chunk" => :agent_thought_chunk,
    "user_message_chunk" => :user_message_chunk,
    "tool_call" => :tool_call,
    "tool_call_update" => :tool_call_update,
    "plan" => :plan,
    "current_mode_update" => :current_mode_update,
    "config_option_update" => :config_option_update,
    "turn_end" => :turn_end
  }

  @doc """
  Returns the closed map of recognised `sessionUpdate` strings → atom kinds.

  Anything not in this map normalizes to `:unknown`. Use this in tests
  rather than hard-coding the list — it's the single source of truth.
  """
  @spec known_kinds() :: %{String.t() => kind()}
  def known_kinds, do: @known

  @doc """
  Normalize an inbound `session/update` notification's `params` into a `t()`.

  `params` is the JSON-decoded `params` field of the notification (the map
  shaped like `%{"sessionId" => "...", "update" => %{"sessionUpdate" => ...}}`).
  Anything missing or malformed degrades gracefully to `kind: :unknown` —
  the runtime never crashes on a weird agent payload, it just labels it.

  `sequence` is supplied by the caller (the `KiroSession` GenServer) so this
  function stays pure and easy to test in isolation.
  """
  @spec normalize(map(), non_neg_integer(), DateTime.t()) :: t()
  def normalize(params, sequence, occurred_at)
      when is_map(params) and is_integer(sequence) and sequence >= 0 do
    {kind, type} = classify(params)
    session_id = extract_session_id(params)

    %__MODULE__{
      kind: kind,
      type: type,
      session_id: session_id,
      sequence: sequence,
      occurred_at: occurred_at,
      raw: params
    }
  end

  # -- Internals ------------------------------------------------------------

  @spec classify(map()) :: {kind(), String.t() | nil}
  defp classify(%{"update" => %{"sessionUpdate" => type}}) when is_binary(type) do
    {Map.get(@known, type, :unknown), type}
  end

  defp classify(%{"update" => %{"sessionUpdate" => _malformed}}) do
    # `sessionUpdate` present but not a string. We mark `:unknown` and
    # store `nil` in the public `:type` field to honour the
    # `String.t() | nil` contract; the malformed value is still
    # preserved verbatim under `:raw["update"]["sessionUpdate"]` for
    # debugging or replay.
    {:unknown, nil}
  end

  defp classify(_params), do: {:unknown, nil}

  @spec extract_session_id(map()) :: String.t() | nil
  defp extract_session_id(%{"sessionId" => sid}) when is_binary(sid), do: sid
  defp extract_session_id(_), do: nil
end
