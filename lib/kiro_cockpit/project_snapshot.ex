defmodule KiroCockpit.ProjectSnapshot do
  @moduledoc """
  Immutable, hashable snapshot of a project's discoverable state.

  Per plan2.md §8 and §16, a `ProjectSnapshot` captures the read-only
  project context that NanoPlanner uses for planning. The struct is
  deterministic — the same project directory at the same point in time
  produces the same snapshot and the same `hash`, suitable for stale-plan
  detection.

  **Never mutates project files.** All operations are read-only.

  ## Stale-plan detection (§16)

  The `hash` field is computed from the root tree listing, config file
  excerpts, and key file mtimes. Before approving or executing a plan,
  compare the stored `project_snapshot_hash` against a freshly computed
  snapshot. If they differ, the plan is stale.
  """

  @type t :: %__MODULE__{
          project_dir: String.t(),
          root_tree: String.t(),
          detected_stack: [String.t()],
          config_excerpts: %{String.t() => String.t()},
          file_fingerprints: %{String.t() => String.t()},
          existing_plans: String.t() | nil,
          session_summary: String.t() | nil,
          hash: String.t(),
          total_chars: non_neg_integer()
        }

  @enforce_keys [:project_dir, :hash]
  defstruct [
    :project_dir,
    :root_tree,
    :detected_stack,
    :config_excerpts,
    :file_fingerprints,
    :existing_plans,
    :session_summary,
    :hash,
    :total_chars
  ]

  alias KiroCockpit.ProjectSnapshot

  @doc """
  Computes a stable SHA-256 hash from snapshot content.

  The hash inputs are project-state fields only: root tree, detected stack,
  config excerpts, relevant file fingerprints, and existing project plans —
  in deterministic order so the same project state always yields the same
  hash. Conversational context such as `session_summary` is deliberately
  excluded so it can enrich the prompt without creating false stale-plan
  positives.
  """
  @spec compute_hash(t()) :: String.t()
  def compute_hash(%ProjectSnapshot{} = snapshot) do
    sorted_stack = (snapshot.detected_stack || []) |> Enum.sort() |> Enum.join(",")

    sorted_excerpts =
      snapshot.config_excerpts
      |> normalize_map()
      |> Enum.sort_by(fn {k, _v} -> k end)
      |> Enum.map_join("|", fn {k, v} -> "#{k}=#{v}" end)

    sorted_fingerprints =
      snapshot.file_fingerprints
      |> normalize_map()
      |> Enum.sort_by(fn {k, _v} -> k end)
      |> Enum.map_join("|", fn {k, v} -> "#{k}=#{v}" end)

    parts =
      [
        snapshot.root_tree || "",
        sorted_stack,
        sorted_excerpts,
        sorted_fingerprints,
        snapshot.existing_plans || ""
      ]
      |> Enum.join("||")

    :crypto.hash(:sha256, parts)
    |> Base.encode16(case: :lower)
  end

  @doc """
  Creates a new snapshot struct with the hash computed from its contents.

  All fields default to empty/nil except `project_dir` (required).
  """
  @spec new(String.t(), keyword()) :: t()
  def new(project_dir, opts \\ []) do
    snapshot = %ProjectSnapshot{
      project_dir: project_dir,
      root_tree: Keyword.get(opts, :root_tree),
      detected_stack: Keyword.get(opts, :detected_stack, []),
      config_excerpts: Keyword.get(opts, :config_excerpts, %{}),
      file_fingerprints: Keyword.get(opts, :file_fingerprints, %{}),
      existing_plans: Keyword.get(opts, :existing_plans),
      session_summary: Keyword.get(opts, :session_summary),
      hash: "placeholder",
      total_chars: Keyword.get(opts, :total_chars, 0)
    }

    %{snapshot | hash: compute_hash(snapshot)}
  end

  defp normalize_map(nil), do: %{}
  defp normalize_map(map) when is_map(map), do: map

  @doc """
  Renders the snapshot as compact markdown per §8 context format.

  Sections:
    - Project Snapshot (header)
    - Root files
    - Detected stack
    - Important config excerpts
    - Existing plans
    - Session summary
  """
  @spec to_markdown(t()) :: String.t()
  def to_markdown(%ProjectSnapshot{} = snapshot) do
    sections = [
      "# Project Snapshot",
      "",
      "## Root files",
      snapshot.root_tree || "(empty)",
      "",
      "## Detected stack",
      format_stack(snapshot.detected_stack),
      "",
      "## Important config excerpts",
      format_excerpts(snapshot.config_excerpts),
      "",
      "## Existing plans",
      snapshot.existing_plans || "(none)",
      "",
      "## Session summary",
      snapshot.session_summary || "(none)"
    ]

    Enum.join(sections, "\n")
  end

  defp format_stack([]), do: "(undetected)"
  defp format_stack(stack), do: Enum.join(stack, ", ")

  defp format_excerpts(excerpts) when is_map(excerpts) and map_size(excerpts) == 0,
    do: "(none)"

  defp format_excerpts(excerpts) do
    excerpts
    |> Enum.sort_by(fn {k, _v} -> k end)
    |> Enum.map_join("\n\n", fn {filename, content} -> "### #{filename}\n#{content}" end)
  end
end
