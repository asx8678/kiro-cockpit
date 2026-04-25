defmodule KiroCockpit.Acp.LineCodecTest do
  use ExUnit.Case, async: true

  alias KiroCockpit.Acp.LineCodec

  describe "encode!/1" do
    test "produces a single line ending in \\n" do
      line = LineCodec.encode!(%{"hello" => "world"})
      assert is_binary(line)
      assert String.ends_with?(line, "\n")
      refute String.contains?(binary_part(line, 0, byte_size(line) - 1), "\n")
    end

    test "string-internal newlines are escaped, not raw" do
      line = LineCodec.encode!(%{"text" => "a\nb"})
      assert line == ~s({"text":"a\\nb"}) <> "\n"
    end

    test "round-trips through decode/1" do
      term = %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping", "params" => %{}}
      line = LineCodec.encode!(term)
      assert {:ok, ^term} = LineCodec.decode(line)
    end
  end

  describe "encode/1" do
    test "returns {:ok, line} for valid term" do
      assert {:ok, line} = LineCodec.encode([1, 2, 3])
      assert line == "[1,2,3]\n"
    end

    test "returns {:error, _} when JSON encoding fails" do
      # Tuples are not JSON-encodable.
      assert {:error, _} = LineCodec.encode({:not, :json})
    end
  end

  describe "decode/1" do
    test "trims a trailing LF" do
      assert {:ok, %{"a" => 1}} = LineCodec.decode(~s({"a":1}\n))
    end

    test "trims a trailing CRLF" do
      assert {:ok, %{"a" => 1}} = LineCodec.decode(~s({"a":1}\r\n))
    end

    test "decodes a line with no trailing newline" do
      assert {:ok, %{"a" => 1}} = LineCodec.decode(~s({"a":1}))
    end

    test "rejects a fully-empty input" do
      assert {:error, :blank} = LineCodec.decode("")
    end

    test "rejects a whitespace-only line" do
      assert {:error, :blank} = LineCodec.decode("\n")
      assert {:error, :blank} = LineCodec.decode("\r\n")
    end

    test "rejects a line with an embedded raw newline" do
      assert {:error, :embedded_newline} = LineCodec.decode(~s({"a":1}\n{"b":2}\n))
    end

    test "rejects invalid JSON" do
      assert {:error, {:invalid_json, _}} = LineCodec.decode("not json\n")
    end

    test "rejects non-binary input" do
      assert {:error, {:not_binary, _}} = LineCodec.decode(:not_a_binary)
    end

    test "decodes JSON primitives, not just objects" do
      assert {:ok, 42} = LineCodec.decode("42\n")
      assert {:ok, "hello"} = LineCodec.decode(~s("hello"\n))
      assert {:ok, [1, 2]} = LineCodec.decode("[1,2]\n")
      assert {:ok, true} = LineCodec.decode("true\n")
      assert {:ok, nil} = LineCodec.decode("null\n")
    end
  end
end
