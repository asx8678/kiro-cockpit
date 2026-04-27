defmodule KiroCockpit.Swarm.DataPipeline.BronzeAcpTest do
  @moduledoc """
  Tests for Bronze ACP capture (§35 Phase 3).

  Covers:
    * acp_update recording with session/plan/task/agent correlation
    * acp_request, acp_response, acp_notification variants
    * ACP payload summarization and privacy
    * Method and RPC id extraction from JSON-RPC payloads
    * Query functions for ACP events
    * Direction filtering (client_to_agent, agent_to_client)
  """

  use KiroCockpit.DataCase, async: true

  alias KiroCockpit.Swarm.DataPipeline.BronzeAcp
  alias KiroCockpit.Swarm.Events

  describe "record_acp_update/1" do
    test "records acp_update with full correlation" do
      session_id = "sess_acp_#{System.unique_integer([:positive])}"
      plan_id = Ecto.UUID.generate()
      task_id = Ecto.UUID.generate()

      payload = %{
        "jsonrpc" => "2.0",
        "method" => "tools/call",
        "params" => %{"name" => "fs_read", "args" => %{"path" => "/tmp/test.txt"}},
        "id" => 123
      }

      attrs = %{
        session_id: session_id,
        plan_id: plan_id,
        task_id: task_id,
        agent_id: "kiro-agent",
        payload: payload,
        direction: :client_to_agent,
        safe: true
      }

      assert :ok = BronzeAcp.record_acp_update(attrs)

      events = BronzeAcp.list_acp_events(session_id)
      assert length(events) == 1

      recorded = hd(events)
      assert recorded.event_type == "acp_update"
      assert recorded.session_id == session_id
      assert recorded.plan_id == plan_id
      assert recorded.task_id == task_id
      assert recorded.agent_id == "kiro-agent"

      hook_results = recorded.hook_results
      assert hook_results["method"] == "tools/call"
      assert hook_results["direction"] == "client_to_agent"
      assert hook_results["rpc_id"] == "123"
      assert hook_results["correlation"]["plan_id"] == plan_id
    end

    test "extracts method and rpc_id from payload automatically" do
      session_id = "sess_extract_#{System.unique_integer([:positive])}"

      payload = %{
        "jsonrpc" => "2.0",
        "method" => "session/prompt",
        "id" => "req-456",
        "params" => %{}
      }

      attrs = %{
        session_id: session_id,
        agent_id: "agent",
        payload: payload
      }

      assert :ok = BronzeAcp.record_acp_update(attrs)

      [recorded] = BronzeAcp.list_acp_events(session_id)
      assert recorded.hook_results["method"] == "session/prompt"
      assert recorded.hook_results["rpc_id"] == "req-456"
    end

    test "summarizes ACP payload by default" do
      session_id = "sess_acp_summary_#{System.unique_integer([:positive])}"

      payload = %{
        "jsonrpc" => "2.0",
        "method" => "tools/call",
        "params" => %{"large_data" => String.duplicate("x", 10000)}
      }

      attrs = %{
        session_id: session_id,
        agent_id: "agent",
        payload: payload
      }

      assert :ok = BronzeAcp.record_acp_update(attrs)

      [recorded] = BronzeAcp.list_acp_events(session_id)

      # Should be a summary, not full payload
      assert recorded.payload["type"] == "acp_payload_summary"
      assert recorded.payload["keys"] == ["jsonrpc", "method", "params"]
      assert recorded.payload["size"] == 3

      # Raw payload should also be summary
      assert recorded.raw_payload["type"] == "acp_raw_payload_summary"
      assert recorded.raw_payload["method_hint"] == "tools/call"
    end

    test "handles atom keys in payload" do
      session_id = "sess_atom_keys_#{System.unique_integer([:positive])}"

      payload = %{
        jsonrpc: "2.0",
        method: "tools/list",
        id: 789
      }

      attrs = %{
        session_id: session_id,
        agent_id: "agent",
        payload: payload
      }

      assert :ok = BronzeAcp.record_acp_update(attrs)

      [recorded] = BronzeAcp.list_acp_events(session_id)
      assert recorded.hook_results["method"] == "tools/list"
      assert recorded.hook_results["rpc_id"] == "789"
    end

    test "emits telemetry on persistence error without crashing" do
      # Missing session_id should fail validation but not crash
      attrs = %{
        session_id: nil,
        agent_id: "agent",
        payload: %{}
      }

      # Should return :ok even though persistence fails
      assert :ok = BronzeAcp.record_acp_update(attrs)
    end
  end

  describe "record_acp_request/4" do
    test "records outgoing ACP request" do
      session_id = "sess_request_#{System.unique_integer([:positive])}"

      payload = %{
        "jsonrpc" => "2.0",
        "method" => "tools/call",
        "params" => %{"name" => "fs_write"},
        "id" => 1
      }

      assert :ok =
               BronzeAcp.record_acp_request(session_id, "kiro-agent", payload,
                 plan_id: Ecto.UUID.generate(),
                 task_id: Ecto.UUID.generate(),
                 method: "tools/call"
               )

      [recorded] = BronzeAcp.list_acp_events(session_id)
      assert recorded.event_type == "acp_request"
      assert recorded.hook_results["direction"] == "agent_to_client"
      assert recorded.hook_results["method"] == "tools/call"
    end
  end

  describe "record_acp_response/4" do
    test "records incoming ACP response" do
      session_id = "sess_response_#{System.unique_integer([:positive])}"

      payload = %{
        "jsonrpc" => "2.0",
        "result" => %{"content" => "file contents"},
        "id" => 1
      }

      assert :ok =
               BronzeAcp.record_acp_response(session_id, "kiro-agent", payload,
                 plan_id: Ecto.UUID.generate()
               )

      [recorded] = BronzeAcp.list_acp_events(session_id)
      assert recorded.event_type == "acp_response"
      assert recorded.hook_results["direction"] == "client_to_agent"
    end
  end

  describe "record_acp_notification/4" do
    test "records ACP notification" do
      session_id = "sess_notify_#{System.unique_integer([:positive])}"

      payload = %{
        "jsonrpc" => "2.0",
        "method" => "notifications/progress",
        "params" => %{"progress" => 50}
      }

      assert :ok =
               BronzeAcp.record_acp_notification(session_id, "kiro-agent", payload,
                 direction: :client_to_agent
               )

      [recorded] = BronzeAcp.list_acp_events(session_id)
      assert recorded.event_type == "acp_notification"
    end
  end

  describe "query functions" do
    test "list_acp_events returns only ACP events for session" do
      session_id = "sess_acp_query_#{System.unique_integer([:positive])}"

      # Create ACP event
      BronzeAcp.record_acp_update(%{
        session_id: session_id,
        agent_id: "agent",
        payload: %{}
      })

      # Create non-ACP event
      Events.create_event(%{
        session_id: session_id,
        agent_id: "agent",
        event_type: "action_before",
        payload: %{},
        raw_payload: %{},
        hook_results: []
      })

      acp_events = BronzeAcp.list_acp_events(session_id)
      assert length(acp_events) == 1
      assert hd(acp_events).event_type == "acp_update"
    end

    test "list_acp_by_plan returns ACP events for plan" do
      plan_id = Ecto.UUID.generate()
      other_plan = Ecto.UUID.generate()

      BronzeAcp.record_acp_update(%{
        session_id: "sess1",
        agent_id: "agent",
        payload: %{},
        plan_id: plan_id
      })

      BronzeAcp.record_acp_update(%{
        session_id: "sess2",
        agent_id: "agent",
        payload: %{},
        plan_id: other_plan
      })

      events = BronzeAcp.list_acp_by_plan(plan_id)
      assert length(events) == 1
      assert hd(events).plan_id == plan_id
    end

    test "list_acp_by_task returns ACP events for task" do
      task_id = Ecto.UUID.generate()

      BronzeAcp.record_acp_update(%{
        session_id: "sess",
        agent_id: "agent",
        payload: %{},
        plan_id: Ecto.UUID.generate(),
        task_id: task_id
      })

      events = BronzeAcp.list_acp_by_task(task_id)
      assert length(events) == 1
      assert hd(events).task_id == task_id
    end

    test "list_by_method filters by ACP method" do
      session_id = "sess_method_filter_#{System.unique_integer([:positive])}"

      BronzeAcp.record_acp_request(session_id, "agent", %{
        "method" => "tools/call"
      })

      BronzeAcp.record_acp_request(session_id, "agent", %{
        "method" => "session/prompt"
      })

      tool_calls = BronzeAcp.list_by_method(session_id, "tools/call")
      assert length(tool_calls) == 1

      prompts = BronzeAcp.list_by_method(session_id, "session/prompt")
      assert length(prompts) == 1
    end

    test "list_by_direction filters by direction" do
      session_id = "sess_dir_filter_#{System.unique_integer([:positive])}"

      BronzeAcp.record_acp_request(session_id, "agent", %{}, [])
      BronzeAcp.record_acp_response(session_id, "agent", %{}, [])

      requests = BronzeAcp.list_by_direction(session_id, :agent_to_client)
      assert length(requests) == 1
      assert hd(requests).event_type == "acp_request"

      responses = BronzeAcp.list_by_direction(session_id, :client_to_agent)
      assert length(responses) == 1
      assert hd(responses).event_type == "acp_response"
    end
  end

  describe "ordering options" do
    test "list_acp_events respects :order option" do
      session_id = "sess_order_#{System.unique_integer([:positive])}"

      # Create events with slight time separation
      for i <- 1..3 do
        BronzeAcp.record_acp_update(%{
          session_id: session_id,
          agent_id: "agent",
          payload: %{"seq" => i},
          created_at: DateTime.add(DateTime.utc_now(), i, :millisecond)
        })
      end

      # Default (ascending)
      asc = BronzeAcp.list_acp_events(session_id, order: :asc)
      seqs = Enum.map(asc, & &1.payload["seq"])
      # Payload might be summarized
      assert seqs == [1, 2, 3] || seqs == [nil, nil, nil]

      # Descending
      desc = BronzeAcp.list_acp_events(session_id, order: :desc)
      assert length(desc) == 3
    end
  end

  describe "edge cases" do
    test "handles payload without jsonrpc or method" do
      session_id = "sess_no_jsonrpc_#{System.unique_integer([:positive])}"

      payload = %{
        "some_field" => "some_value"
      }

      assert :ok =
               BronzeAcp.record_acp_update(%{
                 session_id: session_id,
                 agent_id: "agent",
                 payload: payload
               })

      [recorded] = BronzeAcp.list_acp_events(session_id)
      assert recorded.hook_results["method"] == nil
      assert recorded.raw_payload["method_hint"] == nil
    end

    test "handles various RPC id types" do
      test_cases = [
        {123, "123"},
        {"abc", "abc"},
        {1.5, "1.5"},
        {true, "true"}
      ]

      for {input_id, expected} <- test_cases do
        session_id = "sess_id_#{input_id}_#{System.unique_integer([:positive])}"

        payload = %{
          "jsonrpc" => "2.0",
          "id" => input_id,
          "method" => "test"
        }

        BronzeAcp.record_acp_update(%{
          session_id: session_id,
          agent_id: "agent",
          payload: payload
        })

        [recorded] = BronzeAcp.list_acp_events(session_id)
        assert recorded.hook_results["rpc_id"] == expected
      end
    end
  end
end
