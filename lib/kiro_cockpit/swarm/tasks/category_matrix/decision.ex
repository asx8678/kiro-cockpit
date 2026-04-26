defmodule KiroCockpit.Swarm.Tasks.CategoryMatrix.Decision do
  @moduledoc """
  A single category × permission decision from the gating matrix.

  ## Fields

    - `verdict`   — `:allow`, `:ask`, or `:block`
    - `reason`    — human-readable explanation of the verdict
    - `guidance`  — optional guidance for the agent/operator when denied
    - `condition` — optional atom; when the caller passes `condition: true`
                    in opts, the verdict is promoted one level
  """

  @type verdict :: :allow | :ask | :block
  @type t :: %__MODULE__{
          verdict: verdict(),
          reason: String.t(),
          guidance: String.t() | nil,
          condition: atom() | nil
        }

  @enforce_keys [:verdict, :reason]
  defstruct [:verdict, :reason, :guidance, :condition]
end
