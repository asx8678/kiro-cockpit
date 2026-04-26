defmodule KiroCockpit.Swarm.SteeringAgent do
  @moduledoc """
  LLM-backed steering evaluator for `kiro_cockpit` (§27.7).

  Runs AFTER deterministic category/task gates. Decides whether an action is
  relevant to the active task and approved plan.

  Decisions:

    - `:continue` — on-task; allow silently
    - `:focus`    — slight drift; allow but inject reminder
    - `:guide`    — known context; allow and inject memory/rule/project reference
    - `:block`    — off-topic/contradictory/unsafe; hard stop with alternative

  Strict JSON output is required. Invalid or missing fields trigger
  deterministic-safe fallback (`:continue`, source `:fallback`).

  ## Injectable model

  For testing, pass `:steering_model` in `opts` — any module implementing
  `generate/2` that accepts a prompt string and opts, returning
  `{:ok, output}` or `{:error, reason}`.

  Alternatively, pass `:kiro_session_module` and `:session` to call
  `KiroCockpit.KiroSession.prompt/3`.

  If neither is provided and no application config is set, the agent
  returns fallback immediately (no blocking — deterministic gates have
  already run).
  """

  alias KiroCockpit.Swarm.SteeringAgent.Decision

  @decision_by_string %{
    "continue" => :continue,
    "focus" => :focus,
    "guide" => :guide,
    "block" => :block
  }

  @risk_level_by_string %{
    "low" => :low,
    "medium" => :medium,
    "high" => :high
  }

  @valid_decisions Map.values(@decision_by_string)
  @valid_risk_levels Map.values(@risk_level_by_string)

  # -------------------------------------------------------------------
  # Decision struct
  # -------------------------------------------------------------------

  defmodule Decision do
    @moduledoc """
    Normalized steering decision returned by the SteeringAgent.

    ## Fields

      - `:decision`            — `:continue | :focus | :guide | :block`
      - `:reason`              — non-empty string
      - `:suggested_next_action` — nil or string
      - `:memory_refs`         — list (max 3 items)
      - `:risk_level`         — `:low | :medium | :high`
      - `:source`             — `:llm | :fallback`
    """

    @type decision :: :continue | :focus | :guide | :block
    @type risk_level :: :low | :medium | :high
    @type source :: :llm | :fallback

    @type t :: %__MODULE__{
            decision: decision(),
            reason: String.t(),
            suggested_next_action: String.t() | nil,
            memory_refs: [String.t()],
            risk_level: risk_level(),
            source: source()
          }

    @enforce_keys [:decision, :reason, :risk_level, :source]
    defstruct decision: nil,
              reason: nil,
              suggested_next_action: nil,
              memory_refs: [],
              risk_level: nil,
              source: nil
  end

  # -------------------------------------------------------------------
  # Public API
  # -------------------------------------------------------------------

  @doc """
  Evaluate an event against the active task/plan context using LLM steering.

  Returns `{:ok, %Decision{}}`. Model and validation failures are represented as
  fallback decisions (`source: :fallback`), not errors, so steering infrastructure
  never blocks solely because the LLM is unavailable.

  ## Options

    - `:steering_model` — module with `generate/2` (prompt, opts → `{:ok, output}` | `{:error, reason}`)
    - `:kiro_session_module` + `:session` — uses `KiroSession.prompt/3`
    - `:prompt_path` — override the prompt file path (default: `priv/prompts/swarm_steering_prompt.md`)
  """
  @spec evaluate(map(), map(), keyword()) :: {:ok, Decision.t()}
  def evaluate(event, ctx, opts \\ []) do
    opts = merge_context_opts(ctx, opts)
    prompt_template = read_prompt(opts)
    context_json = build_context_json(event, ctx)
    full_prompt = prompt_template <> "\n\n## Context\n\n```json\n" <> context_json <> "\n```\n"

    case call_model(full_prompt, opts) do
      {:ok, raw_output} ->
        parse_and_validate(raw_output)

      {:error, reason} ->
        {:ok, fallback_decision("LLM unavailable: #{reason}")}
    end
  end

  @doc """
  Returns a deterministic-safe fallback decision.

  Per spec: do NOT block only because the LLM failed — deterministic
  gates have already run. Fallback is `:continue` with `:low` risk.
  """
  @spec fallback_decision(String.t()) :: Decision.t()
  def fallback_decision(reason) do
    %Decision{
      decision: :continue,
      reason: "Steering fallback: #{reason}",
      suggested_next_action: nil,
      memory_refs: [],
      risk_level: :low,
      source: :fallback
    }
  end

  defp merge_context_opts(ctx, opts) do
    ctx_opts =
      [:steering_model, :kiro_session_module, :session]
      |> Enum.flat_map(fn key ->
        case Map.get(ctx, key) do
          nil -> []
          value -> [{key, value}]
        end
      end)

    ctx_steering_opts = Map.get(ctx, :steering_opts, [])

    ctx_opts
    |> Keyword.merge(ctx_steering_opts)
    |> Keyword.merge(opts)
  end

  # -------------------------------------------------------------------
  # Prompt reading
  # -------------------------------------------------------------------

  defp read_prompt(opts) do
    path = Keyword.get(opts, :prompt_path, default_prompt_path())

    case File.read(path) do
      {:ok, content} -> content
      {:error, _} -> build_inline_prompt()
    end
  end

  defp default_prompt_path do
    case :code.priv_dir(:kiro_cockpit) do
      {:error, _} -> Path.join("priv", "prompts/swarm_steering_prompt.md")
      dir -> Path.join(dir, "prompts/swarm_steering_prompt.md")
    end
  end

  # Inline fallback prompt if file is missing (shouldn't happen in prod)
  defp build_inline_prompt do
    """
    # Swarm Steering Prompt

    You are the Ring 2 steering evaluator for `kiro_cockpit`.
    Decide whether the requested action is relevant to the active task and approved plan.

    Return STRICT JSON ONLY — no markdown, no comments, no extra text.

    ```json
    {
      "decision": "continue | focus | guide | block",
      "reason": "one concise sentence",
      "suggested_next_action": "optional concise guidance or null",
      "memory_refs": [],
      "risk_level": "low | medium | high"
    }
    ```

    Rules:
    - Do NOT override deterministic category blocks.
    - Block actions outside the active plan scope.
    - Focus when the action is probably useful but drifting.
    - Guide when a memory, project rule, or previous finding would help.
    - Continue only when clearly aligned.
    """
  end

  # -------------------------------------------------------------------
  # Context building
  # -------------------------------------------------------------------

  defp build_context_json(event, ctx) do
    context = %{
      action: %{
        name: event_field(event, :action_name),
        parameters: event_field(event, :payload, %{}),
        session_id: event_field(event, :session_id),
        agent_id: event_field(event, :agent_id),
        task_id: event_field(event, :task_id),
        plan_id: event_field(event, :plan_id)
      },
      active_task: extract_active_task(ctx),
      plan: extract_plan(ctx),
      task_history: safe_list(ctx, :task_history),
      completed_tasks: safe_list(ctx, :completed_tasks),
      recent_conversation: safe_list(ctx, :recent_conversation),
      permission_policy: safe_map(ctx, :permission_policy),
      project_rules: safe_list(ctx, :project_rules),
      gold_memories: safe_list(ctx, :gold_memories),
      artifacts: safe_list(ctx, :artifacts),
      tools_used: safe_list(ctx, :tools_used)
    }

    # Remove nil values for cleaner JSON
    context
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
    |> Jason.encode!(pretty: true)
  end

  defp event_field(event, key, default \\ nil) do
    Map.get(event, key) || Map.get(event, Atom.to_string(key), default)
  end

  defp extract_active_task(%{active_task: task}) when is_map(task) do
    %{
      title: map_field(task, :content),
      category: map_field(task, :category),
      status: map_field(task, :status),
      description: map_field(task, :notes),
      acceptance_criteria: map_field(task, :acceptance_criteria),
      permission_scope: map_field(task, :permission_scope)
    }
  end

  defp extract_active_task(_ctx), do: nil

  defp extract_plan(%{plan: plan}) when is_map(plan) do
    %{
      phase: map_field(plan, :phase),
      acceptance_criteria: map_field(plan, :acceptance_criteria)
    }
  end

  defp extract_plan(_ctx), do: nil

  defp map_field(map, key, default \\ nil) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key), default)
  end

  defp safe_list(ctx, key) do
    case Map.get(ctx, key) do
      nil -> nil
      list when is_list(list) -> list
      _ -> nil
    end
  end

  defp safe_map(ctx, key) do
    case Map.get(ctx, key) do
      nil -> nil
      map when is_map(map) -> map
      _ -> nil
    end
  end

  # -------------------------------------------------------------------
  # Model invocation
  # -------------------------------------------------------------------

  defp call_model(prompt, opts) do
    cond do
      model = Keyword.get(opts, :steering_model) ->
        invoke_model(model, prompt, opts)

      session_mod = Keyword.get(opts, :kiro_session_module) ->
        session = Keyword.get(opts, :session)

        if session do
          try do
            case session_mod.prompt(session, prompt, opts) do
              {:ok, response} -> {:ok, response}
              {:error, reason} -> {:error, inspect(reason)}
            end
          rescue
            e -> {:error, Exception.message(e)}
          end
        else
          {:error, "no session provided"}
        end

      app_model = Application.get_env(:kiro_cockpit, :steering_model) ->
        invoke_model(app_model, prompt, opts)

      true ->
        {:error, "no steering model configured"}
    end
  end

  # -------------------------------------------------------------------
  # Parsing and validation
  # -------------------------------------------------------------------

  defp parse_and_validate(raw_output) when is_map(raw_output) do
    cond do
      Map.has_key?(raw_output, "decision") ->
        validate_or_fallback(raw_output)

      Map.has_key?(raw_output, :decision) ->
        raw_output
        |> atom_keys_to_strings()
        |> validate_or_fallback()

      content = content_from_map(raw_output) ->
        parse_and_validate(content)

      true ->
        {:ok, fallback_decision("Invalid LLM output: map has no decision/content")}
    end
  end

  defp parse_and_validate(raw_output) when is_binary(raw_output) do
    with {:ok, json_str} <- strip_json_fences(raw_output),
         {:ok, parsed} <- Jason.decode(json_str),
         {:ok, decision} <- validate_decision(parsed) do
      {:ok, decision}
    else
      {:error, %Jason.DecodeError{} = e} ->
        {:ok, fallback_decision("Invalid JSON: #{inspect(e.position)}")}

      {:error, reason} ->
        {:ok, fallback_decision("Invalid LLM output: #{inspect(reason)}")}
    end
  end

  defp parse_and_validate(_raw_output) do
    {:ok, fallback_decision("Invalid LLM output: unsupported response type")}
  end

  defp validate_or_fallback(parsed) do
    case validate_decision(parsed) do
      {:ok, decision} -> {:ok, decision}
      {:error, reason} -> {:ok, fallback_decision("Invalid LLM output: #{inspect(reason)}")}
    end
  end

  defp atom_keys_to_strings(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp content_from_map(map) do
    map
    |> content_candidates()
    |> Enum.find(&is_binary/1)
  end

  defp content_candidates(map) do
    [
      Map.get(map, :content),
      Map.get(map, "content"),
      nested_content_text(Map.get(map, :content), :atom),
      nested_content_text(Map.get(map, "content"), :string)
    ]
  end

  defp nested_content_text(%{text: text}, :atom), do: text
  defp nested_content_text(%{"text" => text}, :string), do: text
  defp nested_content_text(_content, _kind), do: nil

  @doc """
  Strip markdown code fences from raw model output.

  Handles ```json ... ``` and ``` ... ``` wrapping that some models add
  despite instructions.
  """
  @spec strip_json_fences(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def strip_json_fences(raw) when is_binary(raw) do
    raw
    |> String.trim()
    |> extract_json_payload()
  end

  defp extract_json_payload(trimmed) do
    case extract_fenced_json(trimmed) do
      {:ok, json} -> {:ok, json}
      :error -> extract_unfenced_json(trimmed)
    end
  end

  defp extract_fenced_json(trimmed) do
    case Regex.run(~r/```(?:json)?\s*\n?(.*?)\n?\s*```/s, trimmed) do
      [_, inner] -> {:ok, String.trim(inner)}
      nil -> :error
    end
  end

  defp extract_unfenced_json(trimmed) do
    if String.starts_with?(trimmed, "{") do
      extract_first_json_object(trimmed)
    else
      extract_json_slice(trimmed)
    end
  end

  defp extract_json_slice(trimmed) do
    with start_idx when not is_nil(start_idx) <- find_index(trimmed, "{"),
         end_idx when not is_nil(end_idx) <- find_last_index(trimmed, "}"),
         true <- end_idx > start_idx do
      {:ok, String.slice(trimmed, start_idx, end_idx - start_idx + 1)}
    else
      _ -> {:error, "no parseable JSON found"}
    end
  end

  defp validate_decision(parsed) when is_map(parsed) do
    with {:ok, decision_atom} <- validate_decision_field(parsed),
         {:ok, reason} <- validate_reason(parsed),
         {:ok, risk_level} <- validate_risk_level(parsed) do
      suggested = validate_suggested_next_action(parsed)
      memory_refs = validate_memory_refs(parsed)

      {:ok,
       %Decision{
         decision: decision_atom,
         reason: reason,
         suggested_next_action: suggested,
         memory_refs: memory_refs,
         risk_level: risk_level,
         source: :llm
       }}
    end
  end

  defp validate_decision(_), do: {:error, "parsed output is not a map"}

  defp validate_decision_field(%{"decision" => d}) when is_binary(d) do
    case Map.fetch(@decision_by_string, d) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, "invalid decision: #{d}"}
    end
  end

  defp validate_decision_field(%{"decision" => d}) when is_atom(d) do
    if d in @valid_decisions do
      {:ok, d}
    else
      {:error, "invalid decision: #{d}"}
    end
  end

  defp validate_decision_field(_), do: {:error, "missing or invalid 'decision' field"}

  defp validate_reason(%{"reason" => r}) when is_binary(r) do
    trimmed = String.trim(r)

    if trimmed == "" do
      {:error, "reason must be non-empty"}
    else
      {:ok, trimmed}
    end
  end

  defp validate_reason(_), do: {:error, "missing or invalid 'reason' field"}

  defp validate_risk_level(%{"risk_level" => r}) when is_binary(r) do
    case Map.fetch(@risk_level_by_string, r) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, "invalid risk_level: #{r}"}
    end
  end

  defp validate_risk_level(%{"risk_level" => r}) when is_atom(r) do
    if r in @valid_risk_levels do
      {:ok, r}
    else
      {:error, "invalid risk_level: #{r}"}
    end
  end

  defp validate_risk_level(_), do: {:error, "missing or invalid 'risk_level' field"}

  defp validate_suggested_next_action(%{"suggested_next_action" => s}) when is_binary(s) do
    trimmed = String.trim(s)
    if trimmed == "", do: nil, else: trimmed
  end

  defp validate_suggested_next_action(_), do: nil

  defp validate_memory_refs(%{"memory_refs" => refs}) when is_list(refs) do
    refs
    |> Enum.filter(&is_binary/1)
    |> Enum.take(3)
  end

  defp validate_memory_refs(_), do: []

  # Invoke a model — supports module atoms or anonymous functions. Model
  # exceptions are treated the same as unavailable/invalid models: fallback,
  # never block solely because steering infrastructure failed.
  defp invoke_model(model, prompt, opts) do
    cond do
      is_atom(model) -> model.generate(prompt, opts)
      is_function(model, 2) -> model.(prompt, opts)
      true -> {:error, "invalid steering model"}
    end
  rescue
    exception -> {:error, Exception.message(exception)}
  catch
    kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
  end

  # Extract the first complete JSON object from a string that may have
  # trailing text (e.g., model adds explanation after the JSON).
  defp extract_first_json_object(str) do
    case find_balanced_braces(str) do
      {:ok, json} -> {:ok, json}
      :error -> {:ok, str}
    end
  end

  # Simple brace-matching: find the first { then match it to its closing }
  defp find_balanced_braces(str) do
    case :binary.match(str, "{") do
      {start, _} ->
        case match_braces(str, start + 1, 1) do
          {:ok, end_pos} -> {:ok, binary_part(str, start, end_pos - start + 1)}
          :error -> :error
        end

      :nomatch ->
        :error
    end
  end

  defp match_braces(_str, pos, 0), do: {:ok, pos - 1}

  defp match_braces(str, pos, depth) when byte_size(str) > pos do
    case :binary.at(str, pos) do
      ?{ -> match_braces(str, pos + 1, depth + 1)
      ?} -> match_braces(str, pos + 1, depth - 1)
      ?" -> skip_string(str, pos + 1, depth)
      _ -> match_braces(str, pos + 1, depth)
    end
  end

  defp match_braces(_str, _pos, _depth), do: :error

  # Skip a JSON string literal (handle escaped quotes)
  defp skip_string(str, pos, depth) when byte_size(str) > pos do
    case :binary.at(str, pos) do
      ?\" -> match_braces(str, pos + 1, depth)
      ?\\ -> skip_string(str, pos + 2, depth)
      _ -> skip_string(str, pos + 1, depth)
    end
  end

  defp skip_string(_str, _pos, _depth), do: :error

  defp find_index(str, pattern) do
    case :binary.match(str, pattern) do
      {pos, _len} -> pos
      :nomatch -> nil
    end
  end

  defp find_last_index(str, pattern) do
    case :binary.matches(str, pattern) do
      [] -> nil
      matches -> elem(List.last(matches), 0)
    end
  end
end
