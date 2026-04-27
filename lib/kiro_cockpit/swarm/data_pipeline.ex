defmodule KiroCockpit.Swarm.DataPipeline do
  @moduledoc """
  Bronze/Silver/Gold data pipeline entry point for Swarm events (§27.10).

  This module provides a unified interface for Bronze capture of:

    * Action lifecycle events (action_before, action_after, action_blocked)
    * ACP (Agent Communication Protocol) events
    * Hook traces (via existing HookTrace module)

  ## Bronze Capture (§27.10, §27.11)

  Bronze is the raw event capture layer that feeds Silver analyzers and
  Gold memory promotion. Per §27.11 invariant 7, Bronze captures every
  event including blocked attempts. Per §27.11 invariant 8, every event
  carries correlation to trace back to plan_id and task_id.

  ## Modules

    * `BronzeAction` — action lifecycle capture (action_before, action_after, action_blocked)
    * `BronzeAcp` — ACP event capture (acp_update, acp_request, acp_response, acp_notification)

  ## Configuration

    * `:bronze_full_payload_capture` — capture full payloads instead of summaries
      (default: false, enable only for debugging)
    * `:bronze_action_capture_enabled` — gates `record_action_lifecycle/3`:
      when false, the convenience wrapper skips before/after recording.
      `ActionBoundary.run/3` records Bronze action events unconditionally
      regardless of this flag. (default: true)
    * `:bronze_acp_capture_enabled` — **reporting-only toggle**: when false,
      downstream consumers should skip ACP event analysis. This is NOT a
      runtime kill switch — `KiroSession.persist_bronze_acp/3` runs
      UNCONDITIONALLY regardless of both `persist_messages` and this flag.
      Bronze ACP capture is MANDATORY at all times.
      (default: true)

  **Important:** Setting `:bronze_acp_capture_enabled` to `false` does NOT
  prevent `KiroSession` from persisting Bronze ACP events. It only signals
  to reporting/analytics code that ACP capture should be treated as
  disabled for display purposes. Neither does setting `persist_messages: false`
  — Bronze ACP capture is independent of both (§kiro-buk).

  ## Privacy

  By default, payloads are summarized (keys, size hints) rather than captured
  in full to protect sensitive data. Full capture can be enabled per-call
  with `safe: true` or globally for development.
  """

  alias KiroCockpit.Swarm.DataPipeline.{BronzeAcp, BronzeAction}
  alias KiroCockpit.Swarm.Event

  # Action lifecycle capture -------------------------------------------------

  @doc """
  Record an action_before event.

  See `BronzeAction.record_before/2` for details.
  """
  defdelegate record_action_before(event, ctx \\ %{}), to: BronzeAction, as: :record_before

  @doc """
  Record an action_after event.

  See `BronzeAction.record_after/3` for details.
  """
  defdelegate record_action_after(event, result, ctx \\ %{}), to: BronzeAction, as: :record_after

  @doc """
  Record an action_blocked event.

  See `BronzeAction.record_blocked/5` for details.
  """
  defdelegate record_action_blocked(event, reason, messages, ctx \\ %{}, opts \\ []),
    to: BronzeAction,
    as: :record_blocked

  @doc """
  List Bronze action events for a session.
  """
  defdelegate list_action_events(session_id, opts \\ []), to: BronzeAction, as: :list_actions

  @doc """
  List Bronze action events for a plan.
  """
  defdelegate list_action_events_by_plan(plan_id, opts \\ []),
    to: BronzeAction,
    as: :list_actions_by_plan

  @doc """
  List Bronze action events for a task.
  """
  defdelegate list_action_events_by_task(task_id, opts \\ []),
    to: BronzeAction,
    as: :list_actions_by_task

  # ACP event capture --------------------------------------------------------

  @doc """
  Record an ACP update event.

  See `BronzeAcp.record_acp_update/1` for details.
  """
  defdelegate record_acp_update(attrs), to: BronzeAcp

  @doc """
  Record an ACP request (JSON-RPC request message, either direction).

  See `BronzeAcp.record_acp_request/4` for details.
  """
  defdelegate record_acp_request(session_id, agent_id, payload, opts \\ []), to: BronzeAcp

  @doc """
  Record an ACP response (JSON-RPC response/error message, either direction).

  See `BronzeAcp.record_acp_response/4` for details.
  """
  defdelegate record_acp_response(session_id, agent_id, payload, opts \\ []), to: BronzeAcp

  @doc """
  Record an ACP notification.

  See `BronzeAcp.record_acp_notification/4` for details.
  """
  defdelegate record_acp_notification(session_id, agent_id, payload, opts \\ []), to: BronzeAcp

  @doc """
  List Bronze ACP events for a session.
  """
  defdelegate list_acp_events(session_id, opts \\ []), to: BronzeAcp

  @doc """
  List Bronze ACP events for a plan.
  """
  defdelegate list_acp_by_plan(plan_id, opts \\ []), to: BronzeAcp

  @doc """
  List Bronze ACP events for a task.
  """
  defdelegate list_acp_by_task(task_id, opts \\ []), to: BronzeAcp

  @doc """
  List Bronze ACP events by method.
  """
  defdelegate list_acp_by_method(session_id, method, opts \\ []),
    to: BronzeAcp,
    as: :list_by_method

  @doc """
  List Bronze ACP events by direction.
  """
  defdelegate list_acp_by_direction(session_id, direction, opts \\ []),
    to: BronzeAcp,
    as: :list_by_direction

  # Feature flags ------------------------------------------------------------

  @doc """
  Returns true if action_before/action_after capture reporting is enabled.

  This is a reporting/test-compatibility flag, NOT a runtime kill switch.
  KiroSession persists Bronze action events whenever `persist_messages`
  is true regardless of this flag's value.
  """
  @spec action_capture_enabled?() :: boolean()
  def action_capture_enabled? do
    Application.get_env(:kiro_cockpit, :bronze_action_capture_enabled, true)
  end

  @doc """
  Returns true if ACP event capture reporting is enabled.

  This is a reporting/test-compatibility flag, NOT a runtime kill switch.
  KiroSession persists Bronze ACP events UNCONDITIONALLY regardless of
  both `persist_messages` and this flag (§kiro-buk). Setting this to
  false only signals downstream consumers (analytics, dashboards) to
  skip ACP analysis — it does NOT prevent persistence.
  """
  @spec acp_capture_enabled?() :: boolean()
  def acp_capture_enabled? do
    Application.get_env(:kiro_cockpit, :bronze_acp_capture_enabled, true)
  end

  @doc """
  Returns true if full payload capture is enabled globally.
  """
  @spec full_payload_capture?() :: boolean()
  def full_payload_capture? do
    Application.get_env(:kiro_cockpit, :bronze_full_payload_capture, false)
  end

  # Convenience helpers ----------------------------------------------------

  @doc """
  Record a complete action lifecycle: before, execution, and after.

  This is a convenience wrapper that handles the common pattern of:

    1. Record action_before
    2. Execute the function
    3. Record action_after (or action_blocked on failure)

  ## Example

      DataPipeline.record_action_lifecycle(
        event,
        fn -> perform_work() end,
        %{plan_id: plan_id, task_id: task_id}
      )
  """
  @spec record_action_lifecycle(Event.t(), (-> result), map()) ::
          {:ok, result} | {:error, term()}
        when result: term()
  def record_action_lifecycle(%Event{} = event, fun, ctx \\ %{}) when is_function(fun, 0) do
    # Record before
    if action_capture_enabled?() do
      record_action_before(event, ctx)
    end

    # Execute
    result = fun.()

    # Record after (or blocked)
    if action_capture_enabled?() do
      record_action_after(event, normalize_result(result), ctx)
    end

    result
  end

  # Normalize various result shapes to the expected format
  defp normalize_result({:ok, _} = ok), do: ok
  defp normalize_result({:error, _} = err), do: err
  defp normalize_result(:ok), do: {:ok, nil}
  defp normalize_result(:error), do: {:error, :unknown}
  defp normalize_result(other), do: {:ok, other}
end
