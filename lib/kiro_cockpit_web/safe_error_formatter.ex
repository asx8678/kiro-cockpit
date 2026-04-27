defmodule KiroCockpitWeb.SafeErrorFormatter do
  @moduledoc """
  Safe formatting helpers for error/exit messages that appear in LiveView
  flash messages, logs, and PubSub broadcasts.

  Per §22.6/§25.6: error messages must never leak PII, tokens, secrets,
  or raw `inspect` output into flash/log/broadcast paths. This module is
  the **single source of truth** for safe error formatting in the web layer.

  ## Trust Boundary

  `redact_secrets/1` applies conservative regex-based redaction for common
  secret patterns (API keys, tokens, passwords, bearer strings). This is a
  **best-effort heuristic**, not a guarantee. It will NOT catch:

    - Arbitrarily formatted secrets (e.g., base64 blobs without a known prefix)
    - Secrets embedded in deeply nested structures (those are handled by
      `format_error/1` which never inspects maps/tuples/lists)
    - Novel secret formats not covered by the regex patterns below

  If you need guaranteed redaction for a specific data shape, apply
  `redact_secrets/1` explicitly *and* ensure the upstream code never
  passes raw secrets into formatting paths.

  ## Patterns Redacted

    - `token=<value>`, `password=<value>`, `api_key=<value>`,
      `secret=<value>`, `api-key=<value>` (common key=value patterns)
    - `Bearer <value>` (HTTP Authorization headers)
    - `sk-<20+chars>` (OpenAI-style API keys)
    - `ghp_<36chars>` (GitHub personal access tokens)
    - `AKIA<16chars>` (AWS access key IDs)

  ## Dual-Write Compliance (§6.3)

  This module is *read-only* — it formats data for display. It does NOT
  write state or emit events, so the dual-write discipline does not apply
  here directly. However, callers (e.g., LiveView `handle_async`) must
  ensure any state+event writes happen inside `Ecto.Multi`.
  """

  @max_safe_error_length 200

  # ── Public API ────────────────────────────────────────────────────────

  @doc """
  Format an error reason into a safe, human-readable string.

  Handles atoms, binaries, exceptions, Ecto changesets, and lists.
  For unknown types (maps, tuples, pids, functions, etc.), returns a
  generic type name — **never** inspects the value body.
  """
  @spec format_error(term()) :: String.t()
  def format_error(%Ecto.Changeset{} = changeset) do
    changeset.errors
    |> Enum.map_join(", ", fn {field, {msg, _}} -> "#{field}: #{msg}" end)
  end

  def format_error(reason) when is_atom(reason), do: to_string(reason)

  def format_error(reason) when is_binary(reason) do
    safe_truncate(reason, @max_safe_error_length)
  end

  # Exception messages may contain connection strings, stack traces, or
  # other PII. Truncate and never inspect the raw struct (§22.6/§25.6).
  def format_error(%{__exception__: true} = reason) do
    safe_truncate(Exception.message(reason), @max_safe_error_length)
  end

  # Never inspect arbitrary lists — they may contain secrets, tokens, or
  # large payloads. Summarize by count only (§22.6/§25.6).
  def format_error(reason) when is_list(reason) do
    "list of #{length(reason)} item(s)"
  end

  def format_error(reason), do: "unexpected error: #{type_name(reason)}"

  @doc """
  Format an exit reason into a safe, human-readable string.

  Shutdown reasons (`{:shutdown, _}`) are intentionally NOT exposed —
  the reason payload may contain PII or secrets (§22.6/§25.6).
  """
  @spec format_exit(term()) :: String.t()
  def format_exit(:normal), do: "normal exit"
  def format_exit(:shutdown), do: "shutdown"

  # Never include raw shutdown reason text — it may contain PII/secrets (§22.6/§25.6).
  def format_exit({:shutdown, _reason}), do: "shutdown"

  def format_exit(reason) when is_atom(reason), do: to_string(reason)
  def format_exit(_reason), do: "unexpected exit"

  @doc """
  Returns a safe type name for an unknown value — never inspects
  the value body, only its type, to avoid leaking PII/secrets (§22.6/§25.6).
  """
  @spec type_name(term()) :: String.t()
  def type_name(value) when is_map(value), do: "map"
  def type_name(value) when is_tuple(value), do: "tuple"
  def type_name(value) when is_pid(value), do: "pid"
  def type_name(value) when is_function(value), do: "function"
  def type_name(value) when is_port(value), do: "port"
  def type_name(value) when is_reference(value), do: "reference"
  def type_name(value) when is_float(value), do: "float"
  def type_name(value) when is_integer(value), do: "integer"
  def type_name(value) when is_bitstring(value), do: "bitstring"
  def type_name(_value), do: "unknown"

  @doc """
  Truncates a string to `max_length`, appending "..." if truncated,
  then applies conservative secret redaction.

  Order matters: truncate first (secrets past the limit are simply dropped),
  then redact on the visible portion to catch any that land in the first
  `max_length` characters (§22.6/§25.6).
  """
  @spec safe_truncate(String.t(), non_neg_integer()) :: String.t()
  def safe_truncate(text, max_length) when is_binary(text) do
    text
    |> truncate_raw(max_length)
    |> redact_secrets()
  end

  @doc """
  Conservative regex-based redaction for common secret patterns.

  This is a **best-effort heuristic**. See the module doc for the trust
  boundary and the list of patterns covered. Unknown secret formats will
  NOT be caught — if you have specific redaction needs, apply additional
  filtering before calling this function.

  Redacted values are replaced with `[REDACTED]`.
  """
  @spec redact_secrets(String.t()) :: String.t()
  def redact_secrets(text) when is_binary(text) do
    text
    |> redact_key_value_patterns()
    |> redact_bearer_tokens()
    |> redact_known_key_prefixes()
  end

  # ── Private helpers ──────────────────────────────────────────────────

  defp truncate_raw(text, max_length) do
    if String.length(text) > max_length do
      String.slice(text, 0, max_length) <> "..."
    else
      text
    end
  end

  # key=value patterns: token=..., password=..., api_key=..., secret=..., api-key=...
  # Matches the key (case-insensitive), the delimiter (= or :), and the value
  # up to whitespace, end-of-string, or a quote character.
  defp redact_key_value_patterns(text) do
    # credo:disable-for-next-line Credo.Check.Readability.LargeRegex
    Regex.replace(
      ~r/(token|password|api[_-]?key|secret|passwd|passphrase|private[_-]?key|access[_-]?key)\s*[=:]\s*[\S]+/i,
      text,
      "\\1=[REDACTED]"
    )
  end

  # Bearer tokens in HTTP Authorization headers
  defp redact_bearer_tokens(text) do
    Regex.replace(~r/[Bb]earer\s+\S+/, text, "Bearer [REDACTED]")
  end

  # Known API key prefixes:
  #   sk-        — OpenAI / similar API keys (20+ chars after prefix)
  #   ghp_       — GitHub personal access tokens (36 chars)
  #   gho_       — GitHub OAuth access tokens
  #   ghu_       — GitHub user-to-server tokens
  #   ghs_       — GitHub server-to-server tokens
  #   ghr_       — GitHub refresh tokens
  #   AKIA       — AWS access key IDs (16 chars after prefix)
  #   eyJ         — JWT-like base64 (heuristic: starts with eyJ)
  defp redact_known_key_prefixes(text) do
    text
    |> redact_prefix(~r/sk-[a-zA-Z0-9]{20,}/, "sk-[REDACTED]")
    |> redact_prefix(~r/gh[porsu]_[a-zA-Z0-9]{36,}/, "gh?_[REDACTED]")
    |> redact_prefix(~r/AKIA[A-Z0-9]{16}/, "AKIA[REDACTED]")
    |> redact_prefix(~r/eyJ[a-zA-Z0-9_-]{20,}/, "eyJ[REDACTED]")
  end

  defp redact_prefix(text, regex, replacement) do
    Regex.replace(regex, text, replacement)
  end
end
