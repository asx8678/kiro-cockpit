defmodule KiroCockpitWeb.SafeErrorFormatterTest do
  @moduledoc """
  Unit tests for KiroCockpitWeb.SafeErrorFormatter — the production module
  for safe error/exit formatting used by LiveView flash paths.

  Per §22.6/§25.6: error messages must never leak PII, tokens, secrets,
  or raw inspect output into flash/log/broadcast paths.
  """
  use ExUnit.Case, async: true

  alias KiroCockpitWeb.SafeErrorFormatter

  # ── format_error/1 ──────────────────────────────────────────────────

  describe "format_error/1 — redaction (§22.6/§25.6)" do
    test "atom error returns string representation" do
      assert SafeErrorFormatter.format_error(:not_found) == "not_found"
    end

    test "binary error is preserved when short" do
      assert SafeErrorFormatter.format_error("something went wrong") == "something went wrong"
    end

    test "binary error is truncated when too long" do
      long_msg = String.duplicate("x", 300)
      result = SafeErrorFormatter.format_error(long_msg)
      # 200 + "..."
      assert String.length(result) == 203
      assert String.ends_with?(result, "...")
    end

    test "binary error with secret-like content after position 200 is truncated away" do
      secret_msg =
        String.duplicate("x", 200) <> " SECRET=s3cretP@ss123" <> String.duplicate("y", 50)

      result = SafeErrorFormatter.format_error(secret_msg)
      # Should be truncated at 200 chars, the secret should NOT appear
      assert String.length(result) == 203
      refute result =~ "s3cretP@ss123"
    end

    test "binary error with secret-like content before position 200 is redacted" do
      msg = "Error: token=ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890xyz failed"

      result = SafeErrorFormatter.format_error(msg)
      # The token value should be redacted
      refute result =~ "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890xyz"
      assert result =~ "token=[REDACTED]"
    end

    test "exception error uses Exception.message, truncated" do
      exc = %RuntimeError{message: String.duplicate("error_", 100)}
      result = SafeErrorFormatter.format_error(exc)
      assert String.length(result) <= 203
      assert String.ends_with?(result, "...")
    end

    test "exception with secret in message is redacted" do
      long_prefix = String.duplicate("error_detail_", 15)

      exc = %RuntimeError{
        message: long_prefix <> " token=ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890"
      }

      result = SafeErrorFormatter.format_error(exc)
      refute result =~ "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890"
    end

    test "exception with password in message is redacted" do
      exc = %RuntimeError{message: "Connection failed: password=hunter2 host=db"}

      result = SafeErrorFormatter.format_error(exc)
      refute result =~ "hunter2"
      assert result =~ "password=[REDACTED]"
    end

    test "list error shows count, never inspects contents" do
      secret_list = ["api_key=sk-12345", "password=hunter2", %{token: "leaked"}]
      result = SafeErrorFormatter.format_error(secret_list)
      assert result == "list of 3 item(s)"
      # Absolutely no inspection of list contents
      refute result =~ "sk-12345"
      refute result =~ "hunter2"
      refute result =~ "token"
      refute result =~ "["
    end

    test "empty list error shows count" do
      assert SafeErrorFormatter.format_error([]) == "list of 0 item(s)"
    end

    test "map error shows type name only, never inspects" do
      secret_map = %{api_key: "sk-prod-key", password: "supersecret"}
      result = SafeErrorFormatter.format_error(secret_map)
      assert result == "unexpected error: map"
      refute result =~ "sk-prod-key"
      refute result =~ "supersecret"
    end

    test "tuple error shows type name only, never inspects" do
      secret_tuple = {:error, "token=ghp_leaked_key_1234567890"}
      result = SafeErrorFormatter.format_error(secret_tuple)
      assert result == "unexpected error: tuple"
      refute result =~ "ghp_leaked_key"
    end

    test "pid error shows type name only" do
      result = SafeErrorFormatter.format_error(self())
      assert result == "unexpected error: pid"
    end

    test "function error shows type name only" do
      result = SafeErrorFormatter.format_error(fn -> :ok end)
      assert result == "unexpected error: function"
    end

    test "float error shows type name only" do
      result = SafeErrorFormatter.format_error(3.14)
      assert result == "unexpected error: float"
    end

    test "integer error shows type name only" do
      result = SafeErrorFormatter.format_error(42)
      assert result == "unexpected error: integer"
    end

    test "non-binary bitstring error shows type name only" do
      result = SafeErrorFormatter.format_error(<<1::size(3)>>)
      assert result == "unexpected error: bitstring"
    end

    test "reference error shows type name only" do
      result = SafeErrorFormatter.format_error(make_ref())
      assert result == "unexpected error: reference"
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

      result = SafeErrorFormatter.format_error(changeset)
      assert result =~ "title: can't be blank"
      assert result =~ "status: is invalid"
    end
  end

  # ── format_exit/1 ────────────────────────────────────────────────────

  describe "format_exit/1 — redaction (§22.6/§25.6)" do
    test "normal exit" do
      assert SafeErrorFormatter.format_exit(:normal) == "normal exit"
    end

    test "bare shutdown" do
      assert SafeErrorFormatter.format_exit(:shutdown) == "shutdown"
    end

    test "shutdown with binary reason does NOT expose reason text" do
      result =
        SafeErrorFormatter.format_exit({:shutdown, "Database connection lost: password=hunter2"})

      assert result == "shutdown"
      refute result =~ "hunter2"
    end

    test "shutdown with tuple reason does NOT expose reason" do
      result = SafeErrorFormatter.format_exit({:shutdown, {:timeout, 5000}})
      assert result == "shutdown"
      refute result =~ "timeout"
    end

    test "atom exit reason stringifies safely" do
      assert SafeErrorFormatter.format_exit(:killed) == "killed"
    end

    test "unknown exit reason returns generic message" do
      result = SafeErrorFormatter.format_exit({:some_tuple, 123})
      assert result == "unexpected exit"
    end

    test "complex exit reason returns generic message, no inspection" do
      result =
        SafeErrorFormatter.format_exit({:noproc, {GenServer, :call, [MyServer, :request, 5000]}})

      assert result == "unexpected exit"
      refute result =~ "GenServer"
      refute result =~ "MyServer"
    end
  end

  # ── type_name/1 ──────────────────────────────────────────────────────

  describe "type_name/1 — never inspects value body" do
    test "map with secret keys" do
      assert SafeErrorFormatter.type_name(%{api_key: "leaked"}) == "map"
    end

    test "tuple with secret values" do
      assert SafeErrorFormatter.type_name({:token, "secret_value"}) == "tuple"
    end

    test "nested structures" do
      assert SafeErrorFormatter.type_name(%{nested: %{deep: "secret"}}) == "map"
    end
  end

  # ── safe_truncate/2 ─────────────────────────────────────────────────

  describe "safe_truncate/2 — truncation boundary" do
    test "short string is unchanged" do
      assert SafeErrorFormatter.safe_truncate("hello", 200) == "hello"
    end

    test "exact-length string is unchanged" do
      text = String.duplicate("a", 200)
      assert SafeErrorFormatter.safe_truncate(text, 200) == text
    end

    test "over-length string is truncated with ellipsis" do
      text = String.duplicate("a", 201)
      result = SafeErrorFormatter.safe_truncate(text, 200)
      assert String.length(result) == 203
      assert String.ends_with?(result, "...")
    end

    test "truncation cuts at exactly max_length" do
      text = "0123456789ABCDEF_secret_at_end"
      result = SafeErrorFormatter.safe_truncate(text, 10)
      assert result == "0123456789..."
      refute result =~ "secret"
    end
  end

  # ── safe_truncate/2 redaction integration ────────────────────────────

  describe "safe_truncate/2 — secret redaction" do
    test "token pattern in visible portion is redacted" do
      result = SafeErrorFormatter.safe_truncate("Error: token=abc123secret", 200)
      refute result =~ "abc123secret"
      assert result =~ "token=[REDACTED]"
    end

    test "password pattern in visible portion is redacted" do
      result = SafeErrorFormatter.safe_truncate("Auth failed: password=hunter2 for user", 200)
      refute result =~ "hunter2"
      assert result =~ "password=[REDACTED]"
    end

    test "api_key pattern in visible portion is redacted" do
      result = SafeErrorFormatter.safe_truncate("Config error: api_key=sk-prod-1234567890", 200)
      refute result =~ "sk-prod-1234567890"
      assert result =~ "api_key=[REDACTED]"
    end

    test "secret pattern in visible portion is redacted" do
      result = SafeErrorFormatter.safe_truncate("Failed: secret=mysecretvalue", 200)
      refute result =~ "mysecretvalue"
      assert result =~ "secret=[REDACTED]"
    end

    test "string without secrets passes through unchanged (when short)" do
      assert SafeErrorFormatter.safe_truncate("plain error message", 200) == "plain error message"
    end
  end

  # ── redact_secrets/1 ────────────────────────────────────────────────

  describe "redact_secrets/1 — pattern-based redaction (§22.6/§25.6)" do
    test "redacts token= pattern" do
      assert SafeErrorFormatter.redact_secrets("token=abc123") =~ "token=[REDACTED]"
      refute SafeErrorFormatter.redact_secrets("token=abc123") =~ "abc123"
    end

    test "redacts password= pattern" do
      assert SafeErrorFormatter.redact_secrets("password=hunter2") =~ "password=[REDACTED]"
      refute SafeErrorFormatter.redact_secrets("password=hunter2") =~ "hunter2"
    end

    test "redacts api_key= pattern" do
      assert SafeErrorFormatter.redact_secrets("api_key=sk-abc") =~ "api_key=[REDACTED]"
      refute SafeErrorFormatter.redact_secrets("api_key=sk-abc") =~ "sk-abc"
    end

    test "redacts api-key= pattern (hyphenated)" do
      assert SafeErrorFormatter.redact_secrets("api-key=sk-abc") =~ "api-key=[REDACTED]"
      refute SafeErrorFormatter.redact_secrets("api-key=sk-abc") =~ "sk-abc"
    end

    test "redacts secret= pattern" do
      assert SafeErrorFormatter.redact_secrets("secret=myvalue") =~ "secret=[REDACTED]"
      refute SafeErrorFormatter.redact_secrets("secret=myvalue") =~ "myvalue"
    end

    test "redacts Bearer token pattern" do
      result = SafeErrorFormatter.redact_secrets("Authorization: Bearer eyJhbGciOiJIUzI1NiJ9")
      assert result =~ "Bearer [REDACTED]"
      refute result =~ "eyJhbGciOiJIUzI1NiJ9"
    end

    test "redacts lowercase bearer token pattern" do
      result = SafeErrorFormatter.redact_secrets("auth: bearer tok_abc123def456")
      assert result =~ "Bearer [REDACTED]"
      refute result =~ "tok_abc123def456"
    end

    test "redacts OpenAI-style sk- prefix (20+ chars)" do
      result = SafeErrorFormatter.redact_secrets("key=sk-abcdefghijklmnopqrstuvwxyz1234567890")
      # The key=value pattern also catches this, but sk- prefix should too
      refute result =~ "sk-abcdefghijklmnopqrstuvwxyz1234567890"
    end

    test "redacts GitHub PAT ghp_ prefix (36+ chars)" do
      result =
        SafeErrorFormatter.redact_secrets("token=ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890")

      refute result =~ "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890"
    end

    test "redacts AWS AKIA prefix" do
      result = SafeErrorFormatter.redact_secrets("key=AKIAIOSFODNN7EXAMPLE")
      refute result =~ "AKIAIOSFODNN7EXAMPLE"
    end

    test "redacts JWT eyJ prefix" do
      result =
        SafeErrorFormatter.redact_secrets(
          "Authorization: eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.abc.def"
        )

      refute result =~ "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
    end

    test "preserves non-secret content" do
      assert SafeErrorFormatter.redact_secrets("hello world") == "hello world"
    end

    test "handles multiple secrets in one string" do
      result =
        SafeErrorFormatter.redact_secrets("password=hunter2 and token=abc123 in same string")

      refute result =~ "hunter2"
      refute result =~ "abc123"
      assert result =~ "password=[REDACTED]"
      assert result =~ "token=[REDACTED]"
    end

    test "case-insensitive key matching" do
      result = SafeErrorFormatter.redact_secrets("TOKEN=abc123 Password=xyz")
      refute result =~ "abc123"
      refute result =~ "xyz"
    end

    test "handles key: value pattern (colon delimiter)" do
      result = SafeErrorFormatter.redact_secrets("token: abc123")
      refute result =~ "abc123"
    end

    test "does not redact partial key matches in unrelated words" do
      # "secretion" contains "secret" but as a standalone word
      # the regex requires the = or : delimiter after the key
      result = SafeErrorFormatter.redact_secrets("secretion of hormones")
      # This should NOT be redacted because "secretion" != "secret="
      assert result == "secretion of hormones"
    end
  end
end
