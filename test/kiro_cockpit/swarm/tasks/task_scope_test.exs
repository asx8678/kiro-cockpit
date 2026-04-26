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
    test "allows permission with :allow verdict and matching scope" do
      task = build_task(category: "acting", permission_scope: ["read", "write"])

      assert {:ok, :allowed} = TaskScope.permission_allowed?(task, :read)
    end

    test "denies permission outside category ceiling" do
      task = build_task(category: "researching", permission_scope: ["read", "write"])

      assert {:error, :category_denied} = TaskScope.permission_allowed?(task, :write)
    end

    test "denies permission outside task scope even if category allows it" do
      # researching auto-allows :read and :shell_read
      task = build_task(category: "researching", permission_scope: ["read"])

      assert {:ok, :allowed} = TaskScope.permission_allowed?(task, :read)
      assert {:error, :scope_denied} = TaskScope.permission_allowed?(task, :shell_read)
    end

    test "empty permission scope means unconstrained within auto-allowed" do
      task = build_task(category: "acting", permission_scope: [])

      # Acting auto-allows only :read
      assert {:ok, :allowed} = TaskScope.permission_allowed?(task, :read)

      # Acting :write/:shell_read/:shell_write are :ask (need approval)
      assert {:error, :needs_approval} = TaskScope.permission_allowed?(task, :write)
      assert {:error, :needs_approval} = TaskScope.permission_allowed?(task, :shell_read)
      assert {:error, :needs_approval} = TaskScope.permission_allowed?(task, :shell_write)

      # Acting :terminal/:external/:destructive are also :ask
      assert {:error, :needs_approval} = TaskScope.permission_allowed?(task, :terminal)
      assert {:error, :needs_approval} = TaskScope.permission_allowed?(task, :external)
      assert {:error, :needs_approval} = TaskScope.permission_allowed?(task, :destructive)
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

    test "acting write requires both policy clearance and approval" do
      task = build_task(category: "acting", permission_scope: ["write"])

      assert {:error, :needs_approval} =
               TaskScope.permission_allowed?(task, :write, approved: true)

      assert {:error, :needs_approval} =
               TaskScope.permission_allowed?(task, :write, policy_allows_write: true)

      assert {:ok, :allowed} =
               TaskScope.permission_allowed?(task, :write,
                 approved: true,
                 policy_allows_write: true
               )
    end

    test "planning blocks shell_read even when in scope" do
      task = build_task(category: "planning", permission_scope: ["read", "shell_read"])
      assert {:error, :category_denied} = TaskScope.permission_allowed?(task, :shell_read)
    end

    test "verifying allows read and shell_read" do
      task = build_task(%{category: "verifying", permission_scope: []})

      assert {:ok, :allowed} = TaskScope.permission_allowed?(task, :read)
      assert {:ok, :allowed} = TaskScope.permission_allowed?(task, :shell_read)
      assert {:error, :category_denied} = TaskScope.permission_allowed?(task, :write)
      assert {:error, :needs_approval} = TaskScope.permission_allowed?(task, :shell_write)
    end

    test "debugging allows read and shell_read, blocks write" do
      task = build_task(%{category: "debugging", permission_scope: []})

      assert {:ok, :allowed} = TaskScope.permission_allowed?(task, :read)
      assert {:ok, :allowed} = TaskScope.permission_allowed?(task, :shell_read)
      assert {:error, :category_denied} = TaskScope.permission_allowed?(task, :write)
    end

    test "documenting allows read and asks for memory_write/write" do
      task =
        build_task(category: "documenting", permission_scope: ["read", "write", "memory_write"])

      assert {:ok, :allowed} = TaskScope.permission_allowed?(task, :read)
      assert {:error, :needs_approval} = TaskScope.permission_allowed?(task, :memory_write)
      assert {:error, :needs_approval} = TaskScope.permission_allowed?(task, :write)
      assert {:error, :category_denied} = TaskScope.permission_allowed?(task, :shell_write)
    end

    test "permissions narrow: scope intersection, not union" do
      # Researching auto-allows :read and :shell_read, but scope only allows read
      task = build_task(category: "researching", permission_scope: ["read"])

      assert {:ok, :allowed} = TaskScope.permission_allowed?(task, :read)
      assert {:error, :scope_denied} = TaskScope.permission_allowed?(task, :shell_read)
    end

    test ":ask verdict returns needs_approval by default" do
      task = build_task(category: "acting", permission_scope: ["write"])
      assert {:error, :needs_approval} = TaskScope.permission_allowed?(task, :write)
    end

    test ":ask verdict still respects task permission scope before approval" do
      task = build_task(category: "acting", permission_scope: ["read"])
      assert {:error, :scope_denied} = TaskScope.permission_allowed?(task, :write)
    end

    test ":ask verdict returns allowed when approved: true" do
      task = build_task(category: "acting", permission_scope: ["shell_write"])
      assert {:ok, :allowed} = TaskScope.permission_allowed?(task, :shell_write, approved: true)
    end

    test "acting write needs approval even with scope match" do
      task = build_task(category: "acting", permission_scope: ["read", "write", "shell_write"])
      # Acting write is :ask → needs approval without approved: true
      assert {:error, :needs_approval} = TaskScope.permission_allowed?(task, :write)
      assert {:error, :needs_approval} = TaskScope.permission_allowed?(task, :shell_write)
    end

    test "acting write allowed with approval and scope match" do
      task = build_task(category: "acting", permission_scope: ["read", "write"])

      assert {:ok, :allowed} =
               TaskScope.permission_allowed?(task, :write,
                 approved: true,
                 policy_allows_write: true
               )
    end

    test "debugging write blocked even with scope; needs root_cause + approval" do
      task = build_task(category: "debugging", permission_scope: ["read", "write"])
      # debugging write is :block → category_denied
      assert {:error, :category_denied} = TaskScope.permission_allowed?(task, :write)

      # With root_cause_stated, becomes :ask → needs_approval
      assert {:error, :needs_approval} =
               TaskScope.permission_allowed?(task, :write, root_cause_stated: true)

      # With root_cause_stated + approved, becomes :allow → check scope
      assert {:ok, :allowed} =
               TaskScope.permission_allowed?(task, :write,
                 root_cause_stated: true,
                 approved: true
               )
    end

    test "documenting write needs docs_scoped for approval" do
      task = build_task(category: "documenting", permission_scope: ["read", "write"])

      # documenting write is :ask → needs_approval
      assert {:error, :needs_approval} = TaskScope.permission_allowed?(task, :write)

      # With docs_scoped, becomes :allow → check scope
      assert {:ok, :allowed} =
               TaskScope.permission_allowed?(task, :write, docs_scoped: true)
    end

    test "subagent requires approval across all categories" do
      for cat <- Task.categories() do
        task = build_task(category: cat, permission_scope: ["subagent"])
        result = TaskScope.permission_allowed?(task, :subagent)

        case result do
          {:error, :needs_approval} -> :ok
          {:error, :category_denied} -> :ok
          other -> flunk("#{cat} × subagent: expected error, got #{inspect(other)}")
        end
      end
    end
  end

  describe "effective_permissions/1" do
    test "returns auto-allowed permissions when scope is empty" do
      task = build_task(category: "acting", permission_scope: [])
      perms = TaskScope.effective_permissions(task)

      # Acting auto-allows only :read
      assert MapSet.member?(perms, :read)
      refute MapSet.member?(perms, :write)
      refute MapSet.member?(perms, :shell_read)
      refute MapSet.member?(perms, :shell_write)
      refute MapSet.member?(perms, :terminal)
      refute MapSet.member?(perms, :external)
      refute MapSet.member?(perms, :destructive)
    end

    test "returns intersection of auto-allowed and scope" do
      task = build_task(category: "acting", permission_scope: ["read"])
      perms = TaskScope.effective_permissions(task)

      assert MapSet.equal?(perms, MapSet.new([:read]))
    end

    test "scope outside auto-allowed is ignored" do
      task = build_task(category: "researching", permission_scope: ["read", "write"])
      perms = TaskScope.effective_permissions(task)

      # researching auto-allows :read and :shell_read; write is not auto-allowed
      assert MapSet.equal?(perms, MapSet.new([:read]))
    end

    test "documenting does not auto-allow memory_write" do
      task = build_task(category: "documenting", permission_scope: [])
      perms = TaskScope.effective_permissions(task)

      assert MapSet.member?(perms, :read)
      assert MapSet.member?(perms, :shell_read)
      refute MapSet.member?(perms, :memory_write)
    end
  end

  describe "category_permissions/1" do
    test "returns auto-allowed permissions for each category" do
      for category <- Task.categories() do
        perms = TaskScope.category_permissions(category)

        assert MapSet.size(perms) > 0,
               "Category #{category} should have at least one auto-allowed permission"

        assert MapSet.member?(perms, :read), "All categories should auto-allow :read"
      end
    end

    test "returns empty set for unknown category" do
      perms = TaskScope.category_permissions("unknown")
      assert MapSet.size(perms) == 0
    end
  end

  describe "category_ceiling/1" do
    test "returns all non-blocked permissions for acting" do
      ceiling = TaskScope.category_ceiling("acting")
      # Acting has no blocks — all perms are either :allow or :ask
      assert MapSet.size(ceiling) == 9
    end

    test "researching ceiling excludes hard-blocked perms" do
      ceiling = TaskScope.category_ceiling("researching")
      refute MapSet.member?(ceiling, :write)
      refute MapSet.member?(ceiling, :shell_write)
      refute MapSet.member?(ceiling, :terminal)
      refute MapSet.member?(ceiling, :destructive)
      assert MapSet.member?(ceiling, :read)
      assert MapSet.member?(ceiling, :external)
    end
  end

  describe "category_allows_write?/1" do
    test "acting and documenting allow writes" do
      assert TaskScope.category_allows_write?("acting")
      assert TaskScope.category_allows_write?("documenting")
    end

    test "researching, planning deny writes" do
      refute TaskScope.category_allows_write?("researching")
      refute TaskScope.category_allows_write?("planning")
    end

    test "verifying and debugging deny writes by default" do
      refute TaskScope.category_allows_write?("verifying")
      refute TaskScope.category_allows_write?("debugging")
    end
  end

  # -----------------------------------------------------------------
  # File scope checks (unchanged)
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

    test "rejects unsafe absolute and traversal paths before matching" do
      task = build_task(files_scope: ["lib/allowed/"])

      assert {:error, :out_of_scope} =
               TaskScope.file_allowed?(task, "/workspace/lib/allowed/file.ex")

      assert {:error, :out_of_scope} =
               TaskScope.file_allowed?(task, "lib/allowed/../../secret.ex")

      assert {:error, :out_of_scope} = TaskScope.file_allowed?(task, "lib/allowed/./file.ex")
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
    test "requires approval even when category can write and file is in scope" do
      task = build_task(category: "acting", files_scope: ["lib/kiro_cockpit/"])

      assert {:error, :needs_approval} =
               TaskScope.category_and_file_allowed?(task, "lib/kiro_cockpit/repo.ex")

      assert {:ok, :allowed} =
               TaskScope.category_and_file_allowed?(task, "lib/kiro_cockpit/repo.ex",
                 approved: true,
                 policy_allows_write: true
               )
    end

    test "denies when category blocks writes even if file is in scope" do
      task = build_task(category: "researching", files_scope: ["lib/kiro_cockpit/"])

      assert {:error, :category_denied} =
               TaskScope.category_and_file_allowed?(task, "lib/kiro_cockpit/repo.ex")
    end

    test "denies when file is out of scope after approval" do
      task = build_task(category: "acting", files_scope: ["lib/other/"])

      assert {:error, :out_of_scope} =
               TaskScope.category_and_file_allowed?(task, "lib/kiro_cockpit/repo.ex",
                 approved: true,
                 policy_allows_write: true
               )
    end

    test "documenting blocks code paths even with approval" do
      task =
        build_task(category: "documenting", permission_scope: ["write"], files_scope: ["lib/"])

      assert {:error, :category_denied} =
               TaskScope.category_and_file_allowed?(task, "lib/code.ex", approved: true)
    end
  end

  # -----------------------------------------------------------------
  # Dependency helpers (unchanged)
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
