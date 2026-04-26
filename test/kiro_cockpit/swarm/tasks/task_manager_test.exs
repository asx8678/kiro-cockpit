defmodule KiroCockpit.Swarm.Tasks.TaskManagerTest do
  use KiroCockpit.DataCase, async: true

  import Ecto.Query

  alias KiroCockpit.Swarm.Tasks.{Task, TaskManager}

  @valid_attrs %{
    session_id: "session_test_001",
    content: "Implement ACP timeline event normalization",
    owner_id: "kiro-executor",
    category: "acting",
    priority: "high",
    sequence: 1,
    permission_scope: ["read", "write"],
    files_scope: ["lib/kiro_cockpit/event_store.ex"],
    acceptance_criteria: ["Unit tests cover all event types"]
  }

  # -----------------------------------------------------------------
  # Create
  # -----------------------------------------------------------------

  describe "create/1 — defaults and validations" do
    test "creates a task with minimal required fields and applies defaults" do
      attrs = %{
        session_id: "s1",
        content: "Do the thing",
        owner_id: "agent-1"
      }

      assert {:ok, task} = TaskManager.create(attrs)
      assert task.status == "pending"
      assert task.priority == "medium"
      assert task.category == "researching"
      assert task.sequence == 0
      assert task.notes == []
      assert task.depends_on == []
      assert task.blocks == []
      assert task.permission_scope == []
      assert task.files_scope == []
      assert task.acceptance_criteria == []
    end

    test "creates a task with all fields specified" do
      assert {:ok, task} = TaskManager.create(@valid_attrs)
      assert task.status == "pending"
      assert task.category == "acting"
      assert task.priority == "high"
      assert task.sequence == 1
      assert task.permission_scope == ["read", "write"]
      assert task.files_scope == ["lib/kiro_cockpit/event_store.ex"]
      assert task.acceptance_criteria == ["Unit tests cover all event types"]
    end

    test "requires session_id" do
      attrs = Map.delete(@valid_attrs, :session_id)
      assert {:error, changeset} = TaskManager.create(attrs)
      assert "can't be blank" in errors_on(changeset).session_id
    end

    test "requires content" do
      attrs = Map.delete(@valid_attrs, :content)
      assert {:error, changeset} = TaskManager.create(attrs)
      assert "can't be blank" in errors_on(changeset).content
    end

    test "requires owner_id" do
      attrs = Map.delete(@valid_attrs, :owner_id)
      assert {:error, changeset} = TaskManager.create(attrs)
      assert "can't be blank" in errors_on(changeset).owner_id
    end

    test "rejects invalid status" do
      attrs = Map.put(@valid_attrs, :status, "flying")
      assert {:error, changeset} = TaskManager.create(attrs)

      # DB-level CHECK constraint catches this; Ecto may report "is invalid" or "is not included in the list"
      errors = errors_on(changeset).status
      assert Enum.any?(errors, &(&1 == "is invalid" or &1 == "is not included in the list"))
    end

    test "rejects invalid priority" do
      attrs = Map.put(@valid_attrs, :priority, "urgent")
      assert {:error, changeset} = TaskManager.create(attrs)
      errors = errors_on(changeset).priority
      assert Enum.any?(errors, &(&1 == "is invalid" or &1 == "is not included in the list"))
    end

    test "rejects invalid category" do
      attrs = Map.put(@valid_attrs, :category, "cooking")
      assert {:error, changeset} = TaskManager.create(attrs)
      errors = errors_on(changeset).category
      assert Enum.any?(errors, &(&1 == "is invalid" or &1 == "is not included in the list"))
    end

    test "rejects negative sequence" do
      attrs = Map.put(@valid_attrs, :sequence, -1)
      assert {:error, changeset} = TaskManager.create(attrs)
      assert "must be greater than or equal to 0" in errors_on(changeset).sequence
    end

    test "rejects empty content" do
      attrs = Map.put(@valid_attrs, :content, "")
      assert {:error, _changeset} = TaskManager.create(attrs)
    end

    test "accepts all valid statuses" do
      for status <- Task.statuses() do
        attrs = Map.put(@valid_attrs, :status, status)
        assert {:ok, task} = TaskManager.create(attrs)
        assert task.status == status
      end
    end

    test "accepts all valid priorities" do
      for priority <- Task.priorities() do
        attrs = Map.put(@valid_attrs, :priority, priority)
        assert {:ok, task} = TaskManager.create(attrs)
        assert task.priority == priority
      end
    end

    test "accepts all valid categories" do
      for category <- Task.categories() do
        attrs = Map.put(@valid_attrs, :category, category)
        assert {:ok, task} = TaskManager.create(attrs)
        assert task.category == category
      end
    end

    test "nullable plan_id is accepted" do
      attrs = Map.put(@valid_attrs, :plan_id, nil)
      assert {:ok, task} = TaskManager.create(attrs)
      assert task.plan_id == nil
    end

    test "accepts canonical subagent and memory_write permission_scope values" do
      attrs =
        Map.put(@valid_attrs, :permission_scope, ["shell_write", "subagent", "memory_write"])

      assert {:ok, task} = TaskManager.create(attrs)
      assert task.permission_scope == ["shell_write", "subagent", "memory_write"]
    end

    test "normalizes permission_scope aliases before persistence" do
      attrs = Map.put(@valid_attrs, :permission_scope, ["shell", "shell_readonly"])

      assert {:ok, task} = TaskManager.create(attrs)
      assert task.permission_scope == ["shell_write", "shell_read"]
      refute "shell" in task.permission_scope
      refute "shell_readonly" in task.permission_scope
    end

    test "rejects invalid permission_scope values" do
      attrs = Map.put(@valid_attrs, :permission_scope, ["subagent", "banana"])

      assert {:error, changeset} = TaskManager.create(attrs)
      assert "contains invalid permissions" in errors_on(changeset).permission_scope
    end
  end

  describe "create_all/1 — batch creation" do
    test "creates multiple tasks atomically" do
      attrs_list = [
        Map.merge(@valid_attrs, %{sequence: 1, content: "Task 1"}),
        Map.merge(@valid_attrs, %{sequence: 2, content: "Task 2"}),
        Map.merge(@valid_attrs, %{sequence: 3, content: "Task 3"})
      ]

      assert {:ok, tasks} = TaskManager.create_all(attrs_list)
      assert length(tasks) == 3
      assert Enum.map(tasks, & &1.sequence) == [1, 2, 3]
    end

    test "rolls back all tasks if one is invalid" do
      attrs_list = [
        Map.merge(@valid_attrs, %{sequence: 1, content: "Task 1"}),
        Map.merge(@valid_attrs, %{sequence: 2, content: ""})
      ]

      assert {:error, :transaction_failed} = TaskManager.create_all(attrs_list)

      # Verify nothing was persisted
      count =
        from(t in Task, where: t.session_id == ^@valid_attrs.session_id)
        |> Repo.aggregate(:count)

      assert count == 0
    end
  end

  # -----------------------------------------------------------------
  # Read
  # -----------------------------------------------------------------

  describe "get/1" do
    test "returns the task by ID" do
      {:ok, task} = TaskManager.create(@valid_attrs)
      assert {:ok, fetched} = TaskManager.get(task.id)
      assert fetched.id == task.id
    end

    test "returns error for missing ID" do
      assert {:error, :not_found} == TaskManager.get(Ecto.UUID.generate())
    end
  end

  describe "list/2" do
    test "lists tasks for a session ordered by sequence" do
      TaskManager.create(Map.merge(@valid_attrs, %{sequence: 2, content: "Second"}))
      TaskManager.create(Map.merge(@valid_attrs, %{sequence: 1, content: "First"}))

      tasks = TaskManager.list(@valid_attrs.session_id)
      assert length(tasks) == 2
      assert Enum.at(tasks, 0).sequence == 1
      assert Enum.at(tasks, 1).sequence == 2
    end

    test "filters by status" do
      TaskManager.create(
        Map.merge(@valid_attrs, %{sequence: 1, content: "One", status: "pending"})
      )

      TaskManager.create(
        Map.merge(@valid_attrs, %{sequence: 2, content: "Two", status: "completed"})
      )

      tasks = TaskManager.list(@valid_attrs.session_id, status: "completed")
      assert length(tasks) == 1
      assert hd(tasks).status == "completed"
    end

    test "filters by plan_id" do
      {:ok, plan} = create_plan()
      TaskManager.create(Map.merge(@valid_attrs, %{sequence: 1, plan_id: plan.id, content: "P1"}))
      TaskManager.create(Map.merge(@valid_attrs, %{sequence: 2, plan_id: nil, content: "P2"}))

      tasks = TaskManager.list(@valid_attrs.session_id, plan_id: plan.id)
      assert length(tasks) == 1
      assert hd(tasks).plan_id == plan.id
    end

    test "returns empty list for unknown session" do
      assert [] == TaskManager.list("nonexistent_session")
    end
  end

  describe "get_active/2" do
    test "returns nil when no active task exists" do
      assert nil == TaskManager.get_active("s1", "agent-1")
    end

    test "returns the in_progress task for a lane" do
      {:ok, task} = TaskManager.create(@valid_attrs)
      {:ok, activated} = TaskManager.activate(task.id)

      assert fetched = TaskManager.get_active(@valid_attrs.session_id, @valid_attrs.owner_id)
      assert fetched.id == activated.id
    end

    test "does not return tasks from other lanes" do
      {:ok, task} = TaskManager.create(@valid_attrs)
      TaskManager.activate(task.id)

      assert nil == TaskManager.get_active("different_session", @valid_attrs.owner_id)
      assert nil == TaskManager.get_active(@valid_attrs.session_id, "different_owner")
    end
  end

  # -----------------------------------------------------------------
  # Status transitions
  # -----------------------------------------------------------------

  describe "activate/2 — activation exclusivity" do
    test "activates a pending task" do
      {:ok, task} = TaskManager.create(@valid_attrs)
      assert {:ok, activated} = TaskManager.activate(task.id)
      assert activated.status == "in_progress"
    end

    test "idempotent: activating an already-active task succeeds" do
      {:ok, task} = TaskManager.create(@valid_attrs)
      {:ok, _} = TaskManager.activate(task.id)
      assert {:ok, activated} = TaskManager.activate(task.id)
      assert activated.status == "in_progress"
    end

    test "rejects activating a second task when one is already active" do
      {:ok, task1} =
        TaskManager.create(Map.merge(@valid_attrs, %{sequence: 1, content: "First"}))

      {:ok, task2} =
        TaskManager.create(Map.merge(@valid_attrs, %{sequence: 2, content: "Second"}))

      assert {:ok, _} = TaskManager.activate(task1.id)
      assert {:error, :active_task_exists} = TaskManager.activate(task2.id)
    end

    test "allows activating a second task after the first is completed" do
      {:ok, task1} =
        TaskManager.create(Map.merge(@valid_attrs, %{sequence: 1, content: "First"}))

      {:ok, task2} =
        TaskManager.create(Map.merge(@valid_attrs, %{sequence: 2, content: "Second"}))

      assert {:ok, _} = TaskManager.activate(task1.id)
      assert {:ok, _} = TaskManager.complete(task1.id)
      assert {:ok, activated2} = TaskManager.activate(task2.id)
      assert activated2.status == "in_progress"
    end

    test "allows different owners to have concurrent active tasks" do
      {:ok, task1} =
        TaskManager.create(Map.merge(@valid_attrs, %{owner_id: "agent-1", content: "T1"}))

      {:ok, task2} =
        TaskManager.create(Map.merge(@valid_attrs, %{owner_id: "agent-2", content: "T2"}))

      assert {:ok, _} = TaskManager.activate(task1.id)
      assert {:ok, _} = TaskManager.activate(task2.id)
    end

    test "returns error for nonexistent task" do
      assert {:error, :not_found} = TaskManager.activate(Ecto.UUID.generate())
    end

    test "reactivates a blocked task" do
      {:ok, task} = TaskManager.create(@valid_attrs)
      {:ok, _} = TaskManager.activate(task.id)
      {:ok, blocked} = TaskManager.block(task.id)
      assert blocked.status == "blocked"
      {:ok, reactivated} = TaskManager.activate(task.id)
      assert reactivated.status == "in_progress"
    end
  end

  describe "complete/2" do
    test "completes an in_progress task" do
      {:ok, task} = TaskManager.create(@valid_attrs)
      {:ok, _} = TaskManager.activate(task.id)
      assert {:ok, completed} = TaskManager.complete(task.id)
      assert completed.status == "completed"
    end

    test "rejects completing a pending task (must activate first)" do
      {:ok, task} = TaskManager.create(@valid_attrs)
      assert {:error, %Ecto.Changeset{errors: [status: _]}} = TaskManager.complete(task.id)
    end

    test "returns error for nonexistent task" do
      assert {:error, :not_found} = TaskManager.complete(Ecto.UUID.generate())
    end
  end

  describe "block/2" do
    test "blocks an in_progress task" do
      {:ok, task} = TaskManager.create(@valid_attrs)
      {:ok, _} = TaskManager.activate(task.id)
      assert {:ok, blocked} = TaskManager.block(task.id)
      assert blocked.status == "blocked"
    end

    test "rejects blocking a pending task" do
      {:ok, task} = TaskManager.create(@valid_attrs)
      assert {:error, %Ecto.Changeset{errors: [status: _]}} = TaskManager.block(task.id)
    end

    test "returns error for nonexistent task" do
      assert {:error, :not_found} = TaskManager.block(Ecto.UUID.generate())
    end
  end

  describe "delete/1" do
    test "soft-deletes a pending task" do
      {:ok, task} = TaskManager.create(@valid_attrs)
      assert {:ok, deleted} = TaskManager.delete(task.id)
      assert deleted.status == "deleted"
    end

    test "soft-deletes an in_progress task" do
      {:ok, task} = TaskManager.create(@valid_attrs)
      {:ok, _} = TaskManager.activate(task.id)
      assert {:ok, deleted} = TaskManager.delete(task.id)
      assert deleted.status == "deleted"
    end

    test "returns error for nonexistent task" do
      assert {:error, :not_found} = TaskManager.delete(Ecto.UUID.generate())
    end
  end

  # -----------------------------------------------------------------
  # Transition validity
  # -----------------------------------------------------------------

  describe "Task.transition_changeset/2 — valid and invalid transitions" do
    test "pending → in_progress is valid" do
      task = %Task{status: "pending"}
      changeset = Task.transition_changeset(task, "in_progress")
      assert changeset.valid?
    end

    test "pending → deleted is valid" do
      task = %Task{status: "pending"}
      changeset = Task.transition_changeset(task, "deleted")
      assert changeset.valid?
    end

    test "in_progress → completed is valid" do
      task = %Task{status: "in_progress"}
      changeset = Task.transition_changeset(task, "completed")
      assert changeset.valid?
    end

    test "in_progress → blocked is valid" do
      task = %Task{status: "in_progress"}
      changeset = Task.transition_changeset(task, "blocked")
      assert changeset.valid?
    end

    test "in_progress → deleted is valid" do
      task = %Task{status: "in_progress"}
      changeset = Task.transition_changeset(task, "deleted")
      assert changeset.valid?
    end

    test "blocked → in_progress is valid" do
      task = %Task{status: "blocked"}
      changeset = Task.transition_changeset(task, "in_progress")
      assert changeset.valid?
    end

    test "pending → completed is invalid" do
      task = %Task{status: "pending"}
      changeset = Task.transition_changeset(task, "completed")
      refute changeset.valid?
    end

    test "completed → in_progress is invalid" do
      task = %Task{status: "completed"}
      changeset = Task.transition_changeset(task, "in_progress")
      refute changeset.valid?
    end

    test "blocked → completed is invalid" do
      task = %Task{status: "blocked"}
      changeset = Task.transition_changeset(task, "completed")
      refute changeset.valid?
    end

    test "invalid target status returns error" do
      task = %Task{status: "pending"}
      changeset = Task.transition_changeset(task, "flying")
      refute changeset.valid?
    end

    test "idempotent: same → same is valid" do
      for status <- Task.statuses() do
        task = %Task{status: status}
        changeset = Task.transition_changeset(task, status)
        assert changeset.valid?, "Expected #{status} → #{status} to be valid"
      end
    end
  end

  describe "Task.valid_transition?/2" do
    test "all defined transitions are valid" do
      valid = [
        {"pending", "in_progress"},
        {"pending", "deleted"},
        {"in_progress", "completed"},
        {"in_progress", "blocked"},
        {"in_progress", "deleted"},
        {"blocked", "in_progress"}
      ]

      for {from, to} <- valid do
        assert Task.valid_transition?(from, to), "Expected #{from} → #{to} to be valid"
      end
    end

    test "disallowed transitions are invalid" do
      invalid = [
        {"pending", "completed"},
        {"pending", "blocked"},
        {"completed", "in_progress"},
        {"completed", "pending"},
        {"blocked", "completed"},
        {"blocked", "deleted"},
        {"deleted", "pending"},
        {"deleted", "in_progress"}
      ]

      for {from, to} <- invalid do
        refute Task.valid_transition?(from, to), "Expected #{from} → #{to} to be invalid"
      end
    end

    test "same → same is always valid" do
      for status <- Task.statuses() do
        assert Task.valid_transition?(status, status)
      end
    end
  end

  # -----------------------------------------------------------------
  # Helpers
  # -----------------------------------------------------------------

  defp create_plan do
    attrs = %{
      session_id: @valid_attrs.session_id,
      mode: "nano",
      status: "approved",
      user_request: "test plan",
      plan_markdown: "# Plan",
      execution_prompt: "do it",
      project_snapshot_hash: "abc123"
    }

    KiroCockpit.Plans.create_plan(
      attrs.session_id,
      attrs.user_request,
      attrs.mode,
      [],
      plan_markdown: attrs.plan_markdown,
      execution_prompt: attrs.execution_prompt,
      project_snapshot_hash: attrs.project_snapshot_hash
    )
  end
end
