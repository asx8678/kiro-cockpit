defmodule KiroCockpit.KiroSession.CallbacksTest do
  @moduledoc """
  Unit tests for `KiroCockpit.KiroSession.Callbacks`.

  Tests fs/* parameter validation, file I/O, and line slicing.
  Terminal/* method tests live in `TerminalManagerTest` since
  they require a running TerminalManager GenServer.
  """

  use ExUnit.Case, async: true

  alias KiroCockpit.KiroSession.Callbacks

  # -- known_method? ---------------------------------------------------------

  describe "known_method?/1" do
    test "recognizes all known callback methods" do
      assert Callbacks.known_method?("fs/read_text_file")
      assert Callbacks.known_method?("fs/write_text_file")
      assert Callbacks.known_method?("terminal/create")
      assert Callbacks.known_method?("terminal/output")
      assert Callbacks.known_method?("terminal/wait_for_exit")
      assert Callbacks.known_method?("terminal/kill")
      assert Callbacks.known_method?("terminal/release")
    end

    test "rejects unknown methods" do
      refute Callbacks.known_method?("session/prompt")
      refute Callbacks.known_method?("initialize")
      refute Callbacks.known_method?("_kiro.dev/commands/execute")
      refute Callbacks.known_method?("fs/unknown")
    end
  end

  # -- fs/read_text_file -----------------------------------------------------

  describe "fs/read_text_file" do
    setup do
      dir = Path.join(System.tmp_dir!(), "kiro-callbacks-test-#{:erlang.unique_integer()}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    test "reads an existing file", %{dir: dir} do
      path = Path.join(dir, "hello.txt")
      File.write!(path, "hello world")

      assert {:ok, %{"content" => "hello world"}} =
               Callbacks.handle_request("fs/read_text_file", %{"path" => path}, nil)
    end

    test "reads multi-line file", %{dir: dir} do
      path = Path.join(dir, "multi.txt")
      File.write!(path, "line1\nline2\nline3")

      assert {:ok, %{"content" => "line1\nline2\nline3"}} =
               Callbacks.handle_request("fs/read_text_file", %{"path" => path}, nil)
    end

    test "slices with line (1-based) and limit", %{dir: dir} do
      path = Path.join(dir, "lines.txt")
      File.write!(path, "line1\nline2\nline3\nline4\nline5")

      # Line 2, limit 2 → lines 2-3
      assert {:ok, %{"content" => "line2\nline3"}} =
               Callbacks.handle_request(
                 "fs/read_text_file",
                 %{
                   "path" => path,
                   "line" => 2,
                   "limit" => 2
                 },
                 nil
               )
    end

    test "slices with line only (no limit) returns to end", %{dir: dir} do
      path = Path.join(dir, "lines2.txt")
      File.write!(path, "line1\nline2\nline3\nline4")

      # Line 3, no limit → lines 3 to end
      assert {:ok, %{"content" => "line3\nline4"}} =
               Callbacks.handle_request(
                 "fs/read_text_file",
                 %{
                   "path" => path,
                   "line" => 3
                 },
                 nil
               )
    end

    test "slices with limit only starts from line 1", %{dir: dir} do
      path = Path.join(dir, "lines3.txt")
      File.write!(path, "line1\nline2\nline3")

      # No line, limit 2 → lines 1-2
      assert {:ok, %{"content" => "line1\nline2"}} =
               Callbacks.handle_request(
                 "fs/read_text_file",
                 %{
                   "path" => path,
                   "limit" => 2
                 },
                 nil
               )
    end

    test "line 1 is the first line (1-based)", %{dir: dir} do
      path = Path.join(dir, "first.txt")
      File.write!(path, "alpha\nbeta\ngamma")

      assert {:ok, %{"content" => "alpha"}} =
               Callbacks.handle_request(
                 "fs/read_text_file",
                 %{
                   "path" => path,
                   "line" => 1,
                   "limit" => 1
                 },
                 nil
               )
    end

    test "rejects missing path" do
      assert {:error, -32_602, message, nil} =
               Callbacks.handle_request("fs/read_text_file", %{}, nil)

      assert message =~ "Missing required parameter: path"
    end

    test "rejects non-absolute path" do
      assert {:error, -32_602, message, nil} =
               Callbacks.handle_request("fs/read_text_file", %{"path" => "relative/path"}, nil)

      assert message =~ "Path must be absolute"
    end

    test "rejects empty path" do
      assert {:error, -32_602, _message, nil} =
               Callbacks.handle_request("fs/read_text_file", %{"path" => ""}, nil)
    end

    test "returns error for missing file" do
      assert {:error, -32_000, message, nil} =
               Callbacks.handle_request(
                 "fs/read_text_file",
                 %{"path" => "/tmp/nonexistent_file_kiro_test_12345.txt"},
                 nil
               )

      assert message =~ "File not found"
    end

    test "handles binary-ish files via latin-1 fallback", %{dir: dir} do
      path = Path.join(dir, "binary.bin")

      # Write bytes that are not valid UTF-8
      File.write!(path, <<0, 255, 128, 65>>)

      assert {:ok, %{"content" => _content}} =
               Callbacks.handle_request("fs/read_text_file", %{"path" => path}, nil)
    end
  end

  # -- fs/write_text_file ----------------------------------------------------

  describe "fs/write_text_file" do
    setup do
      dir = Path.join(System.tmp_dir!(), "kiro-callbacks-write-#{:erlang.unique_integer()}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    test "writes to a new file", %{dir: dir} do
      path = Path.join(dir, "new_file.txt")

      assert {:ok, nil} =
               Callbacks.handle_request(
                 "fs/write_text_file",
                 %{"path" => path, "content" => "hello"},
                 nil
               )

      assert File.read!(path) == "hello"
    end

    test "overwrites an existing file", %{dir: dir} do
      path = Path.join(dir, "overwrite.txt")
      File.write!(path, "old content")

      assert {:ok, nil} =
               Callbacks.handle_request(
                 "fs/write_text_file",
                 %{"path" => path, "content" => "new content"},
                 nil
               )

      assert File.read!(path) == "new content"
    end

    test "creates parent directories if they don't exist", %{dir: dir} do
      path = Path.join(dir, "nested/deep/file.txt")

      assert {:ok, nil} =
               Callbacks.handle_request(
                 "fs/write_text_file",
                 %{"path" => path, "content" => "nested"},
                 nil
               )

      assert File.read!(path) == "nested"
    end

    test "rejects missing path" do
      assert {:error, -32_602, message, nil} =
               Callbacks.handle_request("fs/write_text_file", %{"content" => "x"}, nil)

      assert message =~ "Missing required parameter: path"
    end

    test "rejects non-absolute path" do
      assert {:error, -32_602, message, nil} =
               Callbacks.handle_request(
                 "fs/write_text_file",
                 %{"path" => "relative.txt", "content" => "x"},
                 nil
               )

      assert message =~ "Path must be absolute"
    end

    test "rejects missing content" do
      assert {:error, -32_602, message, nil} =
               Callbacks.handle_request(
                 "fs/write_text_file",
                 %{"path" => "/tmp/x.txt"},
                 nil
               )

      assert message =~ "Missing required parameter: content"
    end
  end

  # -- Terminal method validation (parameter checks) -------------------------

  describe "terminal/create validation" do
    test "rejects missing command" do
      assert {:error, -32_602, message, nil} =
               Callbacks.handle_request("terminal/create", %{}, nil)

      assert message =~ "command"
    end

    test "rejects nil terminal_manager" do
      assert {:error, -32_000, message, nil} =
               Callbacks.handle_request("terminal/create", %{"command" => "echo"}, nil)

      assert message =~ "auto_callbacks disabled"
    end
  end

  describe "terminal/output validation" do
    test "rejects missing terminalId" do
      assert {:error, -32_602, message, nil} =
               Callbacks.handle_request("terminal/output", %{}, nil)

      assert message =~ "terminalId"
    end

    test "rejects empty terminalId" do
      assert {:error, -32_602, message, nil} =
               Callbacks.handle_request("terminal/output", %{"terminalId" => ""}, nil)

      assert message =~ "terminalId"
    end
  end

  describe "terminal/kill validation" do
    test "rejects missing terminalId" do
      assert {:error, -32_602, _message, nil} =
               Callbacks.handle_request("terminal/kill", %{}, nil)
    end
  end

  describe "terminal/release validation" do
    test "rejects missing terminalId" do
      assert {:error, -32_602, _message, nil} =
               Callbacks.handle_request("terminal/release", %{}, nil)
    end
  end
end
