defmodule KiroCockpit.Swarm.Hooks.ToolResultAnalysisHook do
  @moduledoc """
  Runs analyzers on Kiro ACP results and tool outputs.

  Per §27.2, this post-action hook (priority 90, non-blocking) inspects
  tool/ACP result payloads for patterns that merit attention:

    - **Error patterns**: detects error responses, error codes, stack traces
    - **Test results**: detects test run output, pass/fail counts
    - **Validation candidates**: detects lint output, type check results,
      compiler warnings — things that should trigger verification tasks

  ## How it works

  The hook reads the event's `payload` and `raw_payload` maps, looking
  for common result keys (`:result`, `:output`, `:error`, `:status`,
  `:test_results`, `:exit_code`). When patterns are detected, it
  injects informational messages so the steering/planning layer can
  act on them.

  ## Trusted context

  `ctx[:tool_result_overrides]` can provide a map of pattern overrides
  for project-specific analysis. When present, these override keys are
  merged into the standard analysis keys.

  Priority: 90 (post-action, non-blocking)
  """

  @behaviour KiroCockpit.Swarm.Hook

  alias KiroCockpit.Swarm.{Event, HookResult}

  @tool_result_actions [
    :kiro_session_prompt,
    :kiro_tool_call_detected,
    :verification_run,
    :shell_write,
    :shell_write_requested,
    :terminal,
    :terminal_requested,
    :shell_read,
    :shell_read_requested
  ]

  @error_indicators ~w(error failed failure exception traceback stacktrace)
  @test_indicators ~w(test tests spec pass fail passed failed passing failing)
  @validation_indicators ~w(lint warning warn compile type_check typecheck format credo dialyzer)

  @impl true
  def name, do: :tool_result_analysis

  @impl true
  def priority, do: 90

  @impl true
  def filter(%Event{action_name: action}) do
    action in @tool_result_actions
  end

  @impl true
  def on_event(event, ctx) do
    findings = analyze(event, ctx)

    if findings == [] do
      HookResult.continue(event)
    else
      HookResult.continue(event, findings,
        hook_metadata: %{tool_result_findings: true, finding_count: length(findings)}
      )
    end
  end

  defp analyze(event, ctx) do
    payload = event.payload || %{}
    raw_payload = event.raw_payload || %{}

    overrides =
      Map.get(ctx, :tool_result_overrides) || Map.get(ctx, "tool_result_overrides") || %{}

    combined = Map.merge(payload, raw_payload)

    []
    |> detect_errors(combined)
    |> detect_test_results(combined)
    |> detect_validation_candidates(combined)
    |> detect_exit_code(combined)
    |> apply_overrides(combined, overrides)
  end

  defp detect_errors(messages, data) do
    case find_indicator(data, @error_indicators) do
      {key, value} ->
        messages ++
          ["🔍 Tool result: Error detected in '#{key}' — #{truncate(value, 120)}"]

      nil ->
        messages
    end
  end

  defp detect_test_results(messages, data) do
    case find_indicator(data, @test_indicators) do
      {key, value} ->
        messages ++
          ["🔍 Tool result: Test output detected in '#{key}' — #{truncate(value, 120)}"]

      nil ->
        messages
    end
  end

  defp detect_validation_candidates(messages, data) do
    case find_indicator(data, @validation_indicators) do
      {key, value} ->
        messages ++
          ["🔍 Tool result: Validation candidate found in '#{key}' — #{truncate(value, 120)}"]

      nil ->
        messages
    end
  end

  defp detect_exit_code(messages, data) do
    exit_code = Map.get(data, :exit_code) || Map.get(data, "exit_code")

    if exit_code != nil and exit_code != 0 do
      messages ++
        ["🔍 Tool result: Non-zero exit code (#{exit_code}) — check for errors"]
    else
      messages
    end
  end

  defp apply_overrides(messages, data, overrides) when map_size(overrides) > 0 do
    Enum.reduce(overrides, messages, fn {key, pattern}, acc ->
      key_atom = to_atom_key(key)
      key_string = to_string_key(key)
      value = Map.get(data, key_atom) || Map.get(data, key_string)

      if value != nil and matches_pattern?(value, pattern) do
        display_key = if is_atom(key), do: key, else: key

        acc ++
          ["🔍 Tool result: Override pattern '#{display_key}' matched — #{truncate(value, 100)}"]
      else
        acc
      end
    end)
  end

  defp apply_overrides(messages, _data, _overrides), do: messages

  defp to_atom_key(key) when is_atom(key), do: key
  defp to_atom_key(key) when is_binary(key), do: String.to_atom(key)
  defp to_atom_key(_), do: nil

  defp to_string_key(key) when is_binary(key), do: key
  defp to_string_key(key) when is_atom(key), do: Atom.to_string(key)
  defp to_string_key(_), do: nil

  defp find_indicator(data, indicators) do
    data
    |> Enum.find_value(fn {key, value} ->
      str_value = stringify(value)

      if str_value != nil and
           Enum.any?(indicators, fn indicator ->
             String.contains?(String.downcase(str_value), indicator)
           end) do
        {key, str_value}
      end
    end)
  end

  defp matches_pattern?(value, pattern) when is_binary(pattern) do
    String.contains?(String.downcase(stringify(value) || ""), String.downcase(pattern))
  end

  defp matches_pattern?(value, %Regex{} = regex) do
    Regex.match?(regex, stringify(value) || "")
  end

  defp matches_pattern?(_value, _pattern), do: false

  defp stringify(value) when is_binary(value), do: value
  defp stringify(value) when is_integer(value), do: Integer.to_string(value)
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value) when is_list(value), do: Enum.join(value, ", ")
  defp stringify(_), do: nil

  defp truncate(str, max_len) when is_binary(str) and byte_size(str) > max_len do
    String.slice(str, 0, max_len) <> "..."
  end

  defp truncate(str, _max_len), do: str
end
