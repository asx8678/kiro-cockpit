defmodule KiroCockpit.Swarm.SteeringAgentTest do
  use ExUnit.Case, async: true

  alias KiroCockpit.Swarm.SteeringAgent
  alias KiroCockpit.Swarm.SteeringAgent.Decision

  # -------------------------------------------------------------------
  # Fake steering model for testing
  # -------------------------------------------------------------------

  defmodule FakeModel do
    @moduledoc false
    def generate(_prompt, _opts) do
      # Tests can set the response via process dictionary
      response = Process.get(:fake_model_response)
      if response, do: {:ok, response}, else: {:error, "no response configured"}
    end
  end

  defmodule FailingModel do
    @moduledoc false
    def generate(_prompt, _opts) do
      {:error, "model unavailable"}
    end
  end

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp base_event do
    %{
      action_name: :write,
      session_id: "sess_1",
      agent_id: "agent_1",
      task_id: "task_1",
      plan_id: "plan_1",
      payload: %{target_path: "lib/foo.ex"}
    }
  end

  defp base_ctx do
    %{
      active_task: %{
        content: "Implement auth module",
        category: "acting",
        status: "in_progress",
        acceptance_criteria: ["Auth works end-to-end"],
        permission_scope: ["write"]
      },
      plan: %{phase: "execution", acceptance_criteria: ["All tests pass"]},
      project_rules: ["No external deps without approval"],
      gold_memories: ["mem_config_hot_reload_issue"]
    }
  end

  defp evaluate(event \\ base_event(), ctx \\ base_ctx(), opts \\ []) do
    default_opts = [steering_model: FakeModel]
    SteeringAgent.evaluate(event, ctx, Keyword.merge(default_opts, opts))
  end

  defp set_fake_response(response) do
    Process.put(:fake_model_response, response)
  end

  setup do
    Process.delete(:fake_model_response)
    Process.delete(:captured_prompt)
    :ok
  end

  # -------------------------------------------------------------------
  # JSON parsing and validation
  # -------------------------------------------------------------------

  describe "strip_json_fences/1" do
    test "passes through bare JSON" do
      json = ~s({"decision": "continue", "reason": "ok"})
      assert {:ok, ^json} = SteeringAgent.strip_json_fences(json)
    end

    test "strips ```json ... ``` fences" do
      inner = ~s({"decision": "continue", "reason": "ok"})
      fenced = "```json\n#{inner}\n```"
      assert {:ok, ^inner} = SteeringAgent.strip_json_fences(fenced)
    end

    test "strips ``` ... ``` fences without language tag" do
      inner = ~s({"decision": "focus", "reason": "drift"})
      fenced = "```\n#{inner}\n```"
      assert {:ok, ^inner} = SteeringAgent.strip_json_fences(fenced)
    end

    test "extracts JSON from surrounding text" do
      json = ~s({"decision": "continue", "reason": "aligned"})
      raw = "Here is my decision:\n#{json}\nEnd."
      assert {:ok, ^json} = SteeringAgent.strip_json_fences(raw)
    end

    test "returns error when no JSON found" do
      assert {:error, _} = SteeringAgent.strip_json_fences("no json here")
    end
  end

  describe "parse_and_validate — strict JSON parsing" do
    test "parses valid continue decision" do
      set_fake_response(~s({"decision": "continue", "reason": "On task", "risk_level": "low"}))

      assert {:ok,
              %Decision{decision: :continue, reason: "On task", risk_level: :low, source: :llm}} =
               evaluate()
    end

    test "parses valid focus decision" do
      set_fake_response(
        ~s({"decision": "focus", "reason": "Slight drift", "risk_level": "medium"})
      )

      assert {:ok,
              %Decision{
                decision: :focus,
                reason: "Slight drift",
                risk_level: :medium,
                source: :llm
              }} =
               evaluate()
    end

    test "parses valid guide decision with memory_refs" do
      set_fake_response(~s({
        "decision": "guide",
        "reason": "Consider rule",
        "suggested_next_action": "Add validation",
        "memory_refs": ["mem_1", "mem_2", "mem_3", "mem_extra"],
        "risk_level": "medium"
      }))

      assert {:ok,
              %Decision{
                decision: :guide,
                reason: "Consider rule",
                suggested_next_action: "Add validation",
                memory_refs: ["mem_1", "mem_2", "mem_3"],
                risk_level: :medium,
                source: :llm
              }} = evaluate()
    end

    test "parses valid block decision" do
      set_fake_response(~s({
        "decision": "block",
        "reason": "Off-topic",
        "suggested_next_action": "Do X instead",
        "memory_refs": [],
        "risk_level": "high"
      }))

      assert {:ok,
              %Decision{
                decision: :block,
                reason: "Off-topic",
                suggested_next_action: "Do X instead",
                memory_refs: [],
                risk_level: :high,
                source: :llm
              }} = evaluate()
    end

    test "rejects invalid decision enum" do
      set_fake_response(~s({"decision": "maybe", "reason": "hmm", "risk_level": "low"}))

      assert {:ok, %Decision{decision: :continue, source: :fallback}} = evaluate()
    end

    test "rejects empty reason" do
      set_fake_response(~s({"decision": "continue", "reason": "  ", "risk_level": "low"}))

      assert {:ok, %Decision{source: :fallback}} = evaluate()
    end

    test "rejects missing reason" do
      set_fake_response(~s({"decision": "continue", "risk_level": "low"}))

      assert {:ok, %Decision{source: :fallback}} = evaluate()
    end

    test "rejects missing risk_level" do
      set_fake_response(~s({"decision": "continue", "reason": "ok"}))

      assert {:ok, %Decision{source: :fallback}} = evaluate()
    end

    test "rejects invalid risk_level" do
      set_fake_response(~s({"decision": "continue", "reason": "ok", "risk_level": "critical"}))

      assert {:ok, %Decision{source: :fallback}} = evaluate()
    end

    test "handles null suggested_next_action" do
      set_fake_response(
        ~s({"decision": "continue", "reason": "ok", "suggested_next_action": null, "risk_level": "low"})
      )

      assert {:ok, %Decision{suggested_next_action: nil, source: :llm}} = evaluate()
    end

    test "handles missing suggested_next_action" do
      set_fake_response(~s({"decision": "continue", "reason": "ok", "risk_level": "low"}))

      assert {:ok, %Decision{suggested_next_action: nil, source: :llm}} = evaluate()
    end

    test "parses content response maps" do
      set_fake_response(%{
        "content" => ~s({"decision": "focus", "reason": "drift", "risk_level": "medium"})
      })

      assert {:ok, %Decision{decision: :focus, source: :llm}} = evaluate()
    end

    test "parses already-decoded decision maps" do
      set_fake_response(%{"decision" => "guide", "reason" => "use memory", "risk_level" => "low"})

      assert {:ok, %Decision{decision: :guide, reason: "use memory", source: :llm}} = evaluate()
    end

    test "parses atom-keyed decision maps without arbitrary atom creation" do
      set_fake_response(%{decision: :continue, reason: "ok", risk_level: :low})

      assert {:ok, %Decision{decision: :continue, source: :llm}} = evaluate()
    end

    test "caps memory_refs to 3 items" do
      set_fake_response(~s({
        "decision": "guide",
        "reason": "See refs",
        "memory_refs": ["a", "b", "c", "d", "e"],
        "risk_level": "low"
      }))

      assert {:ok, %Decision{memory_refs: ["a", "b", "c"], source: :llm}} = evaluate()
    end

    test "filters non-string memory_refs" do
      set_fake_response(~s({
        "decision": "guide",
        "reason": "See refs",
        "memory_refs": ["valid", 42, null, "also_valid"],
        "risk_level": "low"
      }))

      assert {:ok, %Decision{memory_refs: ["valid", "also_valid"], source: :llm}} = evaluate()
    end
  end

  describe "invalid JSON fallback" do
    test "fallback on completely invalid JSON" do
      set_fake_response("this is not json at all")

      assert {:ok, %Decision{decision: :continue, source: :fallback}} = evaluate()
    end

    test "fallback on malformed JSON" do
      set_fake_response("{decision: continue, reason: missing quotes}")

      assert {:ok, %Decision{decision: :continue, source: :fallback}} = evaluate()
    end

    test "fallback on unterminated JSON string without raising" do
      set_fake_response(~s({"decision": "continue, "reason": "unterminated))

      assert {:ok, %Decision{decision: :continue, source: :fallback}} = evaluate()
    end

    test "invalid enums do not create arbitrary atoms" do
      invalid = "not_a_valid_decision_#{System.unique_integer([:positive])}"
      assert_raise ArgumentError, fn -> String.to_existing_atom(invalid) end

      set_fake_response(~s({"decision": "#{invalid}", "reason": "hmm", "risk_level": "low"}))

      assert {:ok, %Decision{decision: :continue, source: :fallback}} = evaluate()
      assert_raise ArgumentError, fn -> String.to_existing_atom(invalid) end
    end

    test "fallback on empty string" do
      set_fake_response("")

      assert {:ok, %Decision{decision: :continue, source: :fallback}} = evaluate()
    end

    test "fallback includes error context in reason" do
      set_fake_response("not json")

      assert {:ok, %Decision{reason: reason}} = evaluate()
      assert reason =~ "Steering fallback"
    end
  end

  describe "model unavailable fallback" do
    defmodule RaisingModel do
      @moduledoc false
      def generate(_prompt, _opts), do: raise("boom")
    end

    test "fallback when model returns error" do
      assert {:ok,
              %Decision{
                decision: :continue,
                risk_level: :low,
                source: :fallback
              }} = evaluate(base_event(), base_ctx(), steering_model: FailingModel)
    end

    test "fallback when model raises" do
      assert {:ok, %Decision{decision: :continue, source: :fallback}} =
               evaluate(base_event(), base_ctx(), steering_model: RaisingModel)
    end

    test "fallback when no model configured" do
      assert {:ok,
              %Decision{
                decision: :continue,
                source: :fallback
              }} =
               evaluate(base_event(), base_ctx(), steering_model: nil)
               |> then(fn {:ok, d} -> {:ok, d} end)
    end

    test "fallback does NOT block (deterministic gates already ran)" do
      {:ok, decision} = evaluate(base_event(), base_ctx(), steering_model: FailingModel)
      assert decision.decision == :continue
      assert decision.risk_level == :low
    end
  end

  describe "prompt context" do
    defmodule CapturingModel do
      @moduledoc false
      def generate(prompt, _opts) do
        Process.put(:captured_prompt, prompt)
        {:ok, ~s({"decision": "continue", "reason": "ok", "risk_level": "low"})}
      end
    end

    test "includes action info in prompt sent to model" do
      {:ok, _} = evaluate(base_event(), base_ctx(), steering_model: CapturingModel)

      prompt = Process.get(:captured_prompt)
      assert prompt =~ "write"
      assert prompt =~ "lib/foo.ex"
    end

    test "tolerates missing ctx keys" do
      set_fake_response(~s({"decision": "continue", "reason": "ok", "risk_level": "low"}))

      minimal_ctx = %{}
      assert {:ok, %Decision{decision: :continue}} = evaluate(base_event(), minimal_ctx)
    end

    test "can take steering model from context" do
      ctx = Map.put(base_ctx(), :steering_model, CapturingModel)

      assert {:ok, %Decision{decision: :continue, source: :llm}} =
               SteeringAgent.evaluate(base_event(), ctx)

      assert Process.get(:captured_prompt) =~ "Implement auth module"
    end

    test "includes active task info when present" do
      ctx = %{
        active_task: %{
          content: "Fix login bug",
          category: "debugging",
          status: "in_progress"
        }
      }

      {:ok, _} = evaluate(base_event(), ctx, steering_model: CapturingModel)

      prompt = Process.get(:captured_prompt)
      assert prompt =~ "Fix login bug"
      assert prompt =~ "debugging"
    end
  end

  describe "fallback_decision/1" do
    test "returns continue with low risk" do
      decision = SteeringAgent.fallback_decision("test reason")

      assert %Decision{
               decision: :continue,
               reason: "Steering fallback: test reason",
               suggested_next_action: nil,
               memory_refs: [],
               risk_level: :low,
               source: :fallback
             } = decision
    end
  end

  describe "fenced JSON output from model" do
    test "handles ```json fences from chatty model" do
      set_fake_response(
        "```json\n{\"decision\": \"continue\", \"reason\": \"ok\", \"risk_level\": \"low\"}\n```"
      )

      assert {:ok, %Decision{decision: :continue, source: :llm}} = evaluate()
    end

    test "handles model that adds explanation after JSON" do
      set_fake_response(
        "{\"decision\": \"continue\", \"reason\": \"ok\", \"risk_level\": \"low\"}\n\nNote: this is aligned."
      )

      assert {:ok, %Decision{decision: :continue, source: :llm}} = evaluate()
    end
  end

  describe "Decision struct" do
    test "enforces required keys" do
      assert %Decision{
        decision: :continue,
        reason: "test",
        risk_level: :low,
        source: :llm,
        suggested_next_action: nil,
        memory_refs: []
      }
    end
  end
end
