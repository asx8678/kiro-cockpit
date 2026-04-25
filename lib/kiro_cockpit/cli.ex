defmodule KiroCockpit.CLI do
  @moduledoc """
  Slash-command parser and dispatcher for the NanoPlanner CLI surface
  (plan2.md §12).

  The CLI is a deterministic, side-effect-free **parser** + a thin
  **dispatcher** that delegates to existing application services
  (`KiroCockpit.NanoPlanner` and `KiroCockpit.Plans`). It does NOT
  reach into runtime internals (no GenServer pids, no ETS, no Repo
  calls) — every effect goes through an injectable service module so
  the parser and dispatcher are unit-testable without a real Kiro
  subprocess or database.

  ## Surface

      /nano <task>
      /nano-deep <task>
      /nano-fix <problem>
      /plans
      /plan show <id>
      /plan approve <id>
      /plan revise <id> <request>
      /plan reject <id> [reason]
      /plan run <id>

  ## Pipeline

      raw_input  ──► parse/1 ──► dispatch/2 ──► {:ok | :error, payload}

  `parse/1` is pure: it returns `{:ok, command}` or `{:error, reason}`
  with NO IO and NO service calls. `dispatch/2` takes the parsed
  command and an opts list and calls the appropriate service module.

  ## Injectable service modules

  All callers may pass:

    * `:nano_planner_module` (default `KiroCockpit.NanoPlanner`) —
      must implement `plan/3`, `approve/3`, and `revise/4`.
    * `:plans_module` (default `KiroCockpit.Plans`) — must implement
      `get_plan/1`, `list_plans/2`, and `reject_plan/2`.
    * `:session` — opaque session reference passed through to
      `NanoPlanner` (default `nil`; required for `/nano*` and
      `/plan approve|revise`).
    * `:session_id` — session id used for `/plans` listing (required
      for `/plans`).

  Any additional opts are forwarded to the underlying service
  function, allowing callers (or tests) to override `:project_dir`,
  `:kiro_session_module`, `:planner_timeout`, etc.

  ## Result shape

  Successful dispatch returns `{:ok, %{kind: atom, ...}}`. The `:kind`
  field is the **stable machine-readable contract** (e.g.
  `:plan_created`, `:plan_approved`, `:plans_listed`). Errors return
  `{:error, %{code: atom, message: String.t(), ...}}` where `:code` is
  also stable. See `t:result/0`.
  """

  alias KiroCockpit.CLI.Commands.Nano
  alias KiroCockpit.CLI.Commands.Plan

  @typedoc "Parsed slash-command, ready for `dispatch/2`."
  @type command ::
          {:nano, mode :: :nano | :nano_deep | :nano_fix, task :: String.t()}
          | {:plans}
          | {:plan, action :: :show | :approve | :reject | :run, id :: String.t()}
          | {:plan, :revise, id :: String.t(), request :: String.t()}
          | {:plan, :reject, id :: String.t(), reason :: String.t() | nil}

  @typedoc "Dispatcher result. The `:kind` and `:code` fields are stable contracts."
  @type result ::
          {:ok, map()}
          | {:error, %{required(:code) => atom(), required(:message) => String.t()}}

  @typedoc "Reasons `parse/1` may reject input."
  @type parse_error ::
          :empty_input
          | :unknown_command
          | {:missing_argument, atom()}
          | {:unknown_subcommand, String.t()}

  # ── Public API ───────────────────────────────────────────────────────

  @doc """
  Parses a single slash-command line into a structured command.

  Pure: does NOT call services, hit the database, or perform IO.
  Whitespace-trims the leading slash and the trailing newline.
  Multi-word arguments after the last keyword are joined back into a
  single string (so `/plan revise abc add tests` parses as
  `{:plan, :revise, "abc", "add tests"}`).

  Returns `{:ok, command}` on success, `{:error, reason}` otherwise.
  """
  @spec parse(String.t()) :: {:ok, command()} | {:error, parse_error()}
  def parse(input) when is_binary(input) do
    trimmed = String.trim(input)

    cond do
      trimmed == "" ->
        {:error, :empty_input}

      not String.starts_with?(trimmed, "/") ->
        {:error, :unknown_command}

      true ->
        trimmed
        |> String.trim_leading("/")
        |> split_head()
        |> parse_head()
    end
  end

  @doc """
  Dispatches a parsed command to the appropriate service.

  See module doc for the supported `opts`. Returns `{:ok, payload}` or
  `{:error, payload}` per `t:result/0`.
  """
  @spec dispatch(command(), keyword()) :: result()
  def dispatch(command, opts \\ [])

  def dispatch({:nano, mode, task}, opts) do
    Nano.run(mode, task, opts)
  end

  def dispatch({:plans}, opts) do
    Plan.list(opts)
  end

  def dispatch({:plan, :show, id}, opts) do
    Plan.show(id, opts)
  end

  def dispatch({:plan, :approve, id}, opts) do
    Plan.approve(id, opts)
  end

  def dispatch({:plan, :run, id}, opts) do
    Plan.run(id, opts)
  end

  def dispatch({:plan, :revise, id, request}, opts) do
    Plan.revise(id, request, opts)
  end

  def dispatch({:plan, :reject, id, reason}, opts) do
    Plan.reject(id, reason, opts)
  end

  @doc """
  Convenience: parse and dispatch in one shot.

  Returns the same shape as `dispatch/2`, plus a `{:error, %{code:
  :parse_error, ...}}` envelope if parsing fails. This is the entry
  point a REPL or chat surface would call.
  """
  @spec run(String.t(), keyword()) :: result()
  def run(input, opts \\ []) when is_binary(input) do
    case parse(input) do
      {:ok, command} -> dispatch(command, opts)
      {:error, reason} -> {:error, parse_error_payload(reason, input)}
    end
  end

  # ── Parsing internals ────────────────────────────────────────────────

  # Splits "<head> <rest>" into `{head, rest}` where `rest` may be empty.
  # `head` is the first whitespace-delimited token; `rest` is everything
  # after the first run of whitespace, untouched.
  @spec split_head(String.t()) :: {String.t(), String.t()}
  defp split_head(body) do
    case String.split(body, ~r/\s+/, parts: 2) do
      [head] -> {head, ""}
      [head, rest] -> {head, rest}
    end
  end

  # /nano <task>
  defp parse_head({"nano", rest}), do: parse_nano(:nano, rest)
  # /nano-deep <task>
  defp parse_head({"nano-deep", rest}), do: parse_nano(:nano_deep, rest)
  # /nano-fix <problem>
  defp parse_head({"nano-fix", rest}), do: parse_nano(:nano_fix, rest)
  # /plans
  defp parse_head({"plans", rest}) do
    if String.trim(rest) == "" do
      {:ok, {:plans}}
    else
      # `/plans` takes no arguments; treat anything after as a usage error.
      {:error, {:unknown_subcommand, String.trim(rest)}}
    end
  end

  # /plan <subcommand> ...
  defp parse_head({"plan", rest}), do: parse_plan(rest)
  defp parse_head({other, _rest}), do: {:error, {:unknown_subcommand, other}}

  defp parse_nano(_mode, ""), do: {:error, {:missing_argument, :task}}

  defp parse_nano(mode, raw_task) do
    case String.trim(raw_task) do
      "" -> {:error, {:missing_argument, :task}}
      task -> {:ok, {:nano, mode, task}}
    end
  end

  defp parse_plan(rest) do
    case split_head(String.trim(rest)) do
      {"", _} -> {:error, {:missing_argument, :subcommand}}
      {sub, args} -> parse_plan_sub(sub, args)
    end
  end

  defp parse_plan_sub("show", args), do: parse_plan_with_id(:show, args)
  defp parse_plan_sub("approve", args), do: parse_plan_with_id(:approve, args)
  defp parse_plan_sub("run", args), do: parse_plan_with_id(:run, args)

  defp parse_plan_sub("reject", args) do
    case split_head(String.trim(args)) do
      {"", _} ->
        {:error, {:missing_argument, :id}}

      {id, rest} ->
        reason =
          case String.trim(rest) do
            "" -> nil
            text -> text
          end

        {:ok, {:plan, :reject, id, reason}}
    end
  end

  defp parse_plan_sub("revise", args) do
    case split_head(String.trim(args)) do
      {"", _} ->
        {:error, {:missing_argument, :id}}

      {_id, ""} ->
        {:error, {:missing_argument, :request}}

      {id, rest} ->
        case String.trim(rest) do
          "" -> {:error, {:missing_argument, :request}}
          request -> {:ok, {:plan, :revise, id, request}}
        end
    end
  end

  defp parse_plan_sub(other, _args), do: {:error, {:unknown_subcommand, "plan " <> other}}

  defp parse_plan_with_id(action, args) do
    case String.trim(args) do
      "" ->
        {:error, {:missing_argument, :id}}

      id_and_extra ->
        # Take only the first whitespace-delimited token as the id.
        # Trailing tokens are ignored to keep show/approve/run forgiving.
        {id, _rest} = split_head(id_and_extra)
        {:ok, {:plan, action, id}}
    end
  end

  # ── Error formatting ─────────────────────────────────────────────────

  @spec parse_error_payload(parse_error(), String.t()) :: map()
  defp parse_error_payload(:empty_input, _input) do
    %{
      code: :parse_error,
      reason: :empty_input,
      message: "empty command (expected a slash-command like `/nano <task>`)"
    }
  end

  defp parse_error_payload(:unknown_command, input) do
    %{
      code: :parse_error,
      reason: :unknown_command,
      message:
        "unrecognised input #{inspect(input)} — commands must start with `/` (try `/plans`)"
    }
  end

  defp parse_error_payload({:missing_argument, arg}, _input) do
    %{
      code: :parse_error,
      reason: {:missing_argument, arg},
      message: "missing required argument: #{arg}"
    }
  end

  defp parse_error_payload({:unknown_subcommand, sub}, _input) do
    %{
      code: :parse_error,
      reason: {:unknown_subcommand, sub},
      message: "unknown subcommand: #{inspect(sub)}"
    }
  end
end
