defmodule KiroCockpit.Swarm.Events.JsonAny do
  @moduledoc """
  Ecto type for a jsonb column that legitimately needs to hold either a
  JSON object or a JSON array at the top level.

  Scoped use only: `swarm_events.hook_results` per plan2.md §34.2 stores
  either a list of hook decisions or a map of summaries depending on the
  capture site. The standard `:map` type rejects lists at cast/load, so we
  define a narrow shim that round-trips both shapes through Postgres jsonb.

  Other JSON columns should keep using `:map`. This type exists for the
  `hook_results` shape and nothing else.
  """

  use Ecto.Type

  @impl Ecto.Type
  def type, do: :map

  @impl Ecto.Type
  def cast(value) when is_map(value), do: {:ok, value}
  def cast(value) when is_list(value), do: {:ok, value}
  def cast(nil), do: {:ok, nil}
  def cast(_value), do: :error

  @impl Ecto.Type
  def load(value) when is_map(value), do: {:ok, value}
  def load(value) when is_list(value), do: {:ok, value}
  def load(nil), do: {:ok, nil}
  def load(_value), do: :error

  @impl Ecto.Type
  def dump(value) when is_map(value), do: {:ok, value}
  def dump(value) when is_list(value), do: {:ok, value}
  def dump(nil), do: {:ok, nil}
  def dump(_value), do: :error

  @impl Ecto.Type
  def embed_as(_format), do: :self

  @impl Ecto.Type
  def equal?(a, b), do: a == b
end
