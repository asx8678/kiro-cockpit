defmodule KiroCockpit.Swarm.Events do
  @moduledoc """
  Context for Bronze swarm events (plan2.md §27.10, §34.2).

  Bronze events are the raw capture layer of the Plan 3 data pipeline:
  every runtime event lands here, including blocked ones (§27.11 inv. 7),
  and every event carries enough correlation to trace back to its
  `plan_id` and `task_id` (§27.11 inv. 8).

  This context is intentionally independent of any specific hook struct
  module. Callers pass plain maps for `payload`, `raw_payload`, and
  `hook_results`; correlation IDs (`session_id`, `plan_id`, `task_id`,
  `agent_id`) flow through unchanged. Producers own correlation; this
  layer never invents it.
  """

  import Ecto.Query

  alias KiroCockpit.Repo
  alias KiroCockpit.Swarm.Events.SwarmEvent

  @default_limit 100
  @max_limit 500

  @type event_id :: Ecto.UUID.t()
  @type session_id :: String.t()
  @type plan_id :: Ecto.UUID.t()
  @type task_id :: Ecto.UUID.t()
  @type list_opts :: keyword() | map()
  @type create_result :: {:ok, SwarmEvent.t()} | {:error, Ecto.Changeset.t()}

  @doc """
  Inserts a Bronze swarm event from a map of attributes.

  Required keys:

    * `:session_id` (string) — ACP session identifier
    * `:agent_id` (string) — agent that produced the event
    * `:event_type` (string) — Bronze event type label

  Optional correlation:

    * `:plan_id` (uuid) — owning plan (§27.11 inv. 8)
    * `:task_id` (uuid) — owning task (§27.11 inv. 8)
    * `:phase` (string) — pre/post/lifecycle marker
    * `:payload` (map) — normalized event payload (default `%{}`)
    * `:raw_payload` (map) — original ACP/wrapper payload (default `%{}`)
    * `:hook_results` (map or list) — hook decisions/guidance (default `[]`)
    * `:created_at` (DateTime) — defaults to `DateTime.utc_now/0`
  """
  @spec create_event(map() | keyword()) :: create_result()
  def create_event(attrs) when is_map(attrs) or is_list(attrs) do
    %SwarmEvent{}
    |> SwarmEvent.changeset(Map.new(attrs))
    |> Repo.insert()
  end

  @doc """
  Fetches a swarm event by id, or returns `nil`.
  """
  @spec get_event(event_id()) :: SwarmEvent.t() | nil
  def get_event(event_id), do: Repo.get(SwarmEvent, event_id)

  @doc """
  Fetches a swarm event by id, or raises `Ecto.NoResultsError`.
  """
  @spec get_event!(event_id()) :: SwarmEvent.t()
  def get_event!(event_id), do: Repo.get!(SwarmEvent, event_id)

  @doc """
  Lists Bronze events for the given ACP session, ordered by `created_at`.

  Supported options: `:limit` (default #{@default_limit}, max #{@max_limit})
  and `:order` (`:asc` default or `:desc`).
  """
  @spec list_by_session(session_id(), list_opts()) :: [SwarmEvent.t()]
  def list_by_session(session_id, opts \\ []) when is_binary(session_id) do
    SwarmEvent
    |> where([event], event.session_id == ^session_id)
    |> apply_list_opts(opts)
    |> Repo.all()
  end

  @doc """
  Lists Bronze events for the given plan, ordered by `created_at`.

  Enforces §27.11 invariant 8: every event filed against a plan is
  recoverable from its `plan_id`.
  """
  @spec list_by_plan(plan_id(), list_opts()) :: [SwarmEvent.t()]
  def list_by_plan(plan_id, opts \\ []) when is_binary(plan_id) do
    SwarmEvent
    |> where([event], event.plan_id == ^plan_id)
    |> apply_list_opts(opts)
    |> Repo.all()
  end

  @doc """
  Lists Bronze events for the given task, ordered by `created_at`.

  Enforces §27.11 invariant 8: every event filed against a task is
  recoverable from its `task_id`.
  """
  @spec list_by_task(task_id(), list_opts()) :: [SwarmEvent.t()]
  def list_by_task(task_id, opts \\ []) when is_binary(task_id) do
    SwarmEvent
    |> where([event], event.task_id == ^task_id)
    |> apply_list_opts(opts)
    |> Repo.all()
  end

  @doc """
  Lists the most recent Bronze events across all sessions.

  Defaults to descending order so analyzer tailers see the freshest rows
  first. Supported options: `:limit`, `:order`, `:event_type`,
  `:session_id`, `:plan_id`, `:task_id`, `:agent_id`.
  """
  @spec list_recent(list_opts()) :: [SwarmEvent.t()]
  def list_recent(opts \\ []) do
    opts = Map.new(opts)

    SwarmEvent
    |> filter_equals(:event_type, Map.get(opts, :event_type))
    |> filter_equals(:session_id, Map.get(opts, :session_id))
    |> filter_equals(:plan_id, Map.get(opts, :plan_id))
    |> filter_equals(:task_id, Map.get(opts, :task_id))
    |> filter_equals(:agent_id, Map.get(opts, :agent_id))
    |> apply_list_opts(opts, default_order: :desc)
    |> Repo.all()
  end

  defp apply_list_opts(query, opts, defaults \\ []) do
    opts = Map.new(opts)
    default_order = Keyword.get(defaults, :default_order, :asc)
    order = normalize_order(Map.get(opts, :order, default_order))
    limit = normalize_limit(Map.get(opts, :limit, @default_limit))

    query
    |> order_events(order)
    |> maybe_limit(limit)
  end

  defp filter_equals(query, _field, nil), do: query

  defp filter_equals(query, field, value) do
    where(query, [event], field(event, ^field) == ^value)
  end

  defp order_events(query, :desc) do
    order_by(query, [event], desc: event.created_at, desc: event.id)
  end

  defp order_events(query, _asc) do
    order_by(query, [event], asc: event.created_at, asc: event.id)
  end

  defp normalize_order(:desc), do: :desc
  defp normalize_order("desc"), do: :desc
  defp normalize_order(_other), do: :asc

  defp maybe_limit(query, nil), do: query
  defp maybe_limit(query, limit), do: limit(query, ^limit)

  defp normalize_limit(nil), do: nil
  defp normalize_limit(limit) when is_integer(limit) and limit > @max_limit, do: @max_limit
  defp normalize_limit(limit) when is_integer(limit) and limit > 0, do: limit
  defp normalize_limit(_other), do: @default_limit
end
