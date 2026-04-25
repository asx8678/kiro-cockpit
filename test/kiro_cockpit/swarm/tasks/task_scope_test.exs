defmodule KiroCockpit.Swarm.Tasks.TaskScopeTest do
  use ExUnit.Case, async: true

  alias KiroCockpit.Swarm.Tasks.{Task, TaskScope}

  defp build_task(overrides) do
    struct!(
      %Task{
        category: "acting",
        permission_scope: ["read", "write"],
        files_scope: ["lib/kiro_cockpit/"],
        depends_on: []
      },
      overrides
    )
  end

  # -----------------------------------------------------------------
  # Permission checks
  # -----------------------------------------------------------------

  describe "permission_allowed?/2" do
    test "allows permission within category and scope" do
      task = build_task(category: "acting", permission_scope: ["read", "write"])

      assert {:ok, :allowed} = TaskScope.permission_allowed?(task, :read)
      assert {:ok, :allowed} = TaskScope.permission_allowed?(task, :write)
    end

    test "denies permission outside category ceiling" do
      task = build_task(category: "researching", permission_scope: ["read", "write"])

      assert {:error, :category_denied} = TaskScope.permission_allowed?(task, :write)
    end

    test "denies permission outside task scope even if category allows it" do
      task = build_task(category: "acting", permission_scope: ["read"])

      assert {:ok, :allowed} = TaskScope.permission_allowed?(task, :read)
      assert {:error, :scope_denied} = TaskScope.permission_allowed?(task, :write)
    end

    test "empty permission scope means unconstrained within category" do
      task = build_task(category: "acting", permission_scope: [])

      assert {:ok, :allowed} = TaskScope.permission_allowed?(task, :read)
      assert {:ok, :allowed} = TaskScope.permission_allowed?(task, :write)
      assert {:ok, :allowed} = TaskScope.permission_allowed?(task, :shell_read)

      # Acting doesn't allow terminal/external/destructive at category level
      assert {:error, :category_denied} = TaskScope.permission_allowed?(task, :terminal)
      assert {:error, :category_denied} = TaskScope.permission_allowed?(task, :external)
      assert {:error, :category_denied} = TaskScope.permission_allowed?(task, :destructive)
    end

    test "researching blocks all writes" do
      task = build_task(category: "researching")

      assert {:ok, :allowed} = TaskScope.permission_allowed?(task, :read)
      assert {:error, :category_denied} = TaskScope.permission_allowed?(task, :write)
      assert {:error, :category_denied} = TaskScope.permission_allowed?(task, :shell_write)
      assert {:error, :category_denied} = TaskScope.permission_allowed?(task, :destructive)
    end

    test "planning blocks all writes" do
      task = build_task(category: "planning")

      assert {:ok, :allowed} = TaskScope.permission_allowed?(task, :read)
      assert {:error, :category_denied} = TaskScope.permission_allowed?(task, :write)
    end

    test "verifying allows only read and shell_read" do
      task = build_task(%{category: "verifying", permission_scope: []})

      assert {:ok, :allowed} = TaskScope.permission_allowed?(task, :read)
      assert {:ok, :allowed} = TaskScope.permission_allowed?(task, :shell_read)
      assert {:error, :category_denied} = TaskScope.permission_allowed?(task, :write)
      assert {:error, :category_denied} = TaskScope.permission_allowed?(task, :shell_write)
    end

    test "debugging allows only read and shell_read" do
      task = build_task(%{category: "debugging", permission_scope: []})

      assert {:ok, :allowed} = TaskScope.permission_allowed?(task, :read)
      assert {:ok, :allowed} = TaskScope.permission_allowed?(task, :shell_read)
      assert {:error, :category_denied} = TaskScope.permission_allowed?(task, :write)
    end

    test "documenting allows read and write" do
      task = build_task(category: "documenting")

      assert {:ok, :allowed} = TaskScope.permission_allowed?(task, :read)
      assert {:ok, :allowed} = TaskScope.permission_allowed?(task, :write)
      assert {:error, :category_denied} = TaskScope.permission_allowed?(task, :shell_write)
    end

    test "permissions narrow: scope intersection, not union" do
      # Acting allows write, but scope only allows read
      task = build_task(category: "acting", permission_scope: ["read"])

      assert {:ok, :allowed} = TaskScope.permission_allowed?(task, :read)
      assert {:error, :scope_denied} = TaskScope.permission_allowed?(task, :write)
    end
  end

  describe "effective_permissions/1" do
    test "returns category ceiling when scope is empty" do
      task = build_task(category: "acting", permission_scope: [])
      perms = TaskScope.effective_permissions(task)

      assert MapSet.member?(perms, :read)
      assert MapSet.member?(perms, :write)
      assert MapSet.member?(perms, :shell_read)
      assert MapSet.member?(perms, :shell_write)
      refute MapSet.member?(perms, :terminal)
      refute MapSet.member?(perms, :external)
      refute MapSet.member?(perms, :destructive)
    end

    test "returns intersection of category and scope" do
      task = build_task(category: "acting", permission_scope: ["read", "shell_read"])
      perms = TaskScope.effective_permissions(task)

      assert MapSet.equal?(perms, MapSet.new([:read, :shell_read]))
    end

    test "scope outside category is ignored" do
      task = build_task(category: "researching", permission_scope: ["read", "write"])
      perms = TaskScope.effective_permissions(task)

      # researching only allows read and shell_read; write is outside category
      assert MapSet.equal?(perms, MapSet.new([:read]))
    end
  end

  describe "category_permissions/1" do
    test "returns correct permissions for each category" do
      for category <- Task.categories() do
        perms = TaskScope.category_permissions(category)
        assert MapSet.size(perms) > 0, "Category #{category} should have at least one permission"
        assert MapSet.member?(perms, :read), "All categories should allow :read"
      end
    end

    test "returns empty set for unknown category" do
      perms = TaskScope.category_permissions("unknown")
      assert MapSet.size(perms) == 0
    end
  end

  describe "category_allows_write?/1" do
    test "acting and documenting allow writes" do
      assert TaskScope.category_allows_write?("acting")
      assert TaskScope.category_allows_write?("documenting")
    end

    test "researching, planning, verifying, debugging deny writes" do
      refute TaskScope.category_allows_write?("researching")
      refute TaskScope.category_allows_write?("planning")
      refute TaskScope.category_allows_write?("verifying")
      refute TaskScope.category_allows_write?("debugging")
    end
  end

  # -----------------------------------------------------------------
  # File scope checks
  # -----------------------------------------------------------------

  describe "file_allowed?/2" do
    test "allows any file when scope is empty" do
      task = build_task(files_scope: [])
      assert {:ok, :allowed} = TaskScope.file_allowed?(task, "lib/anything.ex")
    end

    test "allows file matching exact path" do
      task = build_task(files_scope: ["lib/kiro_cockpit/event_store.ex"])
      assert {:ok, :allowed} = TaskScope.file_allowed?(task, "lib/kiro_cockpit/event_store.ex")
    end

    test "denies file not matching exact path" do
      task = build_task(files_scope: ["lib/kiro_cockpit/event_store.ex"])
      assert {:error, :out_of_scope} = TaskScope.file_allowed?(task, "lib/other.ex")
    end

    test "allows file under directory prefix (trailing slash)" do
      task = build_task(files_scope: ["lib/kiro_cockpit/"])
      assert {:ok, :allowed} = TaskScope.file_allowed?(task, "lib/kiro_cockpit/event_store.ex")

      assert {:ok, :allowed} =
               TaskScope.file_allowed?(task, "lib/kiro_cockpit/swarm/tasks/task.ex")

      assert {:error, :out_of_scope} = TaskScope.file_allowed?(task, "lib/other/file.ex")
    end

    test "supports glob patterns with **" do
      task = build_task(files_scope: ["test/**/*_test.exs"])
      assert {:ok, :allowed} = TaskScope.file_allowed?(task, "test/kiro_cockpit/swarm_test.exs")

      assert {:ok, :allowed} =
               TaskScope.file_allowed?(task, "test/kiro_cockpit/swarm/tasks/task_test.exs")

      assert {:error, :out_of_scope} =
               TaskScope.file_allowed?(task, "test/kiro_cockpit/swarm_test.ex")
    end

    test "supports single * glob within segment" do
      task = build_task(files_scope: ["lib/kiro_cockpit/*.ex"])
      assert {:ok, :allowed} = TaskScope.file_allowed?(task, "lib/kiro_cockpit/repo.ex")
      # * does not match /
      assert {:error, :out_of_scope} =
               TaskScope.file_allowed?(task, "lib/kiro_cockpit/swarm/tasks/task.ex")
    end

    test "multiple patterns: any match allows" do
      task =
        build_task(files_scope: ["lib/kiro_cockpit/", "test/**/*_test.exs"])

      assert {:ok, :allowed} = TaskScope.file_allowed?(task, "lib/kiro_cockpit/repo.ex")

      assert {:ok, :allowed} =
               TaskScope.file_allowed?(task, "test/kiro_cockpit/foo_test.exs")

      assert {:error, :out_of_scope} = TaskScope.file_allowed?(task, "docs/README.md")
    end
  end

  describe "category_and_file_allowed?/2" do
    test "allows when category permits writes and file is in scope" do
      task = build_task(category: "acting", files_scope: ["lib/kiro_cockpit/"])

      assert {:ok, :allowed} =
               TaskScope.category_and_file_allowed?(task, "lib/kiro_cockpit/repo.ex")
    end

    test "denies when category blocks writes even if file is in scope" do
      task = build_task(category: "researching", files_scope: ["lib/kiro_cockpit/"])

      assert {:error, :category_denied} =
               TaskScope.category_and_file_allowed?(task, "lib/kiro_cockpit/repo.ex")
    end

    test "denies when file is out of scope even if category allows writes" do
      task = build_task(category: "acting", files_scope: ["lib/other/"])

      assert {:error, :out_of_scope} =
               TaskScope.category_and_file_allowed?(task, "lib/kiro_cockpit/repo.ex")
    end
  end

  # -----------------------------------------------------------------
  # Dependency helpers
  # -----------------------------------------------------------------

  describe "dependencies_met?/2" do
    test "task with no dependencies is always ready" do
      task = build_task(depends_on: [])
      assert TaskScope.dependencies_met?(task, MapSet.new())
    end

    test "task with met dependencies returns true" do
      task = build_task(depends_on: ["task_1", "task_2"])
      completed = MapSet.new(["task_1", "task_2", "task_3"])
      assert TaskScope.dependencies_met?(task, completed)
    end

    test "task with unmet dependencies returns false" do
      task = build_task(depends_on: ["task_1", "task_2"])
      completed = MapSet.new(["task_1"])
      refute TaskScope.dependencies_met?(task, completed)
    end

    test "task with all dependencies unmet returns false" do
      task = build_task(depends_on: ["task_1"])
      completed = MapSet.new([])
      refute TaskScope.dependencies_met?(task, completed)
    end
  end
end
