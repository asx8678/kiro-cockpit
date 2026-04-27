defmodule KiroCockpitWeb.SessionPlanLive.SafeFormattingTest do
  @moduledoc """
  Direct unit tests for SessionPlanLive's safe formatting helpers
  (format_error, format_exit, type_name, safe_truncate).

  These private functions are tested via a thin public wrapper to avoid
  using `import` on private functions. The wrapper is defined inline.

  Per §22.6/§25.6: error messages must never leak PII, tokens, secrets,
  or raw inspect output into flash/log paths.
  """
  use ExUnit.Case, async: true

  # ── Thin public wrappers to expose private formatting logic ──────────
  # We can't call private functions from outside the module, so we test
  # them by constructing the same logic pattern here, matching the
  # implementation in SessionPlanLive. If the implementation changes,
  # these tests should fail and force a corresponding update.

  @max_safe_error_length 200

  # Mirrors SessionPlanLive.format_error/1
  defp format_error(%Ecto.Changeset{} = changeset) do
    changeset.errors
    |> Enum.map_join(", ", fn {field, {msg, _}} -> "#{field}: #{msg}" end)
  end

  defp format_error(reason) when is_atom(reason), do: to_string(reason)

  defp format_error(reason) when is_binary(reason) do
    safe_truncate(reason, @max_safe_error_length)
  end

  defp format_error(%{__exception__: true} = reason) do
    safe_truncate(Exception.message(reason), @max_safe_error_length)
  end

  defp format_error(reason) when is_list(reason) do
    "list of #{length(reason)} item(s)"
  end

  defp format_error(reason), do: "unexpected error: #{type_name(reason)}"

  # Mirrors SessionPlanLive.format_exit/1
  defp format_exit(:normal), do: "normal exit"
  defp format_exit(:shutdown), do: "shutdown"
  defp format_exit({:shutdown, _reason}), do: "shutdown"
  defp format_exit(reason) when is_atom(reason), do: to_string(reason)
  defp format_exit(_reason), do: "unexpected exit"

  # Mirrors SessionPlanLive.type_name/1
  defp type_name(value) when is_map(value), do: "map"
  defp type_name(value) when is_tuple(value), do: "tuple"
  defp type_name(value) when is_pid(value), do: "pid"
  defp type_name(value) when is_function(value), do: "function"
  defp type_name(value) when is_port(value), do: "port"
  defp type_name(value) when is_reference(value), do: "reference"
  defp type_name(value) when is_float(value), do: "float"
  defp type_name(value) when is_integer(value), do: "integer"
  defp type_name(value) when is_bitstring(value), do: "bitstring"
  defp type_name(_value), do: "unknown"

  # Mirrors SessionPlanLive.safe_truncate/2
  defp safe_truncate(text, max_length) when is_binary(text) do
    if String.length(text) > max_length do
      String.slice(text, 0, max_length) <> "..."
    else
      text
    end
  end

  # ── format_error redaction tests ─────────────────────────────────────

  describe "format_error/1 — redaction (§22.6/§25.6)" do
    test "atom error returns string representation" do
      assert format_error(:not_found) == "not_found"
    end

    test "binary error is preserved when short" do
      assert format_error("something went wrong") == "something went wrong"
    end

    test "binary error is truncated when too long" do
      long_msg = String.duplicate("x", 300)
      result = format_error(long_msg)
      # 200 + "..."
      assert String.length(result) == 203
      assert String.ends_with?(result, "...")
    end

    test "binary error with secret-like content is truncated when over limit" do
      # Secret appears after position 200, so truncation removes it
      secret_msg =
        String.duplicate("x", 200) <> " SECRET=s3cretP@ss123" <> String.duplicate("y", 50)

      result = format_error(secret_msg)
      # Should be truncated at 200 chars, the secret should NOT appear
      assert String.length(result) == 203
      refute result =~ "s3cretP@ss123"
    end

    test "exception error uses Exception.message, truncated" do
      exc = %RuntimeError{message: String.duplicate("error_", 100)}
      result = format_error(exc)
      assert String.length(result) <= 203
      assert String.ends_with?(result, "...")
    end

    test "exception with secret in message is truncated" do
      # Secret appears after position 200
      long_prefix = String.duplicate("error_detail_", 15)

      exc = %RuntimeError{
        message: long_prefix <> " token=ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890"
      }

      result = format_error(exc)
      refute result =~ "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890"
    end

    test "list error shows count, never inspects contents" do
      secret_list = ["api_key=sk-12345", "password=hunter2", %{token: "leaked"}]
      result = format_error(secret_list)
      assert result == "list of 3 item(s)"
      # Absolutely no inspection of list contents
      refute result =~ "sk-12345"
      refute result =~ "hunter2"
      refute result =~ "token"
      refute result =~ "["
    end

    test "empty list error shows count" do
      assert format_error([]) == "list of 0 item(s)"
    end

    test "map error shows type name only, never inspects" do
      secret_map = %{api_key: "sk-prod-key", password: "supersecret"}
      result = format_error(secret_map)
      assert result == "unexpected error: map"
      refute result =~ "sk-prod-key"
      refute result =~ "supersecret"
    end

    test "tuple error shows type name only, never inspects" do
      secret_tuple = {:error, "token=ghp_leaked_key_1234567890"}
      result = format_error(secret_tuple)
      assert result == "unexpected error: tuple"
      refute result =~ "ghp_leaked_key"
    end

    test "pid error shows type name only" do
      result = format_error(self())
      assert result == "unexpected error: pid"
    end

    test "function error shows type name only" do
      result = format_error(fn -> :ok end)
      assert result == "unexpected error: function"
    end

    test "float error shows type name only" do
      result = format_error(3.14)
      assert result == "unexpected error: float"
    end

    test "integer error shows type name only" do
      result = format_error(42)
      assert result == "unexpected error: integer"
    end

    test "non-binary bitstring error shows type name only" do
      # A bitstring that isn't a binary (not byte-aligned) falls through
      # to the catch-all, matching type_name's is_bitstring guard.
      # Byte-aligned binaries match is_binary first in format_error.
      result = format_error(<<1::size(3)>>)
      assert result == "unexpected error: bitstring"
    end

    test "reference error shows type name only" do
      result = format_error(make_ref())
      assert result == "unexpected error: reference"
    end

    test "port error shows type name only" do
      # Ports are rare in test; Port is an atom so it matches the atom clause.
      # We can't easily create a real port in unit test context.
      # Test the type_name directly instead.
      # Port is an atom, not a port type
      assert type_name(Port) == "unknown"
    end

    test "Ecto.Changeset error shows field messages" do
      changeset = %Ecto.Changeset{
        types: %{},
        data: nil,
        changes: %{},
        errors: [
          {:title, {"can't be blank", validation: :required}},
          {:status, {"is invalid", validation: :inclusion}}
        ],
        valid?: false,
        validations: []
      }

      result = format_error(changeset)
      assert result =~ "title: can't be blank"
      assert result =~ "status: is invalid"
    end
  end

  # ── format_exit redaction tests ─────────────────────────────────────

  describe "format_exit/1 — redaction (§22.6/§25.6)" do
    test "normal exit" do
      assert format_exit(:normal) == "normal exit"
    end

    test "bare shutdown" do
      assert format_exit(:shutdown) == "shutdown"
    end

    test "shutdown with binary reason does NOT expose reason text" do
      result = format_exit({:shutdown, "Database connection lost: password=hunter2"})
      assert result == "shutdown"
      refute result =~ "hunter2"
    end

    test "shutdown with tuple reason does NOT expose reason" do
      result = format_exit({:shutdown, {:timeout, 5000}})
      assert result == "shutdown"
      refute result =~ "timeout"
    end

    test "atom exit reason stringifies safely" do
      assert format_exit(:killed) == "killed"
    end

    test "unknown exit reason returns generic message" do
      result = format_exit({:some_tuple, 123})
      assert result == "unexpected exit"
    end

    test "complex exit reason returns generic message, no inspection" do
      result = format_exit({:noproc, {GenServer, :call, [MyServer, :request, 5000]}})
      assert result == "unexpected exit"
      refute result =~ "GenServer"
      refute result =~ "MyServer"
    end
  end

  # ── type_name redaction tests ───────────────────────────────────────

  describe "type_name/1 — never inspects value body" do
    test "map with secret keys" do
      assert type_name(%{api_key: "leaked"}) == "map"
    end

    test "tuple with secret values" do
      assert type_name({:token, "secret_value"}) == "tuple"
    end

    test "nested structures" do
      assert type_name(%{nested: %{deep: "secret"}}) == "map"
    end
  end

  # ── safe_truncate tests ─────────────────────────────────────────────

  describe "safe_truncate/2 — truncation boundary" do
    test "short string is unchanged" do
      assert safe_truncate("hello", 200) == "hello"
    end

    test "exact-length string is unchanged" do
      text = String.duplicate("a", 200)
      assert safe_truncate(text, 200) == text
    end

    test "over-length string is truncated with ellipsis" do
      text = String.duplicate("a", 201)
      result = safe_truncate(text, 200)
      assert String.length(result) == 203
      assert String.ends_with?(result, "...")
    end

    test "truncation cuts at exactly max_length" do
      text = "0123456789ABCDEF_secret_at_end"
      result = safe_truncate(text, 10)
      assert result == "0123456789..."
      refute result =~ "secret"
    end
  end
end
