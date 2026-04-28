defmodule KiroCockpit.NanoPlanner.SubagentCoordinator do
  @moduledoc """
  Coordinates read-only specialist reviewer subagents (§26.9, Phase 18).

  NanoPlanner may invoke read-only reviewers before approval if they cannot
  mutate state. Implementation subagents are blocked before approval
  (§25.3 R3). Reviewer outputs become plan evidence and are persisted as
  plan events.

  ## Invariants

    * Only read-only reviewers (no write/shell/terminal tools) may be
      invoked when the plan is not yet approved (§32.2: planning →
      subagent: "read-only reviewers only").
    * Every subagent session receives `parent_session_id`, `plan_id`,
      `task_id`, and `agent_id` (§26.9).
    * Reviewer outputs are persisted atomically with plan evidence via
      `Ecto.Multi` (dual-write discipline §6.3).
    * Permissions narrow, never widen (§4.5): composing a reviewer's
      effective permissions with the planning category always intersects.

  ## Agent definitions

  Agent metadata lives in `.kiro/agents/*.json` files. This module loads
  them at startup and on demand, classifying each as read-only or
  write-capable based on its `tools` list.

  ## Injectable modules

  * `:kiro_session_module` — module implementing `prompt/3` for
    reviewer invocation (default: `KiroCockpit.KiroSession`).
  """

  alias Ecto.Multi
  alias KiroCockpit.Plans.PlanEvent
  alias KiroCockpit.Repo

  require Logger

  # ── Types ──────────────────────────────────────────────────────────

  @type agent_id :: String.t()

  @typedoc """
  A parsed agent definition loaded from `.kiro/agents/*.json`.

  * `:name`          — agent identifier (e.g. "kiro-cockpit-qa-reviewer")
  * `:description`   — human-readable description
  * `:tools`          — full tool set the agent *could* use
  * `:allowed_tools`  — default allowed tools (subset of `:tools`)
  * `:write_capable?` — true if any tool implies mutation
  * `:read_only?`     — true if no mutation-capable tools present
  * `:source_path`    — the JSON file this definition was loaded from
  """
  @type agent_definition :: %{
          name: String.t(),
          description: String.t(),
          tools: [String.t()],
          allowed_tools: [String.t()],
          write_capable?: boolean(),
          read_only?: boolean(),
          source_path: String.t()
        }

  @typedoc """
  Correlation context required for every subagent invocation (§26.9).
  """
  @type correlation :: %{
          parent_session_id: String.t(),
          plan_id: String.t(),
          task_id: String.t() | nil,
          agent_id: String.t()
        }

  @typedoc """
  Result of a reviewer invocation.
  """
  @type reviewer_result :: %{
          agent: agent_definition(),
          output: term(),
          correlation: correlation(),
          persisted_event: PlanEvent.t() | nil
        }

  # Tools that imply mutation — possessing any makes an agent write-capable.
  @write_tools ~w(write shell shell_write terminal destructive)

  @default_kiro_session_module KiroCockpit.KiroSession
  @default_agents_dir ".kiro/agents"
  @reviewer_event_type "reviewer_output"

  # ── Public API: Agent registry ──────────────────────────────────────

  @doc """
  Lists all agent definitions found in `.kiro/agents/*.json`.

  Returns `{:ok, [agent_definition]}` or `{:error, reason}`.
  Agent files with invalid JSON or missing required keys are skipped
  with a warning rather than failing the entire listing.
  """
  @spec list_agents(keyword()) :: {:ok, [agent_definition()]} | {:error, term()}
  def list_agents(opts \\ []) do
    agents_dir = Keyword.get(opts, :agents_dir, @default_agents_dir)

    with {:ok, files} <- list_agent_files(agents_dir) do
      agents =
        files
        |> Enum.map(&load_agent_definition/1)
        |> Enum.reject(fn
          {:ok, _} -> false
          {:error, _} -> true
        end)
        |> Enum.map(fn {:ok, agent} -> agent end)

      {:ok, agents}
    end
  end

  @doc """
  Lists only read-only reviewer agents.

  A read-only reviewer has no mutation-capable tools (`write`, `shell`,
  `shell_write`, `terminal`, `destructive`) in its `tools` list.
  """
  @spec list_read_only_reviewers(keyword()) :: {:ok, [agent_definition()]} | {:error, term()}
  def list_read_only_reviewers(opts \\ []) do
    with {:ok, agents} <- list_agents(opts) do
      {:ok, Enum.filter(agents, & &1.read_only?)}
    end
  end

  @doc """
  Finds a single agent definition by name.

  Returns `{:ok, agent_definition}` or `{:error, :not_found}`.
  """
  @spec find_agent(String.t(), keyword()) ::
          {:ok, agent_definition()} | {:error, :not_found}
  def find_agent(name, opts \\ []) do
    with {:ok, agents} <- list_agents(opts) do
      case Enum.find(agents, &(&1.name == name)) do
        nil -> {:error, :not_found}
        agent -> {:ok, agent}
      end
    end
  end

  @doc """
  Classifies an agent definition as read-only or write-capable.

  Returns `:read_only` if the agent has no mutation-capable tools,
  `:write_capable` otherwise.
  """
  @spec classify_agent(agent_definition()) :: :read_only | :write_capable
  def classify_agent(agent) do
    if agent.read_only?, do: :read_only, else: :write_capable
  end

  # ── Public API: Invocation gating ──────────────────────────────────

  @doc """
  Checks whether a subagent invocation is allowed given the plan's
  approval status.

  ## Rules (§26.9, §25.3 R3, §32.2)

    * When `plan_approved?` is `false`, only read-only reviewers are
      allowed. Implementation subagents (write-capable) are blocked.
    * When `plan_approved?` is `true`, any registered agent is allowed.

  Returns `:ok` if the invocation may proceed, or
  `{:error, {:subagent_blocked, reason, guidance}}` if blocked.
  """
  @spec check_invocation_allowed(agent_definition(), boolean()) ::
          :ok | {:error, {:subagent_blocked, String.t(), String.t()}}
  def check_invocation_allowed(agent, plan_approved?) do
    case {agent.read_only?, plan_approved?} do
      {true, _} ->
        :ok

      {false, true} ->
        :ok

      {false, false} ->
        {:error,
         {:subagent_blocked, "implementation subagent blocked before approval",
          "Approve the plan before invoking write-capable subagents (§25.3 R3). " <>
            "Read-only reviewers are available for pre-approval analysis."}}
    end
  end

  @doc """
  Invokes a read-only reviewer and persists its output as plan evidence.

  Performs three steps atomically (dual-write §6.3):

    1. Validate the agent is read-only and invocation is allowed.
    2. Build a reviewer prompt with correlation context.
    3. Send the prompt via the injectable session module.
    4. Persist the reviewer output as a plan event.

  ## Options

    * `:kiro_session_module` — module implementing `prompt/3`
    * `:agents_dir` — override `.kiro/agents/` directory
    * `:plan_approved?` — whether the plan is approved (default: `false`)

  Returns `{:ok, reviewer_result}` or `{:error, reason}`.
  """
  @spec invoke_reviewer(
          GenServer.server(),
          String.t(),
          String.t(),
          correlation(),
          keyword()
        ) :: {:ok, reviewer_result()} | {:error, term()}
  def invoke_reviewer(session, agent_name, review_prompt, correlation, opts \\ []) do
    with {:ok, agent} <- find_agent(agent_name, opts),
         :ok <- require_read_only(agent),
         :ok <- check_invocation_allowed(agent, Keyword.get(opts, :plan_approved?, false)),
         {:ok, output} <- run_reviewer(session, agent, review_prompt, correlation, opts),
         {:ok, event} <- persist_reviewer_output(correlation, agent, output, opts) do
      {:ok,
       %{
         agent: agent,
         output: output,
         correlation: correlation,
         persisted_event: event
       }}
    end
  end

  @doc """
  Invokes any subagent, respecting pre-approval gating.

  Unlike `invoke_reviewer/5`, this allows write-capable agents when the
  plan is approved. Otherwise the same flow: gate → prompt → persist.

  Returns `{:ok, reviewer_result}` or `{:error, reason}`.
  """
  @spec invoke_subagent(
          GenServer.server(),
          String.t(),
          String.t(),
          correlation(),
          keyword()
        ) :: {:ok, reviewer_result()} | {:error, term()}
  def invoke_subagent(session, agent_name, prompt, correlation, opts \\ []) do
    with {:ok, agent} <- find_agent(agent_name, opts),
         :ok <- check_invocation_allowed(agent, Keyword.get(opts, :plan_approved?, false)),
         {:ok, output} <- run_reviewer(session, agent, prompt, correlation, opts),
         {:ok, event} <- persist_reviewer_output(correlation, agent, output, opts) do
      {:ok,
       %{
         agent: agent,
         output: output,
         correlation: correlation,
         persisted_event: event
       }}
    end
  end

  # ── Public API: Persistence ─────────────────────────────────────────

  @multi_new &Multi.new/0
  defp new_multi, do: @multi_new.()

  @doc """
  Persists a reviewer output as a plan event with correlation metadata.

  Uses `Ecto.Multi` for dual-write compliance (§6.3): the event row and
  its metadata are written atomically. The event type is
  `"reviewer_output"` and the payload includes the agent name, output,
  and full correlation context.
  """
  @spec persist_reviewer_output(correlation(), agent_definition(), term(), keyword()) ::
          {:ok, PlanEvent.t()} | {:error, term()}

  def persist_reviewer_output(correlation, agent, output, _opts) do
    event_attrs = %{
      plan_id: correlation.plan_id,
      event_type: @reviewer_event_type,
      payload: %{
        "agent_name" => agent.name,
        "agent_read_only" => agent.read_only?,
        "output" => sanitize_output(output),
        "parent_session_id" => correlation.parent_session_id,
        "task_id" => correlation.task_id,
        "agent_id" => correlation.agent_id,
        "invoked_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      },
      created_at: DateTime.utc_now()
    }

    new_multi()
    |> Multi.insert(:event, PlanEvent.changeset(%PlanEvent{}, event_attrs))
    |> Repo.transaction()
    |> case do
      {:ok, %{event: event}} -> {:ok, event}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  @doc """
  Lists reviewer output events for a given plan.

  Returns plan events of type `"reviewer_output"` ordered by creation time.
  """
  @spec list_reviewer_outputs(String.t()) :: [PlanEvent.t()]
  def list_reviewer_outputs(plan_id) do
    import Ecto.Query

    PlanEvent
    |> where([e], e.plan_id == ^plan_id and e.event_type == ^@reviewer_event_type)
    |> order_by([e], e.created_at)
    |> Repo.all()
  end

  # ── Agent loading ──────────────────────────────────────────────────

  defp list_agent_files(agents_dir) do
    path = Path.expand(agents_dir)

    if File.dir?(path) do
      files =
        path
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.map(&Path.join(path, &1))

      {:ok, files}
    else
      {:error, {:agents_dir_not_found, agents_dir}}
    end
  end

  @doc false
  @spec load_agent_definition(String.t()) ::
          {:ok, agent_definition()} | {:error, term()}
  def load_agent_definition(path) do
    with {:ok, raw} <- File.read(path),
         {:ok, json} <- Jason.decode(raw) do
      parse_agent_json(json, path)
    else
      {:error, %Jason.DecodeError{} = reason} ->
        Logger.warning("Skipping agent file #{path}: invalid JSON (#{Exception.message(reason)})")
        {:error, {:invalid_json, path}}

      {:error, reason} ->
        Logger.warning("Skipping agent file #{path}: #{inspect(reason)}")
        {:error, {:read_error, path, reason}}
    end
  end

  defp parse_agent_json(json, path) do
    required_keys = ["name", "description", "tools", "allowedTools"]

    missing = Enum.reject(required_keys, &Map.has_key?(json, &1))

    if missing != [] do
      Logger.warning("Skipping agent file #{path}: missing keys #{inspect(missing)}")
      {:error, {:missing_keys, path, missing}}
    else
      tools = json["tools"] || []
      allowed_tools = json["allowedTools"] || []

      write_capable? = has_write_tools?(tools)
      read_only? = not write_capable?

      {:ok,
       %{
         name: json["name"],
         description: json["description"],
         tools: tools,
         allowed_tools: allowed_tools,
         write_capable?: write_capable?,
         read_only?: read_only?,
         source_path: path
       }}
    end
  end

  defp has_write_tools?(tools) when is_list(tools) do
    Enum.any?(tools, fn tool ->
      String.downcase(tool) in @write_tools
    end)
  end

  defp has_write_tools?(_), do: true

  # ── Invocation helpers ──────────────────────────────────────────────

  defp require_read_only(agent) do
    if agent.read_only? do
      :ok
    else
      {:error,
       {:reviewer_not_read_only,
        "Agent #{agent.name} has write-capable tools: " <>
          "#{inspect(write_tools_for(agent))}. " <>
          "Only read-only reviewers may be invoked via invoke_reviewer/5."}}
    end
  end

  defp write_tools_for(agent) do
    Enum.filter(agent.tools, fn tool ->
      String.downcase(tool) in @write_tools
    end)
  end

  defp run_reviewer(session, agent, prompt_text, correlation, opts) do
    session_mod = Keyword.get(opts, :kiro_session_module, @default_kiro_session_module)
    timeout = Keyword.get(opts, :timeout, 120_000)

    # Bind correlation context into prompt opts (§26.9)
    prompt_opts =
      [
        timeout: timeout,
        agent_id: correlation.agent_id,
        parent_session_id: correlation.parent_session_id,
        plan_id: correlation.plan_id,
        task_id: correlation.task_id,
        subagent_name: agent.name
      ]
      |> maybe_add_swarm_ctx(opts)

    session_mod.prompt(session, prompt_text, prompt_opts)
  end

  defp maybe_add_swarm_ctx(kw, opts) do
    case Keyword.get(opts, :swarm_ctx) do
      nil -> kw
      ctx -> Keyword.put(kw, :swarm_ctx, ctx)
    end
  end

  # Sanitize reviewer output for safe persistence.
  # Redacts PII/secrets per §22.6 before storage.
  # All output maps use string keys for consistent DB round-trip behavior.
  defp sanitize_output(output) when is_map(output) do
    output
    |> stringify_keys()
    |> redact_sensitive_fields()
  end

  defp sanitize_output(output) when is_binary(output) do
    %{"raw_text" => truncate_string(output, 10_000)}
  end

  defp sanitize_output(output) do
    %{"inspected" => truncate_string(inspect(output), 5_000)}
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {to_string(k), v}
    end)
  end

  defp redact_sensitive_fields(map) do
    sensitive_keys = ~w(password secret token api_key api_secret credential key private_key)

    Map.new(map, fn {k, v} ->
      key_str = to_string(k)

      if Enum.any?(sensitive_keys, &String.contains?(String.downcase(key_str), &1)) do
        {k, "[REDACTED]"}
      else
        {k, v}
      end
    end)
  end

  defp truncate_string(str, max_len) when byte_size(str) > max_len do
    String.slice(str, 0, max_len) <> "…[truncated]"
  end

  defp truncate_string(str, _max_len), do: str
end
