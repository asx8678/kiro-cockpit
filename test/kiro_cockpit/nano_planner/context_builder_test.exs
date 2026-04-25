defmodule KiroCockpit.NanoPlanner.ContextBuilderTest do
  use ExUnit.Case, async: true

  alias KiroCockpit.NanoPlanner.ContextBuilder
  alias KiroCockpit.ProjectSnapshot

  setup context do
    dir =
      if tmp = context[:tmp_dir] do
        tmp
      else
        path = Path.join(System.tmp_dir!(), "kiro_cb_test_#{:erlang.unique_integer([:positive])}")
        File.mkdir_p!(path)
        on_exit(fn -> File.rm_rf!(path) end)
        path
      end

    {:ok, project_dir: dir}
  end

  defp touch!(path, second) do
    File.touch!(path, {{2024, 1, 1}, {0, 0, second}})
  end

  describe "build/1" do
    @tag :tmp_dir
    test "returns ok with a valid project directory", %{project_dir: dir} do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "mix.exs"), "defmodule Test.MixProject do end")

      assert {:ok, %ProjectSnapshot{} = snapshot} =
               ContextBuilder.build(project_dir: dir)

      assert snapshot.project_dir == dir
      assert snapshot.hash =~ ~r/^[0-9a-f]{64}$/
    end

    @tag :tmp_dir
    test "never mutates project files", %{project_dir: dir} do
      File.mkdir_p!(dir)
      mix_content = "original content"
      File.write!(Path.join(dir, "mix.exs"), mix_content)

      ContextBuilder.build(project_dir: dir)

      assert File.read!(Path.join(dir, "mix.exs")) == mix_content
    end

    test "returns error when project_dir is missing" do
      assert {:error, :project_dir_required} =
               ContextBuilder.build([])
    end

    test "returns error for nonexistent project_dir" do
      nonexistent = "/tmp/kiro_cb_nonexistent_#{:erlang.unique_integer([:positive])}"

      assert {:error, {:project_dir_not_found, ^nonexistent}} =
               ContextBuilder.build(project_dir: nonexistent)
    end

    test "returns error when project_dir is not a directory" do
      tmp = Path.join(System.tmp_dir!(), "kiro_cb_file_#{:erlang.unique_integer([:positive])}")
      File.write!(tmp, "not a dir")

      on_exit(fn -> File.rm(tmp) end)

      assert {:error, {:project_dir_not_directory, ^tmp}} =
               ContextBuilder.build(project_dir: tmp)
    end

    @tag :tmp_dir
    test "detects elixir/phoenix stack from mix.exs", %{project_dir: dir} do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "mix.exs"), "defmodule Test.MixProject do end")

      assert {:ok, snapshot} = ContextBuilder.build(project_dir: dir)
      assert "elixir/phoenix" in snapshot.detected_stack
    end

    @tag :tmp_dir
    test "detects node stack from package.json", %{project_dir: dir} do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "package.json"), ~s({"name": "test"}))

      assert {:ok, snapshot} = ContextBuilder.build(project_dir: dir)
      assert "node" in snapshot.detected_stack
    end

    @tag :tmp_dir
    test "detects multiple stacks simultaneously", %{project_dir: dir} do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "mix.exs"), "defmodule MixProject do end")
      File.write!(Path.join(dir, "package.json"), ~s({"name": "test"}))

      assert {:ok, snapshot} = ContextBuilder.build(project_dir: dir)
      assert "elixir/phoenix" in snapshot.detected_stack
      assert "node" in snapshot.detected_stack
    end

    @tag :tmp_dir
    test "detects python stack from pyproject.toml", %{project_dir: dir} do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "pyproject.toml"), "[project]\nname = 'test'")

      assert {:ok, snapshot} = ContextBuilder.build(project_dir: dir)
      assert "python" in snapshot.detected_stack
    end

    @tag :tmp_dir
    test "detects rust stack from Cargo.toml", %{project_dir: dir} do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "Cargo.toml"), "[package]\nname = 'test'")

      assert {:ok, snapshot} = ContextBuilder.build(project_dir: dir)
      assert "rust" in snapshot.detected_stack
    end

    @tag :tmp_dir
    test "detects go stack from go.mod", %{project_dir: dir} do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "go.mod"), "module test\n\ngo 1.21")

      assert {:ok, snapshot} = ContextBuilder.build(project_dir: dir)
      assert "go" in snapshot.detected_stack
    end

    @tag :tmp_dir
    test "detects deno stack from deno.json", %{project_dir: dir} do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "deno.json"), ~s({"tasks": {}}))

      assert {:ok, snapshot} = ContextBuilder.build(project_dir: dir)
      assert "deno" in snapshot.detected_stack
    end

    @tag :tmp_dir
    test "returns empty stack for unknown project type", %{project_dir: dir} do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "random.txt"), "hello")

      assert {:ok, snapshot} = ContextBuilder.build(project_dir: dir)
      assert snapshot.detected_stack == []
    end

    @tag :tmp_dir
    test "reads safe config files", %{project_dir: dir} do
      File.mkdir_p!(dir)
      mix_content = "defmodule Test.MixProject do\n  use Mix.Project\nend"
      File.write!(Path.join(dir, "mix.exs"), mix_content)
      File.write!(Path.join(dir, "README.md"), "# Test Project")

      assert {:ok, snapshot} = ContextBuilder.build(project_dir: dir)
      assert Map.has_key?(snapshot.config_excerpts, "mix.exs")
      assert Map.has_key?(snapshot.config_excerpts, "README.md")
    end

    @tag :tmp_dir
    test "does not read unsafe files", %{project_dir: dir} do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, ".env"), "SECRET=supersecret")
      File.write!(Path.join(dir, "mix.exs"), "defmodule MixProject do end")

      assert {:ok, snapshot} = ContextBuilder.build(project_dir: dir)
      refute Map.has_key?(snapshot.config_excerpts, ".env")
    end

    @tag :tmp_dir
    test "reads .kiro directory files", %{project_dir: dir} do
      kiro_dir = Path.join(dir, ".kiro")
      File.mkdir_p!(kiro_dir)
      File.write!(Path.join(kiro_dir, "agents"), "test agent config")
      assert {:ok, snapshot} = ContextBuilder.build(project_dir: dir)

      kiro_keys =
        Enum.filter(Map.keys(snapshot.config_excerpts), &String.starts_with?(&1, ".kiro"))

      assert length(kiro_keys) > 0
    end

    @tag :tmp_dir
    test "reads lib/*_web/router.ex via glob", %{project_dir: dir} do
      web_dir = Path.join([dir, "lib", "test_web"])
      File.mkdir_p!(web_dir)
      File.write!(Path.join(web_dir, "router.ex"), "defmodule TestWeb.Router do end")

      assert {:ok, snapshot} = ContextBuilder.build(project_dir: dir)

      router_keys =
        Enum.filter(Map.keys(snapshot.config_excerpts), &String.ends_with?(&1, "router.ex"))

      assert length(router_keys) > 0
    end

    @tag :tmp_dir
    test "truncates file content at max_file_chars_per_file", %{project_dir: dir} do
      File.mkdir_p!(dir)
      long_content = String.duplicate("x", 10_000)
      File.write!(Path.join(dir, "mix.exs"), long_content)

      assert {:ok, snapshot} =
               ContextBuilder.build(project_dir: dir, max_file_chars_per_file: 500)

      excerpt = Map.get(snapshot.config_excerpts, "mix.exs")
      assert excerpt != nil
      assert String.length(excerpt) <= 500
    end

    @tag :tmp_dir
    test "includes kiro_plan.md summary when present", %{project_dir: dir} do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "kiro_plan.md"), "# Existing Plan\nDo the thing.")
      File.write!(Path.join(dir, "mix.exs"), "defmodule MixProject do end")

      assert {:ok, snapshot} = ContextBuilder.build(project_dir: dir)
      assert snapshot.existing_plans =~ "Existing Plan"
    end

    @tag :tmp_dir
    test "returns nil existing_plans when kiro_plan.md is absent", %{project_dir: dir} do
      File.mkdir_p!(dir)

      assert {:ok, snapshot} = ContextBuilder.build(project_dir: dir)
      assert snapshot.existing_plans == nil
    end

    @tag :tmp_dir
    test "includes session_summary when provided", %{project_dir: dir} do
      File.mkdir_p!(dir)

      assert {:ok, snapshot} =
               ContextBuilder.build(
                 project_dir: dir,
                 session_summary: "3 turns, 1 error"
               )

      assert snapshot.session_summary == "3 turns, 1 error"
    end

    @tag :tmp_dir
    test "produces a valid snapshot hash", %{project_dir: dir} do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "mix.exs"), "defmodule MixProject do end")

      assert {:ok, snapshot} = ContextBuilder.build(project_dir: dir)
      assert snapshot.hash =~ ~r/^[0-9a-f]{64}$/
    end

    @tag :tmp_dir
    test "same project state produces same hash", %{project_dir: dir} do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "mix.exs"), "defmodule MixProject do end")

      assert {:ok, s1} = ContextBuilder.build(project_dir: dir)
      assert {:ok, s2} = ContextBuilder.build(project_dir: dir)
      assert s1.hash == s2.hash
    end

    @tag :tmp_dir
    test "changed safe config file content produces different hash", %{project_dir: dir} do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "mix.exs"), "version 1")

      assert {:ok, s1} = ContextBuilder.build(project_dir: dir)

      File.write!(Path.join(dir, "mix.exs"), "version 2")
      touch!(Path.join(dir, "mix.exs"), 2)

      assert {:ok, s2} = ContextBuilder.build(project_dir: dir)
      refute s1.hash == s2.hash
    end

    @tag :tmp_dir
    test "changed relevant source file content produces different hash", %{project_dir: dir} do
      source_path = Path.join([dir, "lib", "example.ex"])
      File.mkdir_p!(Path.dirname(source_path))
      File.write!(source_path, "defmodule Example do
  def value, do: 1
end
")
      touch!(source_path, 1)

      assert {:ok, s1} = ContextBuilder.build(project_dir: dir)

      File.write!(source_path, "defmodule Example do
  def value, do: 2
end
")
      touch!(source_path, 2)

      assert {:ok, s2} = ContextBuilder.build(project_dir: dir)
      refute s1.hash == s2.hash
    end

    @tag :tmp_dir
    test "changing session summary does not change project snapshot hash", %{project_dir: dir} do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "mix.exs"), "defmodule MixProject do end")

      assert {:ok, s1} = ContextBuilder.build(project_dir: dir, session_summary: "session one")
      assert {:ok, s2} = ContextBuilder.build(project_dir: dir, session_summary: "session two")

      assert s1.hash == s2.hash
    end

    @tag :tmp_dir
    test "changes beyond excerpt limit still change hash", %{project_dir: dir} do
      readme_path = Path.join(dir, "README.md")
      File.mkdir_p!(dir)
      File.write!(readme_path, String.duplicate("a", 100) <> "one")
      touch!(readme_path, 1)

      assert {:ok, s1} =
               ContextBuilder.build(project_dir: dir, max_file_chars_per_file: 100)

      File.write!(readme_path, String.duplicate("a", 100) <> "two")
      touch!(readme_path, 2)

      assert {:ok, s2} =
               ContextBuilder.build(project_dir: dir, max_file_chars_per_file: 100)

      assert s1.config_excerpts["README.md"] == s2.config_excerpts["README.md"]
      refute s1.hash == s2.hash
    end
  end

  describe "budget enforcement" do
    @tag :tmp_dir
    test "respects max_total_context_chars budget", %{project_dir: dir} do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "README.md"), String.duplicate("x", 50_000))

      assert {:ok, snapshot} =
               ContextBuilder.build(
                 project_dir: dir,
                 max_total_context_chars: 5_000
               )

      assert snapshot.total_chars <= 5_000
    end

    @tag :tmp_dir
    test "trimming removes config excerpts when budget is tight", %{project_dir: dir} do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "mix.exs"), String.duplicate("y", 20_000))

      assert {:ok, snapshot} =
               ContextBuilder.build(
                 project_dir: dir,
                 max_total_context_chars: 500
               )

      markdown = ProjectSnapshot.to_markdown(snapshot)
      assert String.length(markdown) <= 500
    end

    @tag :tmp_dir
    test "returns budget_exceeded when even minimal snapshot cannot fit", %{project_dir: dir} do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "mix.exs"), "defmodule MixProject do end")

      assert {:error, :budget_exceeded} =
               ContextBuilder.build(
                 project_dir: dir,
                 max_total_context_chars: 10
               )
    end
  end

  describe "read_root_tree/2" do
    @tag :tmp_dir
    test "produces a shallow top-level listing for a directory", %{project_dir: dir} do
      File.mkdir_p!(Path.join(dir, "lib"))
      File.write!(Path.join(dir, "mix.exs"), "content")
      File.write!(Path.join([dir, "lib", "nested.ex"]), "defmodule Nested do end")

      tree = ContextBuilder.read_root_tree(dir, 200)

      assert tree =~ "mix.exs"
      assert tree =~ "lib/"
      refute tree =~ "nested.ex"
    end

    @tag :tmp_dir
    test "omits noisy vendor and build directories from root listing", %{project_dir: dir} do
      File.mkdir_p!(Path.join(dir, "deps"))
      File.mkdir_p!(Path.join(dir, "node_modules"))
      File.mkdir_p!(Path.join(dir, "_build"))
      File.mkdir_p!(Path.join(dir, ".git"))
      File.write!(Path.join(dir, "mix.exs"), "content")

      tree = ContextBuilder.read_root_tree(dir, 200)

      assert tree =~ "mix.exs"
      refute tree =~ "deps"
      refute tree =~ "node_modules"
      refute tree =~ "_build"
      refute tree =~ ".git"
    end

    @tag :tmp_dir
    test "caps output at max_tree_lines", %{project_dir: dir} do
      File.mkdir_p!(dir)

      for i <- 1..300 do
        File.write!(Path.join(dir, "file_#{i}.txt"), "content")
      end

      tree = ContextBuilder.read_root_tree(dir, 10)
      line_count = tree |> String.split("\n", trim: true) |> length()

      assert line_count <= 10
    end

    test "returns placeholder for missing directory" do
      tree = ContextBuilder.read_root_tree("/tmp/nonexistent_kiro_dir_xyz", 200)

      assert tree =~ "could not read directory"
    end
  end

  describe "detect_stack/1" do
    @tag :tmp_dir
    test "detects all known stacks", %{project_dir: dir} do
      File.mkdir_p!(dir)

      for {marker, _label} <- [
            {"mix.exs", "elixir/phoenix"},
            {"package.json", "node"},
            {"pyproject.toml", "python"},
            {"Cargo.toml", "rust"},
            {"go.mod", "go"},
            {"deno.json", "deno"}
          ] do
        File.write!(Path.join(dir, marker), "content")
      end

      stack = ContextBuilder.detect_stack(dir)

      assert "elixir/phoenix" in stack
      assert "node" in stack
      assert "python" in stack
      assert "rust" in stack
      assert "go" in stack
      assert "deno" in stack
    end

    @tag :tmp_dir
    test "returns empty list for unknown project", %{project_dir: dir} do
      File.mkdir_p!(dir)
      assert ContextBuilder.detect_stack(dir) == []
    end
  end

  describe "read_safe_files/2" do
    @tag :tmp_dir
    test "reads all safe files that exist", %{project_dir: dir} do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "README.md"), "# Readme")
      File.write!(Path.join(dir, "AGENTS.md"), "# Agents")
      File.write!(Path.join(dir, "mix.exs"), "defmodule MixProject")

      excerpts = ContextBuilder.read_safe_files(dir, 6_000)

      assert Map.get(excerpts, "README.md") == "# Readme"
      assert Map.get(excerpts, "AGENTS.md") == "# Agents"
      assert Map.get(excerpts, "mix.exs") == "defmodule MixProject"
    end

    @tag :tmp_dir
    test "ignores safe files that do not exist", %{project_dir: dir} do
      File.mkdir_p!(dir)

      excerpts = ContextBuilder.read_safe_files(dir, 6_000)

      assert map_size(excerpts) == 0
    end

    @tag :tmp_dir
    test "truncates at max_chars", %{project_dir: dir} do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "README.md"), String.duplicate("a", 10_000))

      excerpts = ContextBuilder.read_safe_files(dir, 100)

      assert String.length(Map.get(excerpts, "README.md")) == 100
    end

    @tag :tmp_dir
    test "reads pnpm-lock.yaml and uv.lock", %{project_dir: dir} do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "pnpm-lock.yaml"), "lockfile: v6")
      File.write!(Path.join(dir, "uv.lock"), "uv-lock-version: 1")

      excerpts = ContextBuilder.read_safe_files(dir, 6_000)

      assert Map.has_key?(excerpts, "pnpm-lock.yaml")
      assert Map.has_key?(excerpts, "uv.lock")
    end

    @tag :tmp_dir
    test "reads config/config.exs", %{project_dir: dir} do
      config_dir = Path.join(dir, "config")
      File.mkdir_p!(config_dir)
      File.write!(Path.join(config_dir, "config.exs"), "import Config")

      excerpts = ContextBuilder.read_safe_files(dir, 6_000)

      assert Map.has_key?(excerpts, Path.join("config", "config.exs"))
    end

    @tag :tmp_dir
    test "does not follow symlinked ancestor directories for safe files", %{project_dir: dir} do
      outside_dir =
        Path.join(System.tmp_dir!(), "kiro_cb_outside_#{:erlang.unique_integer([:positive])}")

      File.mkdir_p!(outside_dir)
      File.write!(Path.join(outside_dir, "config.exs"), "secret outside config")
      on_exit(fn -> File.rm_rf!(outside_dir) end)

      assert :ok = File.ln_s(outside_dir, Path.join(dir, "config"))

      excerpts = ContextBuilder.read_safe_files(dir, 6_000)

      refute Map.has_key?(excerpts, Path.join("config", "config.exs"))
    end

    @tag :tmp_dir
    test "reads lib/*_web/router.ex glob", %{project_dir: dir} do
      web_dir = Path.join([dir, "lib", "my_app_web"])
      File.mkdir_p!(web_dir)
      File.write!(Path.join(web_dir, "router.ex"), "defmodule MyAppWeb.Router")

      excerpts = ContextBuilder.read_safe_files(dir, 6_000)

      router_key =
        Map.keys(excerpts)
        |> Enum.find(&String.ends_with?(&1, "router.ex"))

      assert router_key != nil
      assert Map.get(excerpts, router_key) == "defmodule MyAppWeb.Router"
    end

    @tag :tmp_dir
    test "does not follow symlinked ancestor directories for globbed safe files", %{
      project_dir: dir
    } do
      outside_web_dir =
        Path.join(System.tmp_dir!(), "kiro_cb_outside_web_#{:erlang.unique_integer([:positive])}")

      File.mkdir_p!(Path.join(outside_web_dir, "my_app_web"))
      File.write!(Path.join([outside_web_dir, "my_app_web", "router.ex"]), "outside router")
      on_exit(fn -> File.rm_rf!(outside_web_dir) end)

      assert :ok = File.ln_s(outside_web_dir, Path.join(dir, "lib"))

      excerpts = ContextBuilder.read_safe_files(dir, 6_000)

      router_key =
        Map.keys(excerpts)
        |> Enum.find(&String.ends_with?(&1, "router.ex"))

      assert router_key == nil
    end

    @tag :tmp_dir
    test "does not read files outside safe list", %{project_dir: dir} do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, ".env"), "SECRET_KEY=abc123")
      File.write!(Path.join(dir, ".gitconfig"), "[user]\\nname=test")
      File.write!(Path.join(dir, "id_rsa"), "PRIVATE KEY DATA")

      excerpts = ContextBuilder.read_safe_files(dir, 6_000)

      refute Map.has_key?(excerpts, ".env")
      refute Map.has_key?(excerpts, ".gitconfig")
      refute Map.has_key?(excerpts, "id_rsa")
    end

    @tag :tmp_dir
    test "reads files under .kiro directory", %{project_dir: dir} do
      kiro_dir = Path.join(dir, ".kiro")
      File.mkdir_p!(Path.join(kiro_dir, "agents"))
      File.write!(Path.join([kiro_dir, "agents", "planner.json"]), ~s({"role": "planner"}))
      File.write!(Path.join(kiro_dir, "rules.md"), "# Rules")

      excerpts = ContextBuilder.read_safe_files(dir, 6_000)

      kiro_keys = Enum.filter(Map.keys(excerpts), &String.starts_with?(&1, ".kiro"))
      assert length(kiro_keys) >= 2
    end
  end

  describe "read_kiro_plan/2" do
    @tag :tmp_dir
    test "reads kiro_plan.md when present", %{project_dir: dir} do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "kiro_plan.md"), "# My Plan\nDo things.")

      assert ContextBuilder.read_kiro_plan(dir, 6_000) =~ "My Plan"
    end

    @tag :tmp_dir
    test "returns nil when kiro_plan.md is absent", %{project_dir: dir} do
      File.mkdir_p!(dir)

      assert ContextBuilder.read_kiro_plan(dir, 6_000) == nil
    end

    @tag :tmp_dir
    test "truncates kiro_plan.md at max_chars", %{project_dir: dir} do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "kiro_plan.md"), String.duplicate("p", 10_000))

      result = ContextBuilder.read_kiro_plan(dir, 500)

      assert String.length(result) == 500
    end
  end

  describe "graceful error handling" do
    @tag :tmp_dir
    test "handles unreadable files gracefully", %{project_dir: dir} do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "mix.exs"), "defmodule MixProject do end")
      File.write!(Path.join(dir, "README.md"), "test")

      assert {:ok, _snapshot} = ContextBuilder.build(project_dir: dir)
    end

    @tag :tmp_dir
    test "handles empty project directory", %{project_dir: dir} do
      File.mkdir_p!(dir)

      assert {:ok, snapshot} = ContextBuilder.build(project_dir: dir)
      assert snapshot.detected_stack == []
      assert map_size(snapshot.config_excerpts) == 0
      assert snapshot.existing_plans == nil
    end

    @tag :tmp_dir
    test "handles project with deeply nested .kiro files", %{project_dir: dir} do
      deep_dir = Path.join([dir, ".kiro", "agents", "nested"])
      File.mkdir_p!(deep_dir)
      File.write!(Path.join(deep_dir, "deep.json"), ~s({"deep": true}))

      excerpts = ContextBuilder.read_safe_files(dir, 6_000)

      deep_keys = Enum.filter(Map.keys(excerpts), &String.contains?(&1, "nested"))
      assert length(deep_keys) > 0
    end
  end

  describe "to_markdown integration" do
    @tag :tmp_dir
    test "snapshot markdown contains all required sections", %{project_dir: dir} do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "mix.exs"), "defmodule Test.MixProject do end")
      File.write!(Path.join(dir, "README.md"), "# Test Project")

      assert {:ok, snapshot} = ContextBuilder.build(project_dir: dir)
      md = ProjectSnapshot.to_markdown(snapshot)

      assert md =~ "# Project Snapshot"
      assert md =~ "## Root files"
      assert md =~ "## Detected stack"
      assert md =~ "## Important config excerpts"
      assert md =~ "## Existing plans"
      assert md =~ "## Session summary"
    end
  end
end
