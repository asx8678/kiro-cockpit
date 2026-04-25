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

  describe "params shape validation" do
    test "known callbacks reject nil params as invalid params" do
      assert {:error, -32_602, message, nil} =
               Callbacks.handle_request("fs/read_text_file", nil, nil)

      assert message =~ "expected a JSON object"
    end

    test "known callbacks reject list params as invalid params" do
      assert {:error, -32_602, message, nil} =
               Callbacks.handle_request("terminal/create", [], nil)

      assert message =~ "expected a JSON object"
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

    # -- line/limit validation --

    test "rejects non-integer line parameter" do
      assert {:error, -32_602, message, nil} =
               Callbacks.handle_request(
                 "fs/read_text_file",
                 %{"path" => "/tmp/any.txt", "line" => "two"},
                 nil
               )

      assert message =~ "'line' must be a positive integer"
    end

    test "rejects zero line parameter" do
      assert {:error, -32_602, message, nil} =
               Callbacks.handle_request(
                 "fs/read_text_file",
                 %{"path" => "/tmp/any.txt", "line" => 0},
                 nil
               )

      assert message =~ "'line' must be a positive integer"
    end

    test "rejects negative line parameter" do
      assert {:error, -32_602, message, nil} =
               Callbacks.handle_request(
                 "fs/read_text_file",
                 %{"path" => "/tmp/any.txt", "line" => -1},
                 nil
               )

      assert message =~ "'line' must be a positive integer"
    end

    test "rejects non-integer limit parameter" do
      assert {:error, -32_602, message, nil} =
               Callbacks.handle_request(
                 "fs/read_text_file",
                 %{"path" => "/tmp/any.txt", "limit" => 3.5},
                 nil
               )

      assert message =~ "'limit' must be a positive integer"
    end

    test "rejects zero limit parameter" do
      assert {:error, -32_602, message, nil} =
               Callbacks.handle_request(
                 "fs/read_text_file",
                 %{"path" => "/tmp/any.txt", "limit" => 0},
                 nil
               )

      assert message =~ "'limit' must be a positive integer"
    end

    test "rejects negative limit parameter" do
      assert {:error, -32_602, message, nil} =
               Callbacks.handle_request(
                 "fs/read_text_file",
                 %{"path" => "/tmp/any.txt", "limit" => -5},
                 nil
               )

      assert message =~ "'limit' must be a positive integer"
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

    test "rejects non-list args" do
      assert {:error, -32_602, message, nil} =
               Callbacks.handle_request(
                 "terminal/create",
                 %{"command" => "echo", "args" => "not-a-list"},
                 nil
               )

      assert message =~ "args"
    end

    test "rejects args with non-string elements" do
      assert {:error, -32_602, message, nil} =
               Callbacks.handle_request(
                 "terminal/create",
                 %{"command" => "echo", "args" => [1, 2]},
                 nil
               )

      assert message =~ "args"
    end

    test "rejects non-list env" do
      assert {:error, -32_602, message, nil} =
               Callbacks.handle_request(
                 "terminal/create",
                 %{"command" => "echo", "env" => "not-a-list"},
                 nil
               )

      assert message =~ "env"
    end

    test "rejects env with non-map elements" do
      assert {:error, -32_602, message, nil} =
               Callbacks.handle_request(
                 "terminal/create",
                 %{"command" => "echo", "env" => ["not-a-map"]},
                 nil
               )

      assert message =~ "env"
    end

    test "rejects env entry missing 'name' key" do
      assert {:error, -32_602, message, nil} =
               Callbacks.handle_request(
                 "terminal/create",
                 %{"command" => "echo", "env" => [%{"value" => "v"}]},
                 nil
               )

      assert message =~ "env"
    end

    test "rejects env entry with non-binary name" do
      assert {:error, -32_602, message, nil} =
               Callbacks.handle_request(
                 "terminal/create",
                 %{"command" => "echo", "env" => [%{"name" => 123, "value" => "v"}]},
                 nil
               )

      assert message =~ "env"
    end

    test "rejects non-positive-integer outputByteLimit" do
      assert {:error, -32_602, message, nil} =
               Callbacks.handle_request(
                 "terminal/create",
                 %{"command" => "echo", "outputByteLimit" => -1},
                 nil
               )

      assert message =~ "outputByteLimit"
    end

    test "rejects zero outputByteLimit" do
      assert {:error, -32_602, message, nil} =
               Callbacks.handle_request(
                 "terminal/create",
                 %{"command" => "echo", "outputByteLimit" => 0},
                 nil
               )

      assert message =~ "outputByteLimit"
    end

    test "rejects string outputByteLimit" do
      assert {:error, -32_602, message, nil} =
               Callbacks.handle_request(
                 "terminal/create",
                 %{"command" => "echo", "outputByteLimit" => "big"},
                 nil
               )

      assert message =~ "outputByteLimit"
    end

    test "rejects non-absolute cwd" do
      assert {:error, -32_602, message, nil} =
               Callbacks.handle_request(
                 "terminal/create",
                 %{"command" => "echo", "cwd" => "relative/path"},
                 nil
               )

      assert message =~ "cwd"
    end

    test "rejects empty string cwd" do
      assert {:error, -32_602, message, nil} =
               Callbacks.handle_request(
                 "terminal/create",
                 %{"command" => "echo", "cwd" => ""},
                 nil
               )

      assert message =~ "cwd"
    end

    test "rejects non-existent cwd directory" do
      assert {:error, -32_602, message, nil} =
               Callbacks.handle_request(
                 "terminal/create",
                 %{"command" => "echo", "cwd" => "/tmp/nonexistent_dir_kiro_12345"},
                 nil
               )

      assert message =~ "cwd" and message =~ "does not exist"
    end

    test "accepts valid cwd directory" do
      # This should pass validation but fail at terminal_manager nil
      # since we're passing nil. The cwd validation happens before the
      # terminal_manager check.
      tmp = System.tmp_dir!()

      # Will fail with terminal not available, but that's AFTER cwd validation passes
      assert {:error, -32_000, _, nil} =
               Callbacks.handle_request(
                 "terminal/create",
                 %{"command" => "echo", "cwd" => tmp},
                 nil
               )
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

  # -- Callback policy (MUST FIX 2) ------------------------------------------

  describe "mutating_method?/1" do
    test "identifies write and terminal methods as mutating" do
      assert Callbacks.mutating_method?("fs/write_text_file")
      assert Callbacks.mutating_method?("terminal/create")
      assert Callbacks.mutating_method?("terminal/output")
      assert Callbacks.mutating_method?("terminal/wait_for_exit")
      assert Callbacks.mutating_method?("terminal/kill")
      assert Callbacks.mutating_method?("terminal/release")
    end

    test "fs/read_text_file is not mutating" do
      refute Callbacks.mutating_method?("fs/read_text_file")
    end

    test "unknown methods are not mutating" do
      refute Callbacks.mutating_method?("session/prompt")
    end
  end

  describe "allowed_by_policy?/2" do
    test ":read_only allows fs/read_text_file" do
      assert Callbacks.allowed_by_policy?("fs/read_text_file", :read_only)
    end

    test ":read_only denies fs/write_text_file" do
      refute Callbacks.allowed_by_policy?("fs/write_text_file", :read_only)
    end

    test ":read_only denies terminal/*" do
      refute Callbacks.allowed_by_policy?("terminal/create", :read_only)
      refute Callbacks.allowed_by_policy?("terminal/output", :read_only)
      refute Callbacks.allowed_by_policy?("terminal/wait_for_exit", :read_only)
      refute Callbacks.allowed_by_policy?("terminal/kill", :read_only)
      refute Callbacks.allowed_by_policy?("terminal/release", :read_only)
    end

    test ":all allows everything" do
      assert Callbacks.allowed_by_policy?("fs/read_text_file", :all)
      assert Callbacks.allowed_by_policy?("fs/write_text_file", :all)
      assert Callbacks.allowed_by_policy?("terminal/create", :all)
    end

    test ":trusted allows everything" do
      assert Callbacks.allowed_by_policy?("fs/read_text_file", :trusted)
      assert Callbacks.allowed_by_policy?("fs/write_text_file", :trusted)
      assert Callbacks.allowed_by_policy?("terminal/create", :trusted)
    end
  end

  describe "capabilities_for_policy/1" do
    test ":read_only advertises read-only fs, no terminal" do
      caps = Callbacks.capabilities_for_policy(:read_only)
      assert caps["fs"]["readTextFile"] == true
      assert caps["fs"]["writeTextFile"] == false
      assert caps["terminal"] == false
    end

    test ":all advertises full fs and terminal" do
      caps = Callbacks.capabilities_for_policy(:all)
      assert caps["fs"]["readTextFile"] == true
      assert caps["fs"]["writeTextFile"] == true
      assert caps["terminal"] == true
    end

    test ":trusted advertises full fs and terminal" do
      caps = Callbacks.capabilities_for_policy(:trusted)
      assert caps["fs"]["readTextFile"] == true
      assert caps["fs"]["writeTextFile"] == true
      assert caps["terminal"] == true
    end
  end

  describe "clamp_capabilities_for_policy/2" do
    test ":read_only clamps unsafe caller capability overrides" do
      unsafe = %{
        "fs" => %{"readTextFile" => true, "writeTextFile" => true},
        "terminal" => true
      }

      caps = Callbacks.clamp_capabilities_for_policy(unsafe, :read_only)

      assert caps["fs"]["readTextFile"] == true
      assert caps["fs"]["writeTextFile"] == false
      assert caps["terminal"] == false
    end

    test ":read_only permits callers to reduce read capabilities" do
      requested = %{"fs" => %{"readTextFile" => false, "writeTextFile" => true}}

      caps = Callbacks.clamp_capabilities_for_policy(requested, :read_only)

      assert caps["fs"]["readTextFile"] == false
      assert caps["fs"]["writeTextFile"] == false
      assert caps["terminal"] == false
    end

    test ":all keeps caller capability overrides unchanged" do
      requested = %{
        "fs" => %{"readTextFile" => true, "writeTextFile" => true},
        "terminal" => true
      }

      assert Callbacks.clamp_capabilities_for_policy(requested, :all) == requested
    end
  end

  describe "denied_error/1" do
    test "returns an error tuple with method name in message" do
      assert {:error, -32_000, message, nil} = Callbacks.denied_error("fs/write_text_file")
      assert message =~ "not allowed under current policy"
      assert message =~ "fs/write_text_file"
    end
  end
end
