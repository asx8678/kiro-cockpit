defmodule KiroCockpit.Swarm.EventsTest do
  @moduledoc """
  Exercises the Bronze swarm event surface (plan2.md §27.10, §27.11, §34.2).

  Covers:

    * full-correlation create round-trip,
    * blocked event capture with `hook_results` (§27.11 inv. 7),
    * `list_by_session` / `list_by_plan` / `list_by_task` correlation queries
      (§27.11 inv. 8),
    * default values for payload / raw_payload / hook_results,
    * required-field and shape validation errors,
    * unique primary key invariant.
  """

  use KiroCockpit.DataCase, async: true

  alias KiroCockpit.Swarm.Events
  alias KiroCockpit.Swarm.Events.SwarmEvent

  defp base_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        session_id: "sess_swarm_#{System.unique_integer([:positive])}",
        agent_id: "kiro-executor",
        event_type: "action_before",
        phase: "pre"
      },
      overrides
    )
  end

  describe "create_event/1" do
    test "persists a Bronze event with full plan/task/agent correlation" do
      session_id = "sess_full_correlation"
      plan_id = Ecto.UUID.generate()
      task_id = Ecto.UUID.generate()
      occurred_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      payload = %{
        "action_name" => "kiro_session_prompt",
        "permission_level" => "write",
        "input_summary" => "create OAuth callback",
        "output_summary" => "applied"
      }

      raw_payload = %{
        "jsonrpc" => "2.0",
        "method" => "session/prompt",
        "params" => %{"prompt" => "create OAuth callback"}
      }

      hook_results = [
        %{"hook" => "task_enforcement", "decision" => "continue"},
        %{"hook" => "steering_pre_action", "decision" => "continue"}
      ]

      assert {:ok, %SwarmEvent{} = event} =
               Events.create_event(%{
                 session_id: session_id,
                 plan_id: plan_id,
                 task_id: task_id,
                 agent_id: "kiro-executor",
                 event_type: "action_before",
                 phase: "pre",
                 payload: payload,
                 raw_payload: raw_payload,
                 hook_results: hook_results,
                 created_at: occurred_at
               })

      assert event.session_id == session_id
      assert event.plan_id == plan_id
      assert event.task_id == task_id
      assert event.agent_id == "kiro-executor"
      assert event.event_type == "action_before"
      assert event.phase == "pre"
      assert event.payload == payload
      assert event.raw_payload == raw_payload
      assert event.hook_results == hook_results
      assert event.created_at == occurred_at

      # Round-trip via Repo.get to confirm correlation IDs survive persistence.
      reloaded = Events.get_event!(event.id)
      assert reloaded.plan_id == plan_id
      assert reloaded.task_id == task_id
      assert reloaded.session_id == session_id
      assert reloaded.agent_id == "kiro-executor"
    end

    test "captures a blocked event with structured hook_results (§27.11 inv. 7)" do
      session_id = "sess_blocked"
      plan_id = Ecto.UUID.generate()
      task_id = Ecto.UUID.generate()

      hook_results = [
        %{
          "hook" => "task_enforcement",
          "decision" => "block",
          "reason" => "no active task",
          "guidance" => "create a task before invoking write tools"
        }
      ]

      assert {:ok, event} =
               Events.create_event(
                 base_attrs(%{
                   session_id: session_id,
                   plan_id: plan_id,
                   task_id: task_id,
                   event_type: "action_blocked",
                   phase: "pre",
                   payload: %{"action_name" => "shell_write"},
                   raw_payload: %{"method" => "shell/exec"},
                   hook_results: hook_results
                 })
               )

      assert event.event_type == "action_blocked"
      assert event.hook_results == hook_results

      # Bronze captures blocked rows: list_by_task returns it.
      assert [listed] = Events.list_by_task(task_id)
      assert listed.id == event.id
      assert listed.event_type == "action_blocked"
    end

    test "accepts hook_results as a map shape" do
      hook_results = %{"summary" => "all hooks continued", "count" => 3}

      assert {:ok, event} =
               Events.create_event(base_attrs(%{hook_results: hook_results}))

      assert event.hook_results == hook_results
    end

    test "applies defaults for payload, raw_payload, hook_results, and created_at" do
      before_create = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      assert {:ok, event} = Events.create_event(base_attrs())

      assert event.payload == %{}
      assert event.raw_payload == %{}
      assert event.hook_results == []
      assert event.created_at != nil
      assert DateTime.compare(event.created_at, before_create) in [:gt, :eq]
    end

    test "creates events that are independent of plan_id/task_id (Bronze captures everything)" do
      assert {:ok, event} = Events.create_event(base_attrs())
      assert event.plan_id == nil
      assert event.task_id == nil
      # Even uncorrelated events are persisted: Bronze never silently drops.
      reloaded = Events.get_event(event.id)
      assert reloaded.id == event.id
    end
  end

  describe "validation errors" do
    test "rejects missing required fields" do
      assert {:error, changeset} = Events.create_event(%{})

      errors = errors_on(changeset)
      assert "can't be blank" in errors.session_id
      assert "can't be blank" in errors.agent_id
      assert "can't be blank" in errors.event_type
    end

    test "rejects payload that is not a map" do
      assert {:error, changeset} =
               Events.create_event(base_attrs(%{payload: ["not", "a", "map"]}))

      assert "is invalid" in errors_on(changeset).payload
    end

    test "rejects raw_payload that is not a map" do
      assert {:error, changeset} =
               Events.create_event(base_attrs(%{raw_payload: "not a map"}))

      assert "is invalid" in errors_on(changeset).raw_payload
    end

    test "rejects hook_results that is neither map nor list" do
      assert {:error, changeset} =
               Events.create_event(base_attrs(%{hook_results: "neither map nor list"}))

      assert "is invalid" in errors_on(changeset).hook_results
    end

    test "rejects hook_results list with non-map entries" do
      assert {:error, changeset} =
               Events.create_event(base_attrs(%{hook_results: ["string", "entries"]}))

      assert "list entries must be maps" in errors_on(changeset).hook_results
    end

    test "rejects oversized session_id, agent_id, event_type, and phase" do
      too_long = String.duplicate("x", 256)
      too_long_phase = String.duplicate("x", 65)

      assert {:error, changeset} =
               Events.create_event(
                 base_attrs(%{
                   session_id: too_long,
                   agent_id: too_long,
                   event_type: too_long,
                   phase: too_long_phase
                 })
               )

      errors = errors_on(changeset)
      assert errors[:session_id] != nil
      assert errors[:agent_id] != nil
      assert errors[:event_type] != nil
      assert errors[:phase] != nil
    end
  end

  describe "list_by_session/2" do
    test "returns events for the session ordered by created_at and excludes others" do
      session_a = "sess_a_#{System.unique_integer([:positive])}"
      session_b = "sess_b_#{System.unique_integer([:positive])}"
      t0 = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      {:ok, e1} =
        Events.create_event(
          base_attrs(%{
            session_id: session_a,
            event_type: "action_before",
            created_at: t0
          })
        )

      {:ok, e2} =
        Events.create_event(
          base_attrs(%{
            session_id: session_a,
            event_type: "action_after",
            created_at: DateTime.add(t0, 1, :millisecond)
          })
        )

      {:ok, _other} = Events.create_event(base_attrs(%{session_id: session_b}))

      results = Events.list_by_session(session_a)
      assert Enum.map(results, & &1.id) == [e1.id, e2.id]
    end

    test "respects :limit option" do
      session_id = "sess_limit_#{System.unique_integer([:positive])}"

      for i <- 1..5 do
        {:ok, _} =
          Events.create_event(
            base_attrs(%{
              session_id: session_id,
              event_type: "evt_#{i}",
              created_at:
                DateTime.add(DateTime.utc_now(), i, :millisecond)
                |> DateTime.truncate(:microsecond)
            })
          )
      end

      assert length(Events.list_by_session(session_id, limit: 2)) == 2
    end

    test "returns desc order when :order is :desc" do
      session_id = "sess_desc_#{System.unique_integer([:positive])}"
      t0 = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      {:ok, e1} =
        Events.create_event(base_attrs(%{session_id: session_id, created_at: t0}))

      {:ok, e2} =
        Events.create_event(
          base_attrs(%{
            session_id: session_id,
            created_at: DateTime.add(t0, 5, :millisecond)
          })
        )

      assert [first, second] = Events.list_by_session(session_id, order: :desc)
      assert first.id == e2.id
      assert second.id == e1.id
    end
  end

  describe "list_by_plan/2 and list_by_task/2" do
    test "returns only the events filed against the given plan_id" do
      plan_a = Ecto.UUID.generate()
      plan_b = Ecto.UUID.generate()
      session_id = "sess_plan_#{System.unique_integer([:positive])}"

      {:ok, evt} =
        Events.create_event(base_attrs(%{session_id: session_id, plan_id: plan_a}))

      {:ok, _other_plan} =
        Events.create_event(base_attrs(%{session_id: session_id, plan_id: plan_b}))

      {:ok, _no_plan} = Events.create_event(base_attrs(%{session_id: session_id}))

      results = Events.list_by_plan(plan_a)
      assert length(results) == 1
      assert hd(results).id == evt.id
    end

    test "returns only the events filed against the given task_id" do
      task_a = Ecto.UUID.generate()
      task_b = Ecto.UUID.generate()
      session_id = "sess_task_#{System.unique_integer([:positive])}"

      {:ok, evt} =
        Events.create_event(base_attrs(%{session_id: session_id, task_id: task_a}))

      {:ok, _other_task} =
        Events.create_event(base_attrs(%{session_id: session_id, task_id: task_b}))

      {:ok, _no_task} = Events.create_event(base_attrs(%{session_id: session_id}))

      results = Events.list_by_task(task_a)
      assert length(results) == 1
      assert hd(results).id == evt.id
    end
  end

  describe "list_recent/1" do
    test "returns events newest-first by default" do
      session_id = "sess_recent_#{System.unique_integer([:positive])}"
      t0 = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      {:ok, e1} =
        Events.create_event(base_attrs(%{session_id: session_id, created_at: t0}))

      {:ok, e2} =
        Events.create_event(
          base_attrs(%{
            session_id: session_id,
            created_at: DateTime.add(t0, 10, :millisecond)
          })
        )

      assert [first | _rest] = Events.list_recent(session_id: session_id)
      assert first.id == e2.id

      ascending = Events.list_recent(session_id: session_id, order: :asc)
      assert Enum.map(ascending, & &1.id) == [e1.id, e2.id]
    end

    test "filters by event_type" do
      session_id = "sess_type_#{System.unique_integer([:positive])}"

      {:ok, blocked} =
        Events.create_event(
          base_attrs(%{
            session_id: session_id,
            event_type: "action_blocked",
            hook_results: [%{"decision" => "block"}]
          })
        )

      {:ok, _normal} =
        Events.create_event(base_attrs(%{session_id: session_id, event_type: "action_before"}))

      assert [only] =
               Events.list_recent(session_id: session_id, event_type: "action_blocked")

      assert only.id == blocked.id
    end
  end

  describe "schema invariants" do
    test "primary key uniqueness rejects duplicate explicit ids" do
      duplicate_id = Ecto.UUID.generate()

      first =
        %SwarmEvent{id: duplicate_id}
        |> SwarmEvent.changeset(base_attrs())

      assert {:ok, _row} = Repo.insert(first)

      second =
        %SwarmEvent{id: duplicate_id}
        |> SwarmEvent.changeset(base_attrs())

      assert_raise Ecto.ConstraintError, fn -> Repo.insert(second) end
    end

    test "jsonb shape check rejects an array payload at the database level" do
      # The schema-level changeset normally catches this, but we test the
      # database constraint directly to prove §27.10 invariants are enforced
      # even if a raw write ever bypasses the changeset.
      sql = """
      INSERT INTO swarm_events
        (id, session_id, agent_id, event_type, payload, raw_payload, hook_results, created_at)
      VALUES
        ($1, $2, $3, $4, $5, $6, $7, $8)
      """

      assert_raise Postgrex.Error, ~r/swarm_events_payload_object_check/, fn ->
        Ecto.Adapters.SQL.query!(Repo, sql, [
          Ecto.UUID.bingenerate(),
          "sess_raw",
          "agent",
          "evt",
          [1, 2, 3],
          %{},
          [],
          DateTime.utc_now() |> DateTime.truncate(:microsecond)
        ])
      end
    end

    test "jsonb shape check rejects a scalar hook_results at the database level" do
      sql = """
      INSERT INTO swarm_events
        (id, session_id, agent_id, event_type, payload, raw_payload, hook_results, created_at)
      VALUES
        ($1, $2, $3, $4, $5, $6, $7, $8)
      """

      assert_raise Postgrex.Error, ~r/swarm_events_hook_results_shape_check/, fn ->
        Ecto.Adapters.SQL.query!(Repo, sql, [
          Ecto.UUID.bingenerate(),
          "sess_raw",
          "agent",
          "evt",
          %{},
          %{},
          "not a map or list",
          DateTime.utc_now() |> DateTime.truncate(:microsecond)
        ])
      end
    end
  end
end
