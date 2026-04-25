defmodule KiroCockpit.NanoPlanner.PlanSchema do
  @moduledoc """
  Normalized planning output from NanoPlanner (§7).

  Validates and normalizes plan maps from LLM output into a deterministic
  shape suitable for UI rendering, persistence via `KiroCockpit.Plans`, and
  Kiro execution handoff.

  ## Required keys

    - `:objective`        — what the plan aims to achieve
    - `:summary`          — concise description
    - `:phases`           — list of phase maps with steps
    - `:permissions_needed` — list of permission atoms/strings
    - `:acceptance_criteria` — list of criteria strings
    - `:risks`            — list of risk maps or strings
    - `:execution_prompt` — the Kiro-ready prompt sent after approval

  ## Optional keys

    - `:mode`, `:status`, `:assumptions`, `:project_snapshot`,
      `:alternatives`, `:plan_markdown`

  ## Normalization

  Accepts both atom and string keys. Normalizes all keys to atoms,
  normalizes permission levels via `KiroCockpit.Permissions`, and
  produces a deterministic map suitable for `flatten_steps/1`.
  """

  alias KiroCockpit.Permissions

  @required_keys [
    :objective,
    :summary,
    :phases,
    :permissions_needed,
    :acceptance_criteria,
    :risks,
    :execution_prompt
  ]

  @optional_keys [
    :mode,
    :status,
    :assumptions,
    :project_snapshot,
    :alternatives,
    :plan_markdown
  ]

  @type normalized_plan :: %{
          required(:objective) => String.t(),
          required(:summary) => String.t(),
          required(:phases) => [phase()],
          required(:permissions_needed) => [Permissions.permission()],
          required(:acceptance_criteria) => [String.t()],
          required(:risks) => [map() | String.t()],
          required(:execution_prompt) => String.t(),
          optional(:mode) => String.t() | nil,
          optional(:status) => String.t() | nil,
          optional(:assumptions) => [String.t()],
          optional(:project_snapshot) => map() | nil,
          optional(:alternatives) => [map()] | nil,
          optional(:plan_markdown) => String.t() | nil
        }

  @type phase :: %{
          required(:number) => pos_integer(),
          required(:title) => String.t(),
          required(:steps) => [step()]
        }

  @type step :: %{
          required(:title) => String.t(),
          optional(:details) => String.t(),
          optional(:files) => [String.t()] | map(),
          optional(:permission) => Permissions.permission() | String.t(),
          optional(:permission_level) => Permissions.permission() | String.t(),
          optional(:validation) => String.t()
        }

  @type flat_step :: %{
          required(:phase_number) => pos_integer(),
          required(:step_number) => pos_integer(),
          required(:title) => String.t(),
          optional(:details) => String.t() | nil,
          optional(:files) => map(),
          optional(:permission_level) => String.t(),
          optional(:validation) => String.t() | nil,
          optional(:status) => String.t()
        }

  @type validation_error ::
          {:missing_keys, [atom()]}
          | {:invalid_phases, String.t()}
          | {:invalid_permissions, [term()]}

  # ── Public API ──────────────────────────────────────────────────────

  @doc """
  Validates and normalizes a plan map, raising on failure.

  Accepts maps with atom or string keys. Returns a normalized map
  with all keys as atoms and permissions normalized.

  ## Examples

      iex> PlanSchema.validate!(%{"objective" => "Build X", "summary" => "S", ...})
      %{objective: "Build X", summary: "S", ...}

      iex> PlanSchema.validate!(%{objective: "X"})
      ** (ArgumentError) NanoPlanner output missing required keys: [...]
  """
  @spec validate!(map()) :: normalized_plan()
  def validate!(plan) when is_map(plan) do
    case validate(plan) do
      {:ok, normalized} -> normalized
      {:error, reasons} -> raise ArgumentError, format_errors(reasons)
    end
  end

  @doc """
  Validates and normalizes a plan map, returning tagged tuples.

  Returns `{:ok, normalized_plan}` on success, or
  `{:error, [validation_error]}` on failure.
  """
  @spec validate(map()) :: {:ok, normalized_plan()} | {:error, [validation_error()]}
  def validate(plan) when is_map(plan) do
    with {:ok, _} <- check_required_keys(plan),
         {:ok, _} <- check_phases(plan),
         {:ok, _} <- check_permissions(plan) do
      {:ok, normalize(plan)}
    end
  end

  @doc """
  Flattens a validated/normalized plan into step maps for persistence.

  Each step becomes a flat map compatible with `KiroCockpit.Plans.create_plan/5`:

      %{
        phase_number: 1,
        step_number: 1,
        title: "Do the thing",
        details: "Details here",
        files: %{"path.ex" => ""},
        permission_level: "write",
        validation: "Check it works",
        status: "planned"
      }

  `files` is converted from a list of paths to a map (required by jsonb
  object constraint on `plan_steps`). `permission_level` is normalized
  and stringified. `status` defaults to `"planned"`.
  """
  @spec flatten_steps(normalized_plan()) :: [flat_step()]
  def flatten_steps(plan) when is_map(plan) do
    phases = get_field(plan, :phases) || []

    phases
    |> Enum.sort_by(&get_field(&1, :number))
    |> Enum.flat_map(fn phase ->
      phase_number = get_field(phase, :number)
      steps = get_field(phase, :steps) || []

      steps
      |> Enum.with_index(1)
      |> Enum.map(fn {step, step_number} ->
        %{
          phase_number: phase_number,
          step_number: step_number,
          title: get_field(step, :title) || "",
          details: get_field(step, :details) || get_field(step, :description),
          files: normalize_files(get_field(step, :files)),
          permission_level:
            step
            |> extract_step_permission()
            |> Permissions.normalize_permission()
            |> to_string(),
          validation: get_field(step, :validation),
          status: "planned"
        }
      end)
    end)
  end

  @doc """
  Returns the list of required keys.
  """
  @spec required_keys() :: [atom()]
  def required_keys, do: @required_keys

  @doc """
  Returns the list of optional keys.
  """
  @spec optional_keys() :: [atom()]
  def optional_keys, do: @optional_keys

  @doc """
  Formats validation errors into a concise human-readable string.
  """
  @spec format_validation_errors([validation_error()]) :: String.t()
  def format_validation_errors(reasons) when is_list(reasons) do
    reasons
    |> Enum.map_join("; ", fn
      {:missing_keys, keys} -> "missing required keys: #{inspect(keys)}"
      {:invalid_phases, msg} -> "invalid phases: #{msg}"
      {:invalid_permissions, perms} -> "invalid permissions: #{inspect(perms)}"
    end)
  end

  # ── Validation ──────────────────────────────────────────────────────

  defp check_required_keys(plan) do
    missing =
      @required_keys
      |> Enum.reject(fn key ->
        Map.has_key?(plan, key) or Map.has_key?(plan, Atom.to_string(key))
      end)

    case missing do
      [] -> {:ok, plan}
      keys -> {:error, [{:missing_keys, keys}]}
    end
  end

  defp check_phases(plan) do
    phases = get_field(plan, :phases)

    cond do
      is_nil(phases) ->
        {:error, [{:invalid_phases, "phases is nil"}]}

      not is_list(phases) ->
        {:error, [{:invalid_phases, "phases must be a list, got: #{inspect(phases)}"}]}

      Enum.empty?(phases) ->
        {:error, [{:invalid_phases, "phases must not be empty"}]}

      true ->
        case find_invalid_phase(phases) do
          nil -> {:ok, plan}
          error -> {:error, [error]}
        end
    end
  end

  defp find_invalid_phase(phases) do
    Enum.find_value(phases, &validate_phase/1)
  end

  defp validate_phase(phase) do
    with :ok <- validate_phase_is_map(phase),
         :ok <- validate_phase_number(phase),
         :ok <- validate_phase_steps(phase) do
      find_invalid_step(get_field(phase, :steps))
    end
  end

  defp validate_phase_is_map(phase) when is_map(phase), do: :ok

  defp validate_phase_is_map(phase),
    do: {:invalid_phases, "each phase must be a map, got: #{inspect(phase)}"}

  defp validate_phase_number(phase) do
    number = get_field(phase, :number)

    cond do
      is_nil(number) ->
        {:invalid_phases, "phase missing required key: number"}

      not (is_integer(number) and number > 0) ->
        {:invalid_phases, "phase number must be a positive integer, got: #{inspect(number)}"}

      true ->
        :ok
    end
  end

  defp validate_phase_steps(phase) do
    steps = get_field(phase, :steps)

    cond do
      not is_list(steps) ->
        {:invalid_phases, "phase steps must be a list, got: #{inspect(steps)}"}

      Enum.empty?(steps) ->
        {:invalid_phases, "phase #{get_field(phase, :number)} has no steps"}

      true ->
        :ok
    end
  end

  defp find_invalid_step(steps) do
    Enum.find_value(steps, fn step ->
      cond do
        not is_map(step) ->
          {:invalid_phases, "each step must be a map, got: #{inspect(step)}"}

        is_nil(get_field(step, :title)) or get_field(step, :title) == "" ->
          {:invalid_phases, "step missing required key: title"}

        true ->
          nil
      end
    end)
  end

  defp check_permissions(plan) do
    perms = get_field(plan, :permissions_needed)

    invalid =
      case perms do
        nil ->
          []

        perms when is_list(perms) ->
          perms
          |> Enum.reject(&valid_permission?/1)

        _ ->
          [perms]
      end

    case invalid do
      [] -> {:ok, plan}
      bad -> {:error, [{:invalid_permissions, bad}]}
    end
  end

  @canonical_permissions Permissions.escalation_order()
  @canonical_permission_strings Enum.map(@canonical_permissions, &to_string/1)
  @permission_alias_strings ~w(shell shell_readonly)

  defp valid_permission?(perm) when perm in @canonical_permissions, do: true

  defp valid_permission?(perm) when is_binary(perm) do
    normalized = String.downcase(perm)
    normalized in @canonical_permission_strings or normalized in @permission_alias_strings
  end

  defp valid_permission?(_), do: false

  # ── Normalization ────────────────────────────────────────────────────

  defp normalize(plan) do
    # Start with required keys normalized
    normalized =
      @required_keys
      |> Enum.map(fn key -> {key, get_field(plan, key)} end)
      |> Map.new()

    # Add optional keys that are present
    normalized =
      @optional_keys
      |> Enum.reduce(normalized, fn key, acc ->
        case get_field(plan, key) do
          nil -> acc
          value -> Map.put(acc, key, value)
        end
      end)

    # Normalize permissions
    normalized =
      Map.update!(normalized, :permissions_needed, fn perms ->
        Permissions.normalize_permissions(perms || [])
      end)

    # Normalize phases
    Map.update!(normalized, :phases, fn phases ->
      Enum.map(phases, &normalize_phase/1)
    end)
  end

  defp normalize_phase(phase) do
    %{
      number: get_field(phase, :number),
      title: get_field(phase, :title) || "Phase #{get_field(phase, :number)}",
      steps: Enum.map(get_field(phase, :steps) || [], &normalize_step/1)
    }
  end

  defp normalize_step(step) do
    perm = extract_step_permission(step)

    %{
      title: get_field(step, :title),
      details: get_field(step, :details) || get_field(step, :description),
      files: get_field(step, :files),
      permission: Permissions.normalize_permission(perm),
      validation: get_field(step, :validation)
    }
  end

  defp extract_step_permission(step) do
    get_field(step, :permission_level) ||
      get_field(step, :permission) ||
      get_field(step, :permissions) ||
      :read
  end

  defp normalize_files(nil), do: %{}

  defp normalize_files(files) when is_map(files), do: files

  defp normalize_files(files) when is_list(files) do
    # Convert a list of file paths to a map for jsonb object constraint.
    # Each path maps to an empty string; the caller can enrich later.
    Map.new(files, fn path -> {to_string(path), ""} end)
  end

  defp normalize_files(_), do: %{}

  # ── Helpers ─────────────────────────────────────────────────────────

  defp get_field(map, key) when is_map(map) do
    Map.get(map, key, Map.get(map, to_string(key)))
  end

  defp format_errors(reasons) do
    "NanoPlanner output validation failed: #{format_validation_errors(reasons)}"
  end
end
