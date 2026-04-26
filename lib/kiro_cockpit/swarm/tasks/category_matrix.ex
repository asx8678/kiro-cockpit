defmodule KiroCockpit.Swarm.Tasks.CategoryMatrix do
  @moduledoc """
  Explicit, deterministic category gating matrix per §27.5 and §32.2.

  This module is the single source of truth for which permissions each
  Swarm task category allows, asks about, or blocks. It is **pure and
  deterministic** — no LLM calls, no runtime process state, no DB lookups.
  Every decision is a compile-time lookup into a static matrix.

  ## Decision verdicts

    - `:allow` — auto-allowed, no approval needed
    - `:ask`   — requires approval or policy check before proceeding
    - `:block` — hard denied; the category never permits this action

  ## Conditional entries

  Some matrix entries carry a `:condition` atom. When the caller supplies
  `opts` containing `condition: true`, the verdict is **promoted** one level:

    - `:block` → `:ask`  (condition unlocks the approval gate)
    - `:ask`  → `:allow` (condition satisfies the approval gate)

  For example, debugging's `:write` is `:block` with condition
  `:root_cause_stated`. If `root_cause_stated: true` is passed, the verdict
  becomes `:ask` (still needs approval, but no longer hard-blocked).

  ## Canonical categories (§27.5)

      researching | planning | acting | verifying | debugging | documenting

  ## Canonical permissions (§32.1)

      :read | :write | :shell_read | :shell_write | :terminal |
      :external | :destructive | :subagent | :memory_write

  `:memory_write` is classified by §32.1 but is not an explicit §32.2
  matrix column, so this module treats it as a conservative approval/pipeline
  policy gate rather than an auto-allowed documentation action.
  """

  alias KiroCockpit.Swarm.Tasks.CategoryMatrix.Decision

  @type permission ::
          :read
          | :write
          | :shell_read
          | :shell_write
          | :terminal
          | :external
          | :destructive
          | :subagent
          | :memory_write

  @type category :: String.t() | atom()

  @categories ~w(researching planning acting verifying debugging documenting)a

  @permissions ~w(read write shell_read shell_write terminal external destructive subagent memory_write)a

  @category_by_string Map.new(@categories, &{Atom.to_string(&1), &1})
  @permission_by_string Map.new(@permissions, &{Atom.to_string(&1), &1})

  @doc_path_prefixes ["docs/", "guides/", "priv/static/docs/"]
  @doc_file_names ["README", "CHANGELOG", "CONTRIBUTING", "LICENSE", "NOTICE"]
  @doc_extensions [".md", ".mdx", ".adoc", ".asciidoc", ".rst", ".txt"]

  @subagent_kinds %{
    researching: [:read_only],
    planning: [:read_only_reviewer],
    verifying: [:qa_reviewer, :reviewer],
    debugging: [:diagnostic_reviewer],
    documenting: [:docs_reviewer]
  }

  # ---------------------------------------------------------------------------
  # The matrix — §27.5 table + §32.2 permission matrix
  # ---------------------------------------------------------------------------
  # Each entry is a %Decision{} struct. Verdicts are:
  #   :allow — auto-allowed
  #   :ask   — needs approval/policy
  #   :block — hard denied
  # Condition atoms signal that the caller may promote the verdict one level.

  @matrix %{
    researching: %{
      read: %Decision{
        verdict: :allow,
        reason: "Researching allows reads"
      },
      write: %Decision{
        verdict: :block,
        reason: "Researching blocks mutating actions",
        guidance: "Convert task to acting category to write"
      },
      shell_read: %Decision{
        verdict: :allow,
        reason: "Non-mutating shell commands allowed for research"
      },
      shell_write: %Decision{
        verdict: :block,
        reason: "Researching blocks mutating shell commands"
      },
      terminal: %Decision{
        verdict: :block,
        reason: "Researching blocks interactive terminals"
      },
      external: %Decision{
        verdict: :ask,
        reason: "External access requires approval for research",
        guidance: "Request approval for docs/search access"
      },
      destructive: %Decision{
        verdict: :block,
        reason: "Researching blocks destructive actions"
      },
      subagent: %Decision{
        verdict: :ask,
        reason: "Subagent must be read-only in researching",
        guidance: "Only read-only subagents allowed"
      },
      memory_write: %Decision{
        verdict: :ask,
        reason: "Memory writes during research need approval",
        guidance: "Request approval to save research findings"
      }
    },
    planning: %{
      read: %Decision{
        verdict: :allow,
        reason: "Planning allows reads"
      },
      write: %Decision{
        verdict: :block,
        reason: "Planning blocks write/edit/bash/shell and implementation",
        guidance: "Planning is read-only; switch to acting for implementation"
      },
      shell_read: %Decision{
        verdict: :block,
        reason: "Planning blocks Bash/Shell by default",
        guidance: "Planning is read-only; delegate diagnostics to a reviewer or switch category"
      },
      shell_write: %Decision{
        verdict: :block,
        reason: "Planning blocks shell writes"
      },
      terminal: %Decision{
        verdict: :block,
        reason: "Planning blocks terminals"
      },
      external: %Decision{
        verdict: :ask,
        reason: "External access requires approval for planning",
        guidance: "Request approval for docs/search access"
      },
      destructive: %Decision{
        verdict: :block,
        reason: "Planning blocks destructive actions"
      },
      subagent: %Decision{
        verdict: :ask,
        reason: "Only read-only reviewers allowed in planning",
        guidance: "Subagents must be read-only reviewers"
      },
      memory_write: %Decision{
        verdict: :ask,
        reason: "Memory writes during planning need approval",
        guidance: "Request approval to consolidate planning insights"
      }
    },
    acting: %{
      read: %Decision{
        verdict: :allow,
        reason: "Acting allows reads"
      },
      write: %Decision{
        verdict: :ask,
        reason: "Write requires policy clearance and explicit approval",
        guidance: "Ensure write is within task scope, policy allows, and approval is durable"
      },
      shell_read: %Decision{
        verdict: :ask,
        reason: "Shell read requires approval in acting",
        guidance: "Request approval for shell read operations"
      },
      shell_write: %Decision{
        verdict: :ask,
        reason: "Shell writes require approval in acting",
        guidance: "Request approval for shell write operations"
      },
      terminal: %Decision{
        verdict: :ask,
        reason: "Terminal access requires approval in acting",
        guidance: "Request approval for terminal access"
      },
      external: %Decision{
        verdict: :ask,
        reason: "External access requires approval in acting",
        guidance: "Request approval for external access"
      },
      destructive: %Decision{
        verdict: :ask,
        reason: "Destructive actions require explicit approval",
        guidance: "Explicit approval required for destructive operations"
      },
      subagent: %Decision{
        verdict: :ask,
        reason: "Subagent invocation requires approval in acting",
        guidance: "Only approved subagents allowed"
      },
      memory_write: %Decision{
        verdict: :ask,
        reason: "Memory writes during acting need approval",
        guidance: "Request approval to promote acting artifacts"
      }
    },
    verifying: %{
      read: %Decision{
        verdict: :allow,
        reason: "Verifying allows reads"
      },
      write: %Decision{
        verdict: :block,
        reason: "Verifying blocks new feature work",
        guidance: "Only test fixture fixes allowed; recategorize to acting for implementation",
        condition: :fixing_test_fixture
      },
      shell_read: %Decision{
        verdict: :allow,
        reason: "Verifying allows non-mutating shell commands"
      },
      shell_write: %Decision{
        verdict: :ask,
        reason: "Shell writes require approval in verifying",
        guidance: "Request approval for shell write operations"
      },
      terminal: %Decision{
        verdict: :ask,
        reason: "Terminal access requires approval in verifying",
        guidance: "Request approval for terminal access"
      },
      external: %Decision{
        verdict: :ask,
        reason: "External access requires approval in verifying",
        guidance: "Request approval for external access"
      },
      destructive: %Decision{
        verdict: :block,
        reason: "Verifying blocks destructive actions"
      },
      subagent: %Decision{
        verdict: :ask,
        reason: "Only QA/review subagents allowed in verifying",
        guidance: "Subagents must be QA/reviewers"
      },
      memory_write: %Decision{
        verdict: :ask,
        reason: "Memory writes during verification need approval",
        guidance: "Request approval to save verification findings"
      }
    },
    debugging: %{
      read: %Decision{
        verdict: :allow,
        reason: "Debugging allows reads"
      },
      write: %Decision{
        verdict: :block,
        reason: "Debugging blocks writes until root cause is stated",
        guidance: "State root cause before writing; recategorize to acting for fixes",
        condition: :root_cause_stated
      },
      shell_read: %Decision{
        verdict: :allow,
        reason: "Debugging allows diagnostic shell commands"
      },
      shell_write: %Decision{
        verdict: :block,
        reason: "Debugging blocks shell writes until approved",
        guidance: "Request approval after root cause is stated",
        condition: :root_cause_stated
      },
      terminal: %Decision{
        verdict: :ask,
        reason: "Terminal access requires approval in debugging",
        guidance: "Request approval for terminal access"
      },
      external: %Decision{
        verdict: :ask,
        reason: "External access requires approval in debugging",
        guidance: "Request approval for external access"
      },
      destructive: %Decision{
        verdict: :block,
        reason: "Debugging blocks destructive actions"
      },
      subagent: %Decision{
        verdict: :ask,
        reason: "Only diagnostic reviewers allowed in debugging",
        guidance: "Subagents must be diagnostic reviewers"
      },
      memory_write: %Decision{
        verdict: :ask,
        reason: "Memory writes during debugging need approval",
        guidance: "Request approval after root cause is identified"
      }
    },
    documenting: %{
      read: %Decision{
        verdict: :allow,
        reason: "Documenting allows reads"
      },
      write: %Decision{
        verdict: :ask,
        reason: "Writes must be docs-scoped in documenting",
        guidance: "Only documentation writes allowed; recategorize for code changes",
        condition: :docs_scoped
      },
      shell_read: %Decision{
        verdict: :allow,
        reason: "Documenting allows non-mutating shell commands"
      },
      shell_write: %Decision{
        verdict: :block,
        reason: "Documenting blocks shell writes"
      },
      terminal: %Decision{
        verdict: :block,
        reason: "Documenting blocks terminals"
      },
      external: %Decision{
        verdict: :ask,
        reason: "External access requires approval in documenting",
        guidance: "Request approval for external access"
      },
      destructive: %Decision{
        verdict: :block,
        reason: "Documenting blocks destructive actions"
      },
      subagent: %Decision{
        verdict: :ask,
        reason: "Only docs reviewers allowed in documenting",
        guidance: "Subagents must be documentation reviewers"
      },
      memory_write: %Decision{
        verdict: :ask,
        reason: "Memory writes require approval/pipeline policy",
        guidance: "Use the approved Silver/Gold memory promotion pipeline"
      }
    }
  }

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Returns the list of canonical task categories (§27.5).
  """
  @spec categories() :: [atom()]
  def categories, do: @categories

  @doc """
  Returns the list of canonical permissions (§32.1).
  """
  @spec permissions() :: [atom()]
  def permissions, do: @permissions

  @doc """
  Looks up the gating decision for a category and permission.

  Opts may include:
    - `root_cause_stated: true` — promotes debugging write/shell_write
    - `fixing_test_fixture: true` — promotes verifying write
    - `docs_scoped: true` — promotes documenting write
    - `policy_allows_write: true` — consumed by `TaskScope` for acting writes
    - Any condition atom matching a matrix entry's `condition` field

  Returns a `%Decision{}` struct. For unknown categories or permissions,
  returns a `:block` decision.

  ## Examples

      iex> CategoryMatrix.decision("researching", :read)
      %Decision{verdict: :allow, reason: "Researching allows reads", ...}

      iex> CategoryMatrix.decision("debugging", :write, root_cause_stated: true)
      %Decision{verdict: :ask, reason: "Debugging blocks writes until root cause is stated", ...}

      iex> CategoryMatrix.decision("documenting", :write, docs_scoped: true)
      %Decision{verdict: :allow, reason: "Writes must be docs-scoped in documenting", ...}
  """
  @spec decision(category(), permission(), keyword()) :: Decision.t()
  def decision(category, permission, opts \\ []) do
    cat_key = normalize_category(category)
    perm_key = normalize_permission(permission)

    case get_in(@matrix, [cat_key, perm_key]) do
      nil ->
        %Decision{
          verdict: :block,
          reason: "Unknown category or permission",
          guidance: "Category '#{category}' or permission '#{permission}' not found in matrix"
        }

      entry ->
        entry
        |> enforce_contextual_qualifiers(cat_key, perm_key, opts)
        |> evaluate_condition(opts)
    end
  end

  @doc """
  Returns all raw matrix permissions with the given verdict for a category.

  Useful for determining what a category auto-allows (`:allow`), what
  needs approval (`:ask`), or what is hard-blocked (`:block`) before
  deterministic contextual qualifiers such as subagent role metadata are
  applied. Use `decision/3` for the enforced verdict for a concrete action.

  ## Examples

      iex> CategoryMatrix.permissions_with_verdict("researching", :allow)
      [:read, :shell_read]
  """
  @spec permissions_with_verdict(category(), Decision.verdict()) :: [permission()]
  def permissions_with_verdict(category, verdict) when verdict in [:allow, :ask, :block] do
    cat_key = normalize_category(category)

    case Map.get(@matrix, cat_key) do
      nil ->
        []

      perms ->
        perms
        |> Enum.filter(fn {_perm, %Decision{verdict: v}} -> v == verdict end)
        |> Enum.map(fn {perm, _} -> perm end)
        |> Enum.sort_by(&permission_index/1)
    end
  end

  @doc """
  Returns all permissions that are not hard-blocked for a category.

  This is the **hard ceiling** — the maximum set of permissions a category
  could ever use (including those requiring approval).

  ## Examples

      iex> CategoryMatrix.non_blocked_permissions("researching")
      [:read, :shell_read, :external, :subagent, :memory_write]
  """
  @spec non_blocked_permissions(category()) :: [permission()]
  def non_blocked_permissions(category) do
    cat_key = normalize_category(category)

    case Map.get(@matrix, cat_key) do
      nil ->
        []

      perms ->
        perms
        |> Enum.reject(fn {_perm, %Decision{verdict: v}} -> v == :block end)
        |> Enum.map(fn {perm, _} -> perm end)
        |> Enum.sort_by(&permission_index/1)
    end
  end

  @doc """
  Returns the auto-allowed permissions for a category (verdict `:allow` only).

  These are permissions that require no approval or policy check.
  """
  @spec auto_allowed_permissions(category()) :: [permission()]
  def auto_allowed_permissions(category) do
    permissions_with_verdict(category, :allow)
  end

  # ---------------------------------------------------------------------------
  # Category classification helpers
  # ---------------------------------------------------------------------------

  @doc """
  Returns categories that can write (write verdict is not `:block`).

  Per §27.5, `acting` and `documenting` allow writes (with conditions/approval);
  all other categories hard-block writes by default.
  """
  @spec write_capable_categories() :: [atom()]
  def write_capable_categories do
    Enum.filter(@categories, fn cat ->
      case decision(cat, :write) do
        %Decision{verdict: :block} -> false
        %Decision{} -> true
      end
    end)
  end

  @doc """
  Returns categories where write is hard-blocked (read-only/diagnostic).

  These categories cannot write under any condition without
  recategorization.
  """
  @spec read_only_categories() :: [atom()]
  def read_only_categories do
    Enum.filter(@categories, fn cat ->
      case decision(cat, :write) do
        %Decision{verdict: :block, condition: nil} -> true
        %Decision{} -> false
      end
    end)
  end

  @doc """
  Returns categories where write is blocked but has a condition that
  could promote it (conditional-write categories).

  These categories hard-block writes by default, but a specific condition
  can unlock the `:ask` gate.
  """
  @spec conditional_write_categories() :: [atom()]
  def conditional_write_categories do
    Enum.filter(@categories, fn cat ->
      case decision(cat, :write) do
        %Decision{verdict: :block, condition: cond_atom} when not is_nil(cond_atom) -> true
        %Decision{} -> false
      end
    end)
  end

  @doc """
  Returns categories where write needs approval but is not hard-blocked
  (ask-write categories).
  """
  @spec ask_write_categories() :: [atom()]
  def ask_write_categories do
    Enum.filter(@categories, fn cat ->
      case decision(cat, :write) do
        %Decision{verdict: :ask} -> true
        %Decision{} -> false
      end
    end)
  end

  @doc """
  Returns categories that are primarily diagnostic in nature.

  Diagnostic categories allow reads and diagnostic shell commands but
  block writes by default.
  """
  @spec diagnostic_categories() :: [atom()]
  def diagnostic_categories do
    [:verifying, :debugging]
  end

  @doc """
  Checks whether a debugging task has its write gate unlocked.

  Accepts either keyword opts (`root_cause_stated: true`) or a task-like
  struct/map with a `notes` collection. A root-cause note is detected
  deterministically from common note shapes such as:

    - `%{type: "root_cause"}` or `%{"type" => "root_cause"}`
    - `%{root_cause: "..."}` or `%{"root_cause" => "..."}`
    - text/content/message containing the phrase `root cause`

  The helper only unlocks debugging from hard-block to approval-gated; it
  does not auto-approve the write.
  """
  @spec debugging_write_unlocked?(keyword() | map()) :: boolean()
  def debugging_write_unlocked?(opts) when is_list(opts) do
    Keyword.get(opts, :root_cause_stated, false)
  end

  def debugging_write_unlocked?(%{notes: notes}) when is_list(notes) do
    Enum.any?(notes, &root_cause_note?/1)
  end

  def debugging_write_unlocked?(_other), do: false

  @doc """
  Checks whether a documenting task's write is docs-scoped.

  Accepts keyword opts with `docs_scoped: true`, `path: "..."`, or
  `paths: ["..."]`. Path checks are deterministic and limited to
  conventional documentation locations/names/extensions.
  """
  @spec documenting_write_docs_scoped?(keyword() | String.t() | [String.t()]) :: boolean()
  def documenting_write_docs_scoped?(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      cond do
        Keyword.get(opts, :docs_scoped, false) -> true
        path = Keyword.get(opts, :path) -> docs_scoped_path?(path)
        paths = Keyword.get(opts, :paths) -> docs_scoped_paths?(paths)
        true -> false
      end
    else
      docs_scoped_paths?(opts)
    end
  end

  def documenting_write_docs_scoped?(path) when is_binary(path), do: docs_scoped_path?(path)

  @doc """
  Returns true when every supplied path is documentation-scoped.
  """
  @spec docs_scoped_paths?([String.t()]) :: boolean()
  def docs_scoped_paths?(paths) when is_list(paths) do
    paths != [] and Enum.all?(paths, &docs_scoped_path?/1)
  end

  @doc """
  Returns true for conventional documentation paths.
  """
  @spec docs_scoped_path?(String.t()) :: boolean()
  def docs_scoped_path?(path) when is_binary(path) do
    if safe_relative_path?(path) do
      relative = path |> Path.expand("/workspace") |> Path.relative_to("/workspace")
      basename = Path.basename(relative)
      stem = Path.rootname(basename)

      String.starts_with?(relative, @doc_path_prefixes) or
        stem in @doc_file_names or
        Path.extname(relative) in @doc_extensions
    else
      false
    end
  end

  def docs_scoped_path?(_path), do: false

  defp safe_relative_path?(path) do
    Path.type(path) == :relative and not Enum.any?(Path.split(path), &(&1 in [".", ".."]))
  end

  @doc """
  Returns a summary of hard blocks for a category.

  Useful for UI/steering to display what a category absolutely
  cannot do.
  """
  @spec hard_blocks(category()) :: [permission()]
  def hard_blocks(category) do
    permissions_with_verdict(category, :block)
  end

  @doc """
  Returns a summary of guidance messages for a category.

  Maps each non-allowed permission to its guidance text (if any).
  Useful for steering/UI to present actionable next steps.
  """
  @spec guidance_summary(category()) :: [{permission(), String.t()}]
  def guidance_summary(category) do
    cat_key = normalize_category(category)

    case Map.get(@matrix, cat_key) do
      nil ->
        []

      perms ->
        perms
        |> Enum.filter(fn {_perm, %Decision{verdict: v}} -> v in [:ask, :block] end)
        |> Enum.map(fn {perm, %Decision{guidance: g}} -> {perm, g || ""} end)
        |> Enum.sort_by(fn {perm, _} -> permission_index(perm) end)
    end
  end

  @doc """
  Returns the full matrix map (for inspection/testing).
  """
  @spec matrix() :: map()
  def matrix, do: @matrix

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  @spec normalize_category(category()) :: atom() | nil
  defp normalize_category(cat) when cat in @categories, do: cat

  defp normalize_category(cat) when is_binary(cat) do
    Map.get(@category_by_string, cat)
  end

  defp normalize_category(_), do: nil

  @spec normalize_permission(permission() | String.t()) :: atom() | nil
  defp normalize_permission(perm) when perm in @permissions, do: perm

  defp normalize_permission(perm) when is_binary(perm) do
    Map.get(@permission_by_string, perm)
  end

  defp normalize_permission(_), do: nil

  defp enforce_contextual_qualifiers(entry, :documenting, :write, opts) do
    cond do
      not paths_present?(opts) ->
        entry

      documenting_write_docs_scoped?(opts) ->
        entry

      true ->
        %Decision{
          verdict: :block,
          reason: "Documenting blocks code changes by default",
          guidance: "Recategorize the task for code changes or target documentation files"
        }
    end
  end

  defp enforce_contextual_qualifiers(entry, category, :subagent, opts) do
    case Map.fetch(@subagent_kinds, category) do
      {:ok, allowed_kinds} -> enforce_subagent_kind(entry, allowed_kinds, opts)
      :error -> entry
    end
  end

  defp enforce_contextual_qualifiers(entry, _category, _permission, _opts), do: entry

  defp enforce_subagent_kind(entry, allowed_kinds, opts) do
    case Keyword.get(opts, :subagent_kind) do
      nil ->
        %Decision{
          verdict: :block,
          reason: "Subagent role is required for this category",
          guidance: "Provide trusted subagent_kind; allowed: #{Enum.join(allowed_kinds, ", ")}"
        }

      kind ->
        if kind in allowed_kinds do
          entry
        else
          %Decision{
            verdict: :block,
            reason: "Subagent role #{inspect(kind)} is not allowed for this category",
            guidance: "Allowed subagent roles: #{Enum.join(allowed_kinds, ", ")}"
          }
        end
    end
  end

  defp paths_present?(opts) do
    Keyword.has_key?(opts, :path) or Keyword.has_key?(opts, :paths)
  end

  @spec evaluate_condition(Decision.t(), keyword()) :: Decision.t()
  defp evaluate_condition(%Decision{condition: nil} = entry, _opts), do: entry

  defp evaluate_condition(%Decision{condition: cond_atom} = entry, opts) do
    if Keyword.get(opts, cond_atom, false) do
      promote(entry)
    else
      entry
    end
  end

  @spec promote(Decision.t()) :: Decision.t()
  defp promote(%Decision{verdict: :block} = entry) do
    %{entry | verdict: :ask}
  end

  defp promote(%Decision{verdict: :ask} = entry) do
    %{entry | verdict: :allow}
  end

  defp promote(%Decision{verdict: :allow} = entry), do: entry

  defp root_cause_note?(note) when is_map(note) do
    root_cause_field?(first_present(note, [:root_cause, "root_cause"])) or
      root_cause_type?(first_present(note, [:type, "type", :kind, "kind"])) or
      root_cause_text?(
        first_present(note, [:content, "content", :message, "message", :text, "text"])
      )
  end

  defp root_cause_note?(note) when is_binary(note), do: root_cause_text?(note)
  defp root_cause_note?(_note), do: false

  defp first_present(map, keys) do
    Enum.find_value(keys, &Map.get(map, &1))
  end

  defp root_cause_field?(value) when is_binary(value), do: String.trim(value) != ""
  defp root_cause_field?(_value), do: false

  defp root_cause_type?(value) when is_binary(value) do
    value in ["root_cause", "root-cause", "root cause"]
  end

  defp root_cause_type?(value) when is_atom(value), do: value == :root_cause
  defp root_cause_type?(_value), do: false

  defp root_cause_text?(value) when is_binary(value) do
    value |> String.downcase() |> String.contains?("root cause")
  end

  defp root_cause_text?(_value), do: false

  @spec permission_index(atom()) :: non_neg_integer()
  defp permission_index(perm) do
    Enum.find_index(@permissions, &(&1 == perm)) || 999
  end
end
