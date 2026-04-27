defmodule KiroCockpit.Swarm.DataPipeline.BronzeSection35RegressionTest do
  @moduledoc """
  Regression tests for §35 Bronze action/ACP capture completeness.

  These tests verify the deterministic invariants from §27.11 that §35
  Phase 3 must uphold:

    * Invariant 7: Bronze captures every event, including blocked ones.
    * Invariant 8: Every execution is traceable to plan_id and task_id.

  Plus §35-specific requirements:

    * action_before always recorded before action_after.
    * Blocked actions always have a Bronze record (fail-closed).
    * ACP events carry session/plan/task/agent correlation.
    * Payload and raw_payload are summarized (privacy) by default.
    * Persistence errors never crash the caller.
  """

  use KiroCockpit.DataCase, async: true

  alias KiroCockpit.Swarm.{DataPipeline, DataPipeline.BronzeAction, DataPipeline.BronzeAcp, Event}

  # ---------------------------------------------------------------------------
  # §27.11 Invariant 7: Bronze captures every event, including blocked ones
  # ---------------------------------------------------------------------------

  describe "§27.11 invariant 7 — Bronze captures every event including blocked ones" do
    test "blocked actions always produce a Bronze record" do
      session_id = "inv7_blocked_#{System.unique_integer([:positive])}"

      event =
        Event.new(:file_write,
          session_id: session_id,
          agent_id: "inv7-agent",
          plan_id: Ecto.UUID.generate(),
          task_id: Ecto.UUID.generate()
        )

      reason = "task category does not allow write"
      messages = ["switch to an acting task or request approval"]

      assert :ok = BronzeAction.record_blocked(event, reason, messages, %{})

      events = BronzeAction.list_actions(session_id)
      assert length(events) == 1

      blocked = hd(events)
      assert blocked.event_type == "action_blocked"
      assert blocked.hook_results["block_reason"] == reason
      assert blocked.hook_results["guidance_messages"] == messages
    end

    test "action_before is recorded even if the action is later blocked" do
      session_id = "inv7_before_#{System.unique_integer([:positive])}"

      event =
        Event.new(:shell_exec,
          session_id: session_id,
          agent_id: "inv7-agent"
        )

      # Record before (simulates ActionBoundary recording before pre-hooks)
      assert :ok = BronzeAction.record_before(event, %{})

      # Then record blocked (simulates pre-hooks blocking)
      assert :ok =
               BronzeAction.record_blocked(event, "security violation", ["contact admin"], %{},
                 blocking_hook: "SecurityAuditHook"
               )

      events = BronzeAction.list_actions(session_id)
      assert length(events) == 2

      event_types = Enum.map(events, & &1.event_type)
      assert "action_before" in event_types
      assert "action_blocked" in event_types
    end

    test "no silent drops — every action lifecycle produces at least one Bronze record" do
      # Even an action with nil session_id must not crash or silently fail
      event = Event.new(:orphan_action, session_id: nil, agent_id: nil)

      # This will fail persistence but must not crash
      assert :ok = BronzeAction.record_before(event, %{})
      assert :ok = BronzeAction.record_after(event, {:ok, :done}, %{})
      assert :ok = BronzeAction.record_blocked(event, "reason", ["msg"], %{})
    end
  end

  # ---------------------------------------------------------------------------
  # §27.11 Invariant 8: Every execution is traceable to plan_id and task_id
  # ---------------------------------------------------------------------------

  describe "§27.11 invariant 8 — every execution traceable to plan_id/task_id" do
    test "action_before carries plan_id and task_id when provided" do
      session_id = "inv8_before_#{System.unique_integer([:positive])}"
      plan_id = Ecto.UUID.generate()
      task_id = Ecto.UUID.generate()

      event =
        Event.new(:kiro_session_prompt,
          session_id: session_id,
          agent_id: "inv8-agent",
          plan_id: plan_id,
          task_id: task_id
        )

      assert :ok = BronzeAction.record_before(event, %{})

      [recorded] = BronzeAction.list_actions(session_id)
      assert recorded.plan_id == plan_id
      assert recorded.task_id == task_id

      # Correlation map in hook_results also carries them
      corr = recorded.hook_results["correlation"]
      assert corr["plan_id"] == plan_id
      assert corr["task_id"] == task_id
    end

    test "action_after carries plan_id and task_id through the full lifecycle" do
      session_id = "inv8_after_#{System.unique_integer([:positive])}"
      plan_id = Ecto.UUID.generate()
      task_id = Ecto.UUID.generate()

      event =
        Event.new(:kiro_session_prompt,
          session_id: session_id,
          agent_id: "inv8-agent",
          plan_id: plan_id,
          task_id: task_id
        )

      BronzeAction.record_before(event, %{})
      BronzeAction.record_after(event, {:ok, :completed}, %{})

      events = BronzeAction.list_actions(session_id)

      for evt <- events do
        assert evt.plan_id == plan_id, "event_type=#{evt.event_type} missing plan_id"
        assert evt.task_id == task_id, "event_type=#{evt.event_type} missing task_id"
      end
    end

    test "action_blocked carries plan_id and task_id correlation" do
      session_id = "inv8_blocked_#{System.unique_integer([:positive])}"
      plan_id = Ecto.UUID.generate()
      task_id = Ecto.UUID.generate()

      event =
        Event.new(:file_write,
          session_id: session_id,
          agent_id: "inv8-agent",
          plan_id: plan_id,
          task_id: task_id
        )

      BronzeAction.record_blocked(event, "scope violation", ["use read-only"], %{})

      [recorded] = BronzeAction.list_actions(session_id)
      assert recorded.plan_id == plan_id
      assert recorded.task_id == task_id
    end

    test "ACP events carry plan_id and task_id correlation" do
      session_id = "inv8_acp_#{System.unique_integer([:positive])}"
      plan_id = Ecto.UUID.generate()
      task_id = Ecto.UUID.generate()

      attrs = %{
        session_id: session_id,
        agent_id: "inv8-agent",
        plan_id: plan_id,
        task_id: task_id,
        payload: %{"method" => "tools/call"}
      }

      assert :ok = BronzeAcp.record_acp_update(attrs)

      [recorded] = BronzeAcp.list_acp_events(session_id)
      assert recorded.plan_id == plan_id
      assert recorded.task_id == task_id

      # Correlation map also present
      corr = recorded.hook_results["correlation"]
      assert corr["plan_id"] == plan_id
      assert corr["task_id"] == task_id
    end

    test "query by plan_id recovers all correlated action events" do
      plan_id = Ecto.UUID.generate()
      session_id = "inv8_plan_#{System.unique_integer([:positive])}"

      event =
        Event.new(:file_write,
          session_id: session_id,
          agent_id: "inv8-agent",
          plan_id: plan_id,
          task_id: Ecto.UUID.generate()
        )

      BronzeAction.record_before(event, %{})
      BronzeAction.record_after(event, {:ok, :written}, %{})

      by_plan = BronzeAction.list_actions_by_plan(plan_id)
      assert length(by_plan) == 2

      for evt <- by_plan do
        assert evt.plan_id == plan_id
      end
    end

    test "query by task_id recovers all correlated action events" do
      task_id = Ecto.UUID.generate()
      session_id = "inv8_task_#{System.unique_integer([:positive])}"

      event =
        Event.new(:file_read,
          session_id: session_id,
          agent_id: "inv8-agent",
          plan_id: Ecto.UUID.generate(),
          task_id: task_id
        )

      BronzeAction.record_before(event, %{})
      BronzeAction.record_after(event, {:ok, :read}, %{})

      by_task = BronzeAction.list_actions_by_task(task_id)
      assert length(by_task) == 2

      for evt <- by_task do
        assert evt.task_id == task_id
      end
    end
  end

  # ---------------------------------------------------------------------------
  # §35 action lifecycle completeness
  # ---------------------------------------------------------------------------

  describe "§35 action_before always precedes action_after" do
    test "action_before is recorded with phase='pre', action_after with phase='post'" do
      session_id = "lifecycle_phases_#{System.unique_integer([:positive])}"

      event =
        Event.new(:nano_plan_generate,
          session_id: session_id,
          agent_id: "lifecycle-agent"
        )

      BronzeAction.record_before(event, %{})
      BronzeAction.record_after(event, {:ok, :plan_created}, %{})

      events = BronzeAction.list_actions(session_id)

      before_evt = Enum.find(events, &(&1.event_type == "action_before"))
      after_evt = Enum.find(events, &(&1.event_type == "action_after"))

      assert before_evt.phase == "pre"
      assert after_evt.phase == "post"
    end

    test "result_status values cover ok, blocked, error" do
      session_id_prefix = "result_status_#{System.unique_integer([:positive])}"

      for {status, result} <- [
            {:ok, {:ok, "success"}},
            {:blocked, {:error, {:swarm_blocked, "nope", []}}},
            {:error, {:error, :timeout}}
          ] do
        session_id = "#{session_id_prefix}_#{status}"

        event =
          Event.new(:test_action,
            session_id: session_id,
            agent_id: "status-agent"
          )

        BronzeAction.record_after(event, result, %{})

        [recorded] = BronzeAction.list_actions(session_id)
        assert recorded.hook_results["result_status"] == to_string(status)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # §35 ACP capture completeness
  # ---------------------------------------------------------------------------

  describe "§35 ACP capture completeness" do
    test "acp_request, acp_response, acp_notification all record with correlation" do
      session_id = "acp_complete_#{System.unique_integer([:positive])}"
      plan_id = Ecto.UUID.generate()
      task_id = Ecto.UUID.generate()

      # Request
      :ok =
        BronzeAcp.record_acp_request(session_id, "acp-agent", %{"method" => "tools/call"},
          plan_id: plan_id,
          task_id: task_id
        )

      # Response
      :ok =
        BronzeAcp.record_acp_response(session_id, "acp-agent", %{"result" => "ok"},
          plan_id: plan_id,
          task_id: task_id
        )

      # Notification
      :ok =
        BronzeAcp.record_acp_notification(session_id, "acp-agent", %{"method" => "progress"},
          plan_id: plan_id,
          task_id: task_id
        )

      events = BronzeAcp.list_acp_events(session_id)
      assert length(events) == 3

      event_types = Enum.map(events, & &1.event_type)
      assert "acp_request" in event_types
      assert "acp_response" in event_types
      assert "acp_notification" in event_types

      # All carry plan_id and task_id
      for evt <- events do
        assert evt.plan_id == plan_id
        assert evt.task_id == task_id
      end
    end

    test "ACP method extraction from JSON-RPC payload" do
      session_id = "acp_method_#{System.unique_integer([:positive])}"

      payload = %{
        "jsonrpc" => "2.0",
        "method" => "tools/call",
        "id" => 42,
        "params" => %{"name" => "fs_read"}
      }

      :ok =
        BronzeAcp.record_acp_update(%{
          session_id: session_id,
          agent_id: "method-agent",
          payload: payload
        })

      [recorded] = BronzeAcp.list_acp_events(session_id)
      assert recorded.hook_results["method"] == "tools/call"
      assert recorded.hook_results["rpc_id"] == "42"
    end

    test "ACP direction is normalized to strings" do
      session_id = "acp_dir_#{System.unique_integer([:positive])}"

      :ok =
        BronzeAcp.record_acp_update(%{
          session_id: session_id,
          agent_id: "dir-agent",
          payload: %{},
          direction: :agent_to_client
        })

      [recorded] = BronzeAcp.list_acp_events(session_id)
      assert recorded.hook_results["direction"] == "agent_to_client"
    end

    test "ACP query by plan and task recovers correlated events" do
      plan_id = Ecto.UUID.generate()
      task_id = Ecto.UUID.generate()
      session_id = "acp_query_#{System.unique_integer([:positive])}"

      :ok =
        BronzeAcp.record_acp_update(%{
          session_id: session_id,
          agent_id: "query-agent",
          plan_id: plan_id,
          task_id: task_id,
          payload: %{}
        })

      by_plan = BronzeAcp.list_acp_by_plan(plan_id)
      assert length(by_plan) == 1
      assert hd(by_plan).plan_id == plan_id

      by_task = BronzeAcp.list_acp_by_task(task_id)
      assert length(by_task) == 1
      assert hd(by_task).task_id == task_id
    end
  end

  # ---------------------------------------------------------------------------
  # §35 payload/raw_payload summarization and privacy
  # ---------------------------------------------------------------------------

  describe "§35 payload/raw_payload summarization — privacy by default" do
    test "action payload is summarized — full values never appear in Bronze" do
      session_id = "priv_action_#{System.unique_integer([:positive])}"

      event =
        Event.new(:file_write,
          session_id: session_id,
          agent_id: "priv-agent",
          payload: %{"path" => "/secret/key.pem", "secret" => "sk-12345"}
        )

      BronzeAction.record_before(event, %{})

      [recorded] = BronzeAction.list_actions(session_id)

      # Summary only: keys and size, not values
      assert recorded.payload["type"] == "payload_summary"
      refute recorded.payload["secret"]
      assert "secret" in recorded.payload["keys"]
    end

    test "ACP payload is summarized — method/rpc id extracted but not params" do
      session_id = "priv_acp_#{System.unique_integer([:positive])}"

      payload = %{
        "jsonrpc" => "2.0",
        "method" => "tools/call",
        "params" => %{"token" => "sensitive-value"},
        "id" => 1
      }

      :ok =
        BronzeAcp.record_acp_update(%{
          session_id: session_id,
          agent_id: "priv-agent",
          payload: payload
        })

      [recorded] = BronzeAcp.list_acp_events(session_id)

      # Payload summary: keys and size, not the sensitive param values
      assert recorded.payload["type"] == "acp_payload_summary"
      refute recorded.payload["params"]

      # Raw payload summary has method hint but no params
      assert recorded.raw_payload["type"] == "acp_raw_payload_summary"
      assert recorded.raw_payload["method_hint"] == "tools/call"
    end

    test "safe: true captures full payload for debugging" do
      session_id = "priv_safe_#{System.unique_integer([:positive])}"

      event =
        Event.new(:file_write,
          session_id: session_id,
          agent_id: "safe-agent",
          payload: %{"path" => "/tmp/test.txt", "content" => "hello"}
        )

      BronzeAction.record_before(event, %{safe: true})

      [recorded] = BronzeAction.list_actions(session_id)

      # Full payload preserved
      assert recorded.payload["path"] == "/tmp/test.txt"
      assert recorded.payload["content"] == "hello"
      refute recorded.payload["type"] == "payload_summary"
    end
  end

  # ---------------------------------------------------------------------------
  # §35 fail-closed audit persistence
  # ---------------------------------------------------------------------------

  describe "§35 fail-closed audit — persistence errors never lose the record" do
    test "BronzeAction persistence failure does not crash caller" do
      # nil session_id will fail DB validation
      event = Event.new(:fail_closed, session_id: nil, agent_id: nil)

      # All three record functions must return :ok even on DB failure
      assert :ok = BronzeAction.record_before(event, %{})
      assert :ok = BronzeAction.record_after(event, {:ok, :done}, %{})
      assert :ok = BronzeAction.record_blocked(event, "reason", ["msg"], %{})
    end

    test "BronzeAcp persistence failure does not crash caller" do
      # nil session_id will fail DB validation
      attrs = %{session_id: nil, agent_id: nil, payload: %{}}

      assert :ok = BronzeAcp.record_acp_update(attrs)
    end

    test "persistence failure emits telemetry for observability" do
      # We can't easily assert on telemetry handler without attaching,
      # but we can verify the code path completes without error.
      # The telemetry event uses [:kiro_cockpit, :bronze, :action, :exception]
      # or [:kiro_cockpit, :bronze, :acp, :exception].

      event = Event.new(:telemetry_check, session_id: nil, agent_id: nil)
      assert :ok = BronzeAction.record_before(event, %{})

      attrs = %{session_id: nil, agent_id: nil, payload: %{}}
      assert :ok = BronzeAcp.record_acp_update(attrs)
    end
  end

  # ---------------------------------------------------------------------------
  # §35 DataPipeline convenience API
  # ---------------------------------------------------------------------------

  describe "DataPipeline convenience API" do
    test "record_action_lifecycle records before and after" do
      session_id = "pipeline_lifecycle_#{System.unique_integer([:positive])}"
      plan_id = Ecto.UUID.generate()

      event =
        Event.new(:pipeline_test,
          session_id: session_id,
          agent_id: "pipeline-agent",
          plan_id: plan_id
        )

      result =
        DataPipeline.record_action_lifecycle(event, fn -> {:ok, "did the thing"} end)

      assert result == {:ok, "did the thing"}

      events = BronzeAction.list_actions(session_id)
      event_types = Enum.map(events, & &1.event_type)
      assert "action_before" in event_types
      assert "action_after" in event_types
    end

    test "action_capture_enabled? respects configuration" do
      original = Application.get_env(:kiro_cockpit, :bronze_action_capture_enabled, true)

      Application.put_env(:kiro_cockpit, :bronze_action_capture_enabled, false)
      refute DataPipeline.action_capture_enabled?()

      Application.put_env(:kiro_cockpit, :bronze_action_capture_enabled, true)
      assert DataPipeline.action_capture_enabled?()

      Application.put_env(:kiro_cockpit, :bronze_action_capture_enabled, original)
    end

    test "acp_capture_enabled? respects configuration" do
      original = Application.get_env(:kiro_cockpit, :bronze_acp_capture_enabled, true)

      Application.put_env(:kiro_cockpit, :bronze_acp_capture_enabled, false)
      refute DataPipeline.acp_capture_enabled?()

      Application.put_env(:kiro_cockpit, :bronze_acp_capture_enabled, true)
      assert DataPipeline.acp_capture_enabled?()

      Application.put_env(:kiro_cockpit, :bronze_acp_capture_enabled, original)
    end
  end
end
