defmodule KiroCockpit.Swarm.Hooks.LocalFindingsHook do
  @moduledoc """
  Persists local findings before LLM scoring.

  Per §27.2, this post-action hook (priority 85, non-blocking) captures
  structured findings from event payloads and persists them as Bronze
  swarm events of type `"local_finding"`. These findings feed the
  Silver/Gold analysis pipeline — the LLM scorer reads them in batch
  to produce scored, promoted findings.

  ## What gets persisted

  The hook looks for finding-like data in `event.payload` and
  `event.metadata` under these keys:

    - `:findings` — a list of maps, each with at least a `"type"` and
      `"description"` field
    - `:error_findings` — a map or list of error-related findings
    - `:pattern_findings` — a map or list of pattern match findings

  When no finding data is present, the hook is a quiet no-op.

  ## Persistence

  Findings are persisted as Bronze swarm events with:

    - `event_type`: `"local_finding"`
    - `session_id`, `plan_id`, `task_id`, `agent_id`: carried from
      the originating event
    - `payload`: the normalized finding map(s)
    - `phase`: `"post"`

  Persistence failures are caught and emitted as telemetry — the hook
  chain never crashes due to a persistence error.

  ## Suppression

  Set `ctx[:local_findings_suppressed]` to `true` to skip persistence
  (useful in test isolation).

  Priority: 85 (post-action, non-blocking)
  """

  @behaviour KiroCockpit.Swarm.Hook

  alias KiroCockpit.Swarm.{Event, Events, HookResult}
  alias KiroCockpit.Telemetry

  @finding_actions [
    :kiro_session_prompt,
    :kiro_tool_call_detected,
    :verification_run,
    :write,
    :file_write_requested,
    :file_edit_requested,
    :write_file,
    :shell_write,
    :shell_write_requested,
    :terminal,
    :terminal_requested,
    :fs_write_requested,
    :shell_read,
    :shell_read_requested,
    :read,
    :fs_read_requested
  ]

  @impl true
  def name, do: :local_findings

  @impl true
  def priority, do: 85

  @impl true
  def filter(%Event{action_name: action}) do
    action in @finding_actions
  end

  @impl true
  def on_event(event, ctx) do
    if suppressed?(ctx) do
      HookResult.continue(event)
    else
      findings = extract_findings(event)

      if findings == [] do
        HookResult.continue(event)
      else
        persist_findings(event, findings)

        HookResult.continue(
          event,
          ["📊 Local findings: #{length(findings)} finding(s) persisted for analysis"],
          hook_metadata: %{findings_persisted: length(findings)}
        )
      end
    end
  end

  defp extract_findings(event) do
    payload = event.payload || %{}
    metadata = event.metadata || %{}

    explicit_findings(payload) ++
      error_findings(payload) ++
      pattern_findings(payload) ++
      explicit_findings(metadata) ++
      error_findings(metadata) ++
      pattern_findings(metadata)
  end

  defp explicit_findings(map) do
    case Map.get(map, :findings) || Map.get(map, "findings") do
      findings when is_list(findings) ->
        Enum.filter(findings, &valid_finding?/1)

      _ ->
        []
    end
  end

  defp error_findings(map) do
    case Map.get(map, :error_findings) || Map.get(map, "error_findings") do
      findings when is_list(findings) ->
        Enum.map(findings, &normalize_finding(&1, "error"))

      finding when is_map(finding) ->
        [normalize_finding(finding, "error")]

      _ ->
        []
    end
  end

  defp pattern_findings(map) do
    case Map.get(map, :pattern_findings) || Map.get(map, "pattern_findings") do
      findings when is_list(findings) ->
        Enum.map(findings, &normalize_finding(&1, "pattern"))

      finding when is_map(finding) ->
        [normalize_finding(finding, "pattern")]

      _ ->
        []
    end
  end

  defp valid_finding?(finding) when is_map(finding) do
    Map.has_key?(finding, "type") or Map.has_key?(finding, :type) or
      Map.has_key?(finding, "description") or Map.has_key?(finding, :description)
  end

  defp valid_finding?(_), do: false

  defp normalize_finding(finding, default_type) when is_map(finding) do
    type = Map.get(finding, "type") || Map.get(finding, :type) || default_type
    description = Map.get(finding, "description") || Map.get(finding, :description) || ""

    %{type: type, description: description, source: "local_findings_hook"}
    |> maybe_add_key(finding, "severity")
    |> maybe_add_key(finding, "file")
    |> maybe_add_key(finding, "line")
  end

  defp normalize_finding(_, default_type) do
    %{type: default_type, description: "", source: "local_findings_hook"}
  end

  defp maybe_add_key(acc, source, key) do
    value = Map.get(source, key) || Map.get(source, String.to_atom(key))

    if value != nil do
      Map.put(acc, String.to_atom(key), value)
    else
      acc
    end
  end

  defp persist_findings(event, findings) do
    Enum.each(findings, fn finding ->
      attrs = %{
        session_id: event.session_id,
        plan_id: event.plan_id,
        task_id: event.task_id,
        agent_id: event.agent_id,
        event_type: "local_finding",
        phase: "post",
        payload: finding,
        raw_payload: %{},
        hook_results: []
      }

      case Events.create_event(attrs) do
        {:ok, _} ->
          :ok

        {:error, error} ->
          emit_persistence_error(error)
      end
    end)
  end

  defp emit_persistence_error(error) do
    event = Telemetry.event(:hook, :local_finding_persistence, :exception)
    Telemetry.execute(event, %{count: 1}, %{error: inspect(error)})
  rescue
    _ -> :ok
  end

  defp suppressed?(ctx) do
    truthy?(Map.get(ctx, :local_findings_suppressed)) or
      truthy?(Map.get(ctx, "local_findings_suppressed"))
  end

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_), do: false
end
