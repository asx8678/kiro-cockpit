defmodule KiroCockpit.Swarm.Hooks.SteeringPreActionHook do
  @moduledoc """
  Deterministic steering pre-action hook.

  Per §27.7, this hook evaluates action relevance using deterministic signals
  (not LLM). It honors context/payload signals such as:
  - off-topic/drift/guide/relevance/task mismatch
  - category blocks
  - explicit steering decisions in event metadata

  Produces continue/focus/guide/block messages for downstream UI.

  Priority: 95 (pre-action, can block)
  """

  @behaviour KiroCockpit.Swarm.Hook

  alias KiroCockpit.Swarm.{Event, HookResult}

  @impl true
  def name, do: :steering_pre_action

  @impl true
  def priority, do: 95

  @impl true
  def filter(%Event{action_name: action}) do
    # Apply to all actions that could need steering
    action in [:read, :write, :shell_read, :shell_write, :terminal, :external, :destructive]
  end

  @impl true
  def on_event(event, ctx) do
    # Check for deterministic steering signals in metadata or payload
    case check_deterministic_signals(event, ctx) do
      {:focus, message} ->
        HookResult.modify(event, [message], hook_metadata: %{steering_decision: :focus})

      {:guide, message} ->
        HookResult.modify(event, [message], hook_metadata: %{steering_decision: :guide})

      {:block, reason, guidance} ->
        HookResult.block(event, reason, [guidance], hook_metadata: %{steering_decision: :block})

      :no_signal ->
        # No deterministic signal found, continue
        HookResult.continue(event)
    end
  end

  defp check_deterministic_signals(event, _ctx) do
    metadata = event.metadata
    payload = event.payload

    cond do
      # Explicit block signal
      Map.get(metadata, :steering_decision) == :block ->
        reason = Map.get(metadata, :block_reason, "Action blocked by steering")
        guidance = Map.get(metadata, :block_guidance, "Action is off-topic or unsafe.")
        {:block, reason, guidance}

      # Explicit off-topic signal
      Map.get(metadata, :off_topic) == true ->
        reason = "Action is off-topic"

        guidance =
          Map.get(
            metadata,
            :off_topic_guidance,
            "This action is not related to the current task."
          )

        {:block, reason, guidance}

      # Explicit drift signal
      Map.get(metadata, :drift) == true ->
        message = Map.get(metadata, :drift_message, "Action is drifting from the main task.")
        {:focus, message}

      # Explicit guide signal
      Map.get(metadata, :guide) == true ->
        message = Map.get(metadata, :guide_message, "Consider related context or memory.")
        {:guide, message}

      # Task mismatch signal
      Map.get(metadata, :task_mismatch) == true ->
        reason = "Task mismatch"

        guidance =
          Map.get(metadata, :task_mismatch_guidance, "Action does not match the active task.")

        {:block, reason, guidance}

      # Check payload for steering signals
      Map.get(payload, :steering_decision) == :block ->
        reason = Map.get(payload, :block_reason, "Action blocked by steering")
        guidance = Map.get(payload, :block_guidance, "Action is off-topic or unsafe.")
        {:block, reason, guidance}

      # No deterministic signals found
      true ->
        :no_signal
    end
  end
end
