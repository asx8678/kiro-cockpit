defmodule KiroCockpit.NanoPlanner do
  @moduledoc """
  NanoPlanner service module (plan2.md §9).

  Coordinates read-only project discovery, prompt construction, model
  invocation, plan validation, and persistence. Public API:

    * `plan/3`   — generate and persist a draft plan
    * `approve/3` — approve a plan and send execution prompt to Kiro
    * `revise/4` — supersede a plan with a revised version

  ## Injectable modules

  The `:kiro_session_module` opt (default `KiroCockpit.KiroSession`) allows
  swapping the Kiro session implementation for testing. The module must
  implement `state/1` and `prompt/3` with the same signatures as
  `KiroCockpit.KiroSession`.

  ## Supported modes

  Only `:nano`, `:nano_deep`, and `:nano_fix` (atom or string) are accepted.
  Any other mode returns `{:error, {:invalid_mode, mode}}`.
  """

  alias KiroCockpit.NanoPlanner.{ContextBuilder, PlanSchema, PromptBuilder, Staleness}
  alias KiroCockpit.Plans
  alias KiroCockpit.Swarm.ActionBoundary
  alias KiroCockpit.Swarm.Tasks.TaskManager

  @supported_modes [:nano, :nano_deep, :nano_fix]
  @mode_by_string Map.new(@supported_modes, fn mode -> {to_string(mode), mode} end)

  @default_kiro_session_module KiroCockpit.KiroSession
  @default_planner_timeout 300_000
  @default_execution_agent_id "kiro-executor"

  # ACP envelope keys to check for nested plan JSON (in priority order)
  @acp_content_keys ~w(content text message output plan raw_plan)a
  @acp_container_keys ~w(raw update stream_events events)a

  @fenced_json_regex ~r/```json\s*\n?/i

  # ── Public API ──────────────────────────────────────────────────────

  @doc """
  Generates and persists a draft plan for the given user request.

  ## Steps

  1. Resolve mode, session id, and project dir from opts or session state.
  2. Build a read-only project snapshot via `ContextBuilder`.
  3. Build the runtime planner prompt via `PromptBuilder`.
  4. Run the planner model via the injectable session module.
  5. Parse the model response into a raw plan map.
  6. Validate and normalize via `PlanSchema`.
  7. Persist via `Plans.create_plan/5` with flattened steps.

  ## Options

    * `:mode` — planning mode (default `:nano`). Must be one of
      `:nano`, `:nano_deep`, `:nano_fix` (atom or string).
    * `:session_id` — override session id (defaults to session state).
    * `:project_dir` — override project directory (defaults to session cwd).
    * `:kiro_session_module` — module for `state/1` and `prompt/3`
      (default `KiroCockpit.KiroSession`).
    * `:planner_timeout` / `:timeout` — timeout for the planner prompt
      call in ms (default 300 000).
    * `:session_summary` — optional session history summary for context.
    * `:max_tree_lines` — context builder tree cap.
    * `:max_file_chars_per_file` — context builder per-file cap.
    * `:max_total_context_chars` — context builder total budget cap.

  Returns `{:ok, saved_plan}` or `{:error, reason}`.
  """
  @spec plan(GenServer.server(), String.t(), keyword()) ::
          {:ok, Plans.Plan.t()} | {:error, term()}
  def plan(session, user_request, opts \\ []) do
    with {:ok, mode} <- resolve_mode(opts),
         session_mod = resolve_session_module(opts),
         {:ok, session_state} <- fetch_session_state(session_mod, session),
         {:ok, session_id} <- resolve_session_id(session_state, opts),
         {:ok, project_dir} <- resolve_project_dir(session_state, opts) do
      boundary_opts =
        plan_generate_boundary_opts(session_id, project_dir, mode, user_request, opts)

      if boundary_enabled?(opts) do
        case ActionBoundary.run(:nano_plan_generate, boundary_opts, fn ->
               do_plan(
                 session,
                 user_request,
                 mode,
                 session_mod,
                 session_state,
                 session_id,
                 project_dir,
                 opts
               )
             end) do
          {:ok, result} ->
            result

          {:error, {:swarm_blocked, reason, messages}} ->
            {:error, {:swarm_blocked, reason, messages}}
        end
      else
        do_plan(
          session,
          user_request,
          mode,
          session_mod,
          session_state,
          session_id,
          project_dir,
          opts
        )
      end
    end
  end

  # Actual plan generation/persistence — extracted for boundary wrapping.
  defp do_plan(
         session,
         user_request,
         mode,
         session_mod,
         _session_state,
         session_id,
         project_dir,
         opts
       ) do
    with {:ok, snapshot} <- build_snapshot(project_dir, opts),
         {:ok, prompt} <- build_prompt(user_request, snapshot, mode),
         {:ok, raw_result} <- run_planner(session_mod, session, prompt, opts),
         {:ok, raw_plan} <- parse_model_output(raw_result),
         {:ok, normalized} <- validate_plan(raw_plan) do
      persist_plan(session_id, user_request, mode, normalized, snapshot, raw_plan)
    end
  end

  defp boundary_enabled?(opts) do
    case Keyword.get(opts, :swarm_hooks) do
      nil -> Application.get_env(:kiro_cockpit, :swarm_action_hooks_enabled, true)
      explicit -> explicit
    end
  end

  defp plan_generate_boundary_opts(session_id, project_dir, mode, user_request, opts) do
    agent_id = Keyword.get(opts, :agent_id, "nano-planner")
    plan_mode = Keyword.get(opts, :plan_mode)
    swarm_ctx = Keyword.get(opts, :swarm_ctx, %{})

    [
      session_id: session_id,
      agent_id: agent_id,
      permission_level: :subagent,
      project_dir: project_dir,
      payload: %{mode: mode, request_summary: truncate_request(user_request)},
      plan_mode: plan_mode,
      swarm_ctx: swarm_ctx,
      enabled: boundary_enabled?(opts)
    ]
    |> maybe_put_opt(opts, :pre_hooks)
    |> maybe_put_opt(opts, :post_hooks)
    |> maybe_put_opt(opts, :hook_manager_module)
    |> maybe_put_opt(opts, :task_manager_module)
  end

  defp truncate_request(request) when is_binary(request) and byte_size(request) > 200 do
    String.slice(request, 0, 200) <> "…"
  end

  defp truncate_request(request), do: request

  defp maybe_put_opt(kw, opts, key) do
    case Keyword.get(opts, key) do
      nil -> kw
      value -> Keyword.put(kw, key, value)
    end
  end

  @doc """
  Approves a draft plan and sends its execution prompt to Kiro.

  Before approval, checks whether the project snapshot has changed since
  the plan was created. If the hash differs, returns `{:error, :stale_plan}`.
  If the current project dir is unavailable or the snapshot cannot be
  computed, returns `{:error, :stale_plan_unknown}` — the check **fails
  closed** rather than being skipped.

  After approval (`Plans.approve_plan/1`), swarm tasks are derived from
  `plan_steps` and created atomically. The first pending task is activated
  for the execution lane (session_id + execution_agent_id). Only then is
  the plan's `execution_prompt` sent to Kiro via `prompt/3` with
  plan/task/agent identifiers bound into prompt opts.

  ## Options

    * `:kiro_session_module` — module for `state/1` and `prompt/3`
      (default `KiroCockpit.KiroSession`).
    * `:planner_timeout` — timeout for the execution prompt call in ms.
    * `:project_dir` — trusted project directory override.
    * `:context_builder_module` — module implementing `build/1` for
      staleness checks (default `ContextBuilder`). Useful for testing
      snapshot-build failure scenarios.
    * `:execution_agent_id` — owner_id for derived swarm tasks and the
      execution lane; defaults to `"kiro-executor"`.
    * `:task_manager_module` — module implementing `create_all/1`,
      `activate/1`, `get_active/2`, `list/2` (default
      `KiroCockpit.Swarm.Tasks.TaskManager`). Useful for testing.

  Returns `{:ok, %{plan: approved_plan, prompt_result: result, tasks: tasks, active_task: task}}`
  on success. Existing code pattern-matching on `%{plan: _, prompt_result: _}`
  continues to work. If the prompt send fails after approval, returns
  `{:error, {:prompt_failed, approved_plan, prompt_error}}`.
  If task creation or activation fails, returns `{:error, reason}`
  without sending the execution prompt.
  """
  @spec approve(GenServer.server(), Plans.plan_id(), keyword()) ::
          {:ok,
           %{
             plan: Plans.Plan.t(),
             prompt_result: map(),
             tasks: list(),
             active_task: KiroCockpit.Swarm.Tasks.Task.t() | nil
           }}
          | {:error, term()}
  def approve(session, plan_id, opts \\ []) do
    session_mod = resolve_session_module(opts)

    with {:ok, plan} <- fetch_plan(plan_id),
         {:ok, project_dir} <- resolve_project_dir_for_staleness(session_mod, session, opts) do
      boundary_opts = plan_approve_boundary_opts(plan, project_dir, opts)

      # Staleness check remains outside boundary for now (kiro-ux7 will move
      # it into the boundary executor). If stale, we skip the boundary
      # entirely — the action never reaches hooks.
      case Staleness.check(plan, project_dir, opts) do
        :ok ->
          if boundary_enabled?(opts) do
            case ActionBoundary.run(:nano_plan_approve, boundary_opts, fn ->
                   do_approve(session_mod, session, plan_id, opts)
                 end) do
              {:ok, result} ->
                result

              {:error, {:swarm_blocked, reason, messages}} ->
                {:error, {:swarm_blocked, reason, messages}}
            end
          else
            do_approve(session_mod, session, plan_id, opts)
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Actual approve + prompt send — extracted for boundary wrapping.
  # Per §36.8 (kiro-56f): on approval, derive swarm tasks from plan_steps,
  # activate the first task for the execution lane, then send the
  # execution prompt with plan/task/agent identifiers bound into opts.
  defp do_approve(session_mod, session, plan_id, opts) do
    case Plans.approve_plan(plan_id) do
      {:ok, approved_plan} ->
        task_manager_mod = Keyword.get(opts, :task_manager_module, TaskManager)
        agent_id = Keyword.get(opts, :execution_agent_id, @default_execution_agent_id)

        with {:ok, tasks} <- ensure_plan_tasks(approved_plan, agent_id, task_manager_mod),
             {:ok, active_task} <-
               activate_first_task(tasks, approved_plan, agent_id, task_manager_mod) do
          # Re-fetch tasks from DB so the returned list reflects post-activation status
          refreshed_tasks =
            task_manager_mod.list(approved_plan.session_id, plan_id: approved_plan.id)

          case send_execution_prompt(session_mod, session, approved_plan, opts,
                 plan_id: approved_plan.id,
                 task_id: active_task.id,
                 agent_id: agent_id,
                 swarm_plan_id: approved_plan.id
               ) do
            {:ok, %{plan: approved_plan, prompt_result: result}} ->
              {:ok,
               %{
                 plan: approved_plan,
                 prompt_result: result,
                 tasks: refreshed_tasks,
                 active_task: active_task
               }}

            {:error, {:prompt_failed, plan, reason}} ->
              {:error, {:prompt_failed, plan, reason}}
          end
        else
          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp plan_approve_boundary_opts(plan, project_dir, opts) do
    session_id = Keyword.get(opts, :session_id, plan.session_id)
    agent_id = Keyword.get(opts, :agent_id, "nano-planner")
    plan_mode = Keyword.get(opts, :plan_mode)
    swarm_ctx = Keyword.get(opts, :swarm_ctx, %{})

    [
      session_id: session_id,
      agent_id: agent_id,
      plan_id: plan.id,
      permission_level: :write,
      project_dir: project_dir,
      payload: %{plan_id: plan.id, mode: plan.mode},
      plan_mode: plan_mode,
      swarm_ctx: swarm_ctx,
      enabled: boundary_enabled?(opts)
    ]
    |> maybe_put_opt(opts, :pre_hooks)
    |> maybe_put_opt(opts, :post_hooks)
    |> maybe_put_opt(opts, :hook_manager_module)
    |> maybe_put_opt(opts, :task_manager_module)
    |> maybe_put_opt(opts, :stale_plan_override?)
    |> maybe_put_opt(opts, :stale_plan_confirmed?)
  end

  @doc """
  Supersedes an existing plan with a revised version.

  Fetches the old plan, builds a revision request that includes the user's
  revision instructions plus context from the old plan (plan_markdown,
  execution_prompt, steps summary), then calls `plan/3` to generate and
  persist a new draft. The old plan is superseded **only after** the new
  plan is successfully created.

  ## Options

  Passed through to `plan/3`. The `:kiro_session_module` and `:mode` opts
  are supported. Mode defaults to the old plan's mode.

  Returns `{:ok, new_plan}` or `{:error, reason}`.
  """
  @spec revise(GenServer.server(), Plans.plan_id(), String.t(), keyword()) ::
          {:ok, Plans.Plan.t()} | {:error, term()}
  def revise(session, plan_id, revision_request, opts \\ []) do
    with {:ok, old_plan} <- fetch_plan(plan_id) do
      combined_request = build_revision_request(revision_request, old_plan)

      # Preserve the old plan's session and mode context
      plan_opts =
        opts
        |> Keyword.put_new(:session_id, old_plan.session_id)
        |> Keyword.put_new(:mode, normalize_mode(old_plan.mode))

      case plan(session, combined_request, plan_opts) do
        {:ok, new_plan} ->
          supersede_old_plan(plan_id, new_plan)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # ── Mode resolution ─────────────────────────────────────────────────

  defp resolve_mode(opts) do
    raw = Keyword.get(opts, :mode, :nano)
    mode = normalize_mode(raw)

    if mode in @supported_modes do
      {:ok, mode}
    else
      {:error, {:invalid_mode, raw}}
    end
  end

  defp normalize_mode(mode) when mode in @supported_modes, do: mode

  defp normalize_mode(mode) when is_binary(mode) do
    Map.get(@mode_by_string, String.downcase(mode))
  end

  defp normalize_mode(_), do: nil

  # ── Session resolution ──────────────────────────────────────────────

  defp resolve_session_module(opts) do
    Keyword.get(opts, :kiro_session_module, @default_kiro_session_module)
  end

  defp fetch_session_state(session_mod, session) do
    safe_session_call(fn -> session_mod.state(session) end)
  end

  defp safe_session_call(fun) do
    {:ok, fun.()}
  rescue
    _ -> {:error, :session_unavailable}
  catch
    :exit, _ -> {:error, :session_unavailable}
  end

  defp resolve_session_id(session_state, opts) do
    case Keyword.get(opts, :session_id) do
      nil ->
        case Map.get(session_state, :session_id) do
          nil -> {:error, :session_id_required}
          id -> {:ok, id}
        end

      id ->
        {:ok, id}
    end
  end

  defp resolve_project_dir(session_state, opts) do
    case Keyword.get(opts, :project_dir) do
      nil ->
        case Map.get(session_state, :cwd) do
          nil -> {:error, :project_dir_required}
          dir -> {:ok, dir}
        end

      dir ->
        {:ok, dir}
    end
  end

  # ── Snapshot ────────────────────────────────────────────────────────

  defp build_snapshot(project_dir, opts) do
    cb_opts =
      [
        project_dir: project_dir,
        session_summary: Keyword.get(opts, :session_summary),
        max_tree_lines: Keyword.get(opts, :max_tree_lines),
        max_file_chars_per_file: Keyword.get(opts, :max_file_chars_per_file),
        max_total_context_chars: Keyword.get(opts, :max_total_context_chars)
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    ContextBuilder.build(cb_opts)
  end

  # ── Prompt ──────────────────────────────────────────────────────────

  defp build_prompt(user_request, snapshot, mode) do
    PromptBuilder.build_runtime_prompt(
      user_request: user_request,
      project_snapshot: snapshot,
      mode: mode,
      session_summary: snapshot.session_summary || "",
      kiro_plan_summary: snapshot.existing_plans || ""
    )
  end

  # ── Planner invocation ──────────────────────────────────────────────

  defp run_planner(session_mod, session, prompt, opts) do
    timeout =
      Keyword.get(opts, :planner_timeout) ||
        Keyword.get(opts, :timeout, @default_planner_timeout)

    case session_mod.prompt(session, prompt, timeout: timeout) do
      {:ok, result} -> {:ok, enrich_with_stream_events(session_mod, session, result, opts)}
      {:error, _} = error -> error
    end
  end

  defp enrich_with_stream_events(session_mod, session, result, opts) do
    case recent_stream_events(session_mod, session, opts) do
      [] ->
        result

      events when is_map(result) ->
        Map.put_new(result, "stream_events", events)

      events ->
        %{"prompt_result" => inspect(result), "stream_events" => events}
    end
  end

  defp recent_stream_events(session_mod, session, opts) do
    if function_exported?(session_mod, :recent_stream_events, 2),
      do: fetch_recent_stream_events(session_mod, session, opts),
      else: []
  end

  defp fetch_recent_stream_events(session_mod, session, opts) do
    limit = Keyword.get(opts, :stream_event_limit, 32)

    case safe_session_call(fn -> session_mod.recent_stream_events(session, limit: limit) end) do
      {:ok, events} when is_list(events) -> events
      _ -> []
    end
  end

  # ── Model output parsing ────────────────────────────────────────────

  @doc false
  @spec parse_model_output(term()) :: {:ok, map()} | {:error, {:invalid_model_output, String.t()}}
  def parse_model_output(result) when is_map(result) do
    if has_plan_keys?(result) do
      {:ok, result}
    else
      extract_from_acp_envelope(result)
    end
  end

  def parse_model_output(result) when is_binary(result) do
    decode_json_string(result)
  end

  def parse_model_output(result) do
    {:error, {:invalid_model_output, "expected map or string, got: #{inspect(result)}"}}
  end

  defp has_plan_keys?(map) do
    required = PlanSchema.required_keys()
    Enum.any?(required, fn key -> Map.has_key?(map, key) or Map.has_key?(map, to_string(key)) end)
  end

  defp extract_from_acp_envelope(map) do
    map
    |> collect_candidate_values()
    |> parse_candidate_values()
    |> case do
      :no_candidates ->
        {:error,
         {:invalid_model_output, "no plan found in ACP envelope: #{inspect(Map.keys(map))}"}}

      {:ok, _} = success ->
        success

      {:error, _} = error ->
        error
    end
  end

  defp collect_candidate_values(map) when is_map(map) do
    direct_values = values_for_keys(map, @acp_content_keys)

    nested_values =
      map
      |> values_for_keys(@acp_container_keys)
      |> Enum.flat_map(&collect_candidate_values/1)

    direct_values ++ nested_values
  end

  defp collect_candidate_values(list) when is_list(list) do
    Enum.flat_map(list, &collect_candidate_values/1)
  end

  defp collect_candidate_values(_), do: []

  defp values_for_keys(map, keys) when is_map(map) do
    Enum.flat_map(keys, fn key ->
      map
      |> get_key_variants(key)
      |> Enum.reject(&is_nil/1)
    end)
  end

  defp get_key_variants(map, key) when is_atom(key) do
    [Map.get(map, key), Map.get(map, to_string(key))]
  end

  defp get_key_variants(map, key) when is_binary(key) do
    [Map.get(map, key), Map.get(map, String.to_existing_atom(key))]
  rescue
    ArgumentError -> [Map.get(map, key)]
  end

  defp parse_candidate_values([]), do: :no_candidates

  defp parse_candidate_values(values) do
    values
    |> Enum.reduce_while(:no_candidates, fn value, last_error ->
      case try_parse_plan_value(value) do
        {:ok, _} = success -> {:halt, success}
        {:error, _} = error -> {:cont, error}
        :skip -> {:cont, last_error}
      end
    end)
  end

  defp try_parse_plan_value(value) when is_map(value) do
    cond do
      has_plan_keys?(value) ->
        {:ok, value}

      collect_candidate_values(value) == [] ->
        :skip

      true ->
        parse_candidate_values(collect_candidate_values(value))
    end
  end

  defp try_parse_plan_value(value) when is_list(value) do
    value
    |> Enum.flat_map(fn
      item when is_binary(item) -> [item]
      item -> collect_candidate_values(item)
    end)
    |> parse_candidate_values()
  end

  defp try_parse_plan_value(value) when is_binary(value) do
    case decode_json_string(value) do
      {:ok, _} = success -> success
      {:error, _} = error -> error
    end
  end

  defp try_parse_plan_value(_), do: :skip

  defp decode_json_string(str) do
    str
    |> strip_fenced_json()
    |> Jason.decode()
    |> case do
      {:ok, decoded} when is_map(decoded) ->
        {:ok, decoded}

      {:ok, other} ->
        {:error, {:invalid_model_output, "JSON decoded to non-map: #{inspect(other)}"}}

      {:error, %Jason.DecodeError{} = reason} ->
        {:error, {:invalid_model_output, "JSON parse error: #{Exception.message(reason)}"}}
    end
  end

  defp strip_fenced_json(str) do
    str
    |> String.replace(@fenced_json_regex, "")
    |> String.replace(~r/```\s*\n?/, "")
    |> String.trim()
  end

  # ── Validation ──────────────────────────────────────────────────────

  defp validate_plan(raw_plan) do
    case PlanSchema.validate(raw_plan) do
      {:ok, normalized} ->
        {:ok, normalized}

      {:error, reasons} ->
        {:error, {:invalid_plan, PlanSchema.format_validation_errors(reasons)}}
    end
  end

  # ── Persistence ─────────────────────────────────────────────────────

  defp persist_plan(session_id, user_request, mode, normalized, snapshot, raw_plan) do
    flat_steps = PlanSchema.flatten_steps(normalized)

    opts = [
      plan_markdown: Map.get(normalized, :plan_markdown, ""),
      execution_prompt: Map.get(normalized, :execution_prompt, ""),
      raw_model_output: raw_plan,
      project_snapshot_hash: snapshot.hash
    ]

    case Plans.create_plan(session_id, user_request, mode, flat_steps, opts) do
      {:ok, plan} -> {:ok, plan}
      {:error, reason} -> {:error, {:persist_failed, reason}}
    end
  end

  # ── Approval helpers ────────────────────────────────────────────────

  defp fetch_plan(plan_id) do
    case Plans.get_plan(plan_id) do
      nil -> {:error, :not_found}
      plan -> {:ok, plan}
    end
  end

  # Resolves a trusted project directory for staleness checks.
  # Fails closed: returns `{:error, :stale_plan_unknown}` when no
  # project dir can be determined.
  defp resolve_project_dir_for_staleness(session_mod, session, opts) do
    case Keyword.get(opts, :project_dir) do
      dir when is_binary(dir) and dir != "" ->
        {:ok, dir}

      _ ->
        case safe_session_call(fn -> session_mod.state(session) end) do
          {:ok, %{cwd: cwd}} when is_binary(cwd) and cwd != "" -> {:ok, cwd}
          _ -> {:error, :stale_plan_unknown}
        end
    end
  end

  # ── Task derivation helpers (§36.8 kiro-56f) ───────────────────────

  # Idempotent: if tasks already exist for this plan, return them.
  # Otherwise, derive from plan_steps and create atomically.
  @spec ensure_plan_tasks(Plans.Plan.t(), String.t(), module()) ::
          {:ok, [KiroCockpit.Swarm.Tasks.Task.t()]} | {:error, term()}
  defp ensure_plan_tasks(approved_plan, agent_id, task_manager_mod) do
    existing = task_manager_mod.list(approved_plan.session_id, plan_id: approved_plan.id)

    if existing != [] do
      {:ok, existing}
    else
      attrs_list = derive_tasks_from_plan(approved_plan, agent_id)

      if attrs_list == [] do
        {:ok, []}
      else
        task_manager_mod.create_all(attrs_list)
      end
    end
  end

  # Derives task attribute maps from an approved plan's plan_steps.
  #
  # Field mapping per §36.8:
  #   plan_id           → approved_plan.id
  #   session_id         → approved_plan.session_id
  #   owner_id           → execution agent id
  #   sequence           → phase_number * 100 + step_number (stable)
  #   content            → "Phase N, Step M: title" + details
  #   status             → "pending"
  #   category           → permission-based heuristic:
  #       write/shell_write/terminal/destructive/subagent/memory_write → "acting"
  #       read/shell_read                               → "researching"
  #       validation-only (no mutation permissions)      → "verifying"
  #   permission_scope   → [step.permission_level, "read"]
  #   files_scope        → Map.keys(step.files) if map
  #   acceptance_criteria → [step.validation] if present
  @spec derive_tasks_from_plan(Plans.Plan.t(), String.t()) :: [map()]
  defp derive_tasks_from_plan(approved_plan, agent_id) do
    steps = approved_plan.plan_steps || []

    steps
    |> Enum.sort_by(fn step -> {step.phase_number, step.step_number} end)
    |> Enum.map(fn step ->
      perm = step.permission_level || "read"
      category = category_for_permission(perm, step)
      files = extract_files_scope(step)
      validation = if step.validation && step.validation != "", do: [step.validation], else: []

      content =
        case step.details do
          nil ->
            "Phase #{step.phase_number}, Step #{step.step_number}: #{step.title}"

          "" ->
            "Phase #{step.phase_number}, Step #{step.step_number}: #{step.title}"

          details ->
            "Phase #{step.phase_number}, Step #{step.step_number}: #{step.title}\n#{details}"
        end

      # Include read as baseline permission alongside step's explicit level
      permission_scope =
        [perm, "read"]
        |> Enum.uniq()
        |> Enum.filter(&valid_permission?/1)

      %{
        plan_id: approved_plan.id,
        session_id: approved_plan.session_id,
        owner_id: agent_id,
        sequence: step.phase_number * 100 + step.step_number,
        content: content,
        status: "pending",
        category: category,
        priority: "medium",
        permission_scope: permission_scope,
        files_scope: files,
        acceptance_criteria: validation
      }
    end)
  end

  # Category heuristic: mutation permissions → "acting", read-only → "researching",
  # validation-focused → "verifying".
  @acting_permissions ~w(write shell_write terminal destructive subagent memory_write)
  @researching_permissions ~w(read shell_read)

  defp category_for_permission(perm, step) do
    cond do
      perm in @acting_permissions ->
        "acting"

      perm in @researching_permissions and has_validation?(step) ->
        "verifying"

      perm in @researching_permissions ->
        "researching"

      true ->
        # Unknown permission: default to acting (safest for enforcement)
        "acting"
    end
  end

  defp has_validation?(step), do: step.validation != nil and step.validation != ""

  defp extract_files_scope(%{files: files}) when is_map(files) and map_size(files) > 0 do
    Map.keys(files)
  end

  defp extract_files_scope(%{files: files}) when is_list(files) and length(files) > 0 do
    Enum.map(files, &to_string/1)
  end

  defp extract_files_scope(_), do: []

  defp valid_permission?(perm) when is_binary(perm) do
    case KiroCockpit.Permissions.parse_permission(perm) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  defp valid_permission?(_), do: false

  # Activate the first pending task for the execution lane.
  # Idempotent: if the task is already active, return it.
  @spec activate_first_task(
          [KiroCockpit.Swarm.Tasks.Task.t()],
          Plans.Plan.t(),
          String.t(),
          module()
        ) ::
          {:ok, KiroCockpit.Swarm.Tasks.Task.t()} | {:error, term()}
  defp activate_first_task([], _approved_plan, _agent_id, _task_manager_mod) do
    {:error, :no_tasks_to_activate}
  end

  defp activate_first_task(tasks, approved_plan, agent_id, task_manager_mod) do
    # Check if an active task already exists for this lane
    case task_manager_mod.get_active(approved_plan.session_id, agent_id) do
      nil ->
        # Sort by sequence, activate the first pending task
        first_task =
          tasks
          |> Enum.sort_by(& &1.sequence)
          |> Enum.find(&(&1.status == "pending"))

        case first_task do
          nil ->
            # All tasks already completed/blocked — find any existing
            # active task for the lane and return it
            case task_manager_mod.get_active(approved_plan.session_id, agent_id) do
              nil -> {:error, :no_pending_tasks}
              active -> {:ok, active}
            end

          task ->
            task_manager_mod.activate(task.id)
        end

      active ->
        {:ok, active}
    end
  end

  # ── Execution prompt ──────────────────────────────────────────────────

  defp send_execution_prompt(session_mod, session, approved_plan, opts, correlation) do
    execution_prompt = approved_plan.execution_prompt
    timeout = Keyword.get(opts, :planner_timeout, @default_planner_timeout)

    # Merge correlation identifiers (plan_id, task_id, agent_id, swarm_plan_id)
    # into prompt opts so downstream boundary can trace execution context.
    prompt_opts =
      [timeout: timeout] ++
        Enum.reject(correlation, fn {_k, v} -> is_nil(v) end)

    case session_mod.prompt(session, execution_prompt, prompt_opts) do
      {:ok, result} ->
        {:ok, %{plan: approved_plan, prompt_result: result}}

      {:error, reason} ->
        {:error, {:prompt_failed, approved_plan, reason}}
    end
  end

  # ── Revision helpers ────────────────────────────────────────────────

  defp build_revision_request(revision_request, old_plan) do
    steps_summary = format_steps_summary(old_plan)

    """
    Revise this plan according to the user request.

    User revision:
    #{revision_request}

    Previous plan_markdown:
    #{old_plan.plan_markdown}

    Previous execution_prompt:
    #{old_plan.execution_prompt}

    Previous steps:
    #{steps_summary}
    """
  end

  defp format_steps_summary(plan) do
    steps = plan.plan_steps || []

    if steps == [] do
      "(none)"
    else
      steps
      |> Enum.sort_by(fn step -> {step.phase_number, step.step_number} end)
      |> Enum.map_join("\n", fn step ->
        "Phase #{step.phase_number}, Step #{step.step_number}: #{step.title}"
      end)
    end
  end

  defp supersede_old_plan(old_plan_id, new_plan) do
    case Plans.update_status(old_plan_id, "superseded", %{"replaced_by" => new_plan.id}) do
      {:ok, _} -> {:ok, new_plan}
      {:error, reason} -> {:error, {:supersede_failed, reason}}
    end
  end
end
