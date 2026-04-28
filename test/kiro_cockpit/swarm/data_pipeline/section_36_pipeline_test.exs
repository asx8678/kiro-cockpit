defmodule KiroCockpit.Swarm.DataPipeline.Section36PipelineTest do
  use KiroCockpit.DataCase, async: true

  alias KiroCockpit.Swarm.Analyzers.{DreamAnalyzer, ErrorAnalyzer}
  alias KiroCockpit.Swarm.DataPipeline.{BronzeAction, Finding, FindingsScorer}
  alias KiroCockpit.Swarm.Event
  alias KiroCockpit.Swarm.Memory.Gold

  test "Bronze event contains session/plan/task correlation" do
    session_id = "section36-#{System.unique_integer([:positive])}"
    plan_id = Ecto.UUID.generate()
    task_id = Ecto.UUID.generate()

    event =
      Event.new(:kiro_session_prompt,
        session_id: session_id,
        plan_id: plan_id,
        task_id: task_id,
        agent_id: "kiro-executor",
        permission_level: :write,
        payload: %{prompt: "run focused tests"}
      )

    assert :ok = BronzeAction.record_before(event, %{safe: true})
    [recorded] = BronzeAction.list_actions(session_id)

    assert recorded.session_id == session_id
    assert recorded.plan_id == plan_id
    assert recorded.task_id == task_id

    assert recorded.hook_results["correlation"]["session_id"] == session_id
    assert recorded.hook_results["correlation"]["plan_id"] == plan_id
    assert recorded.hook_results["correlation"]["task_id"] == task_id
    assert recorded.hook_results["correlation"]["action_name"] == "kiro_session_prompt"
  end

  test "ErrorAnalyzer creates high-priority finding" do
    [finding] =
      ErrorAnalyzer.analyze(%{
        session_id: "s1",
        plan_id: "p1",
        task_id: "t1",
        stderr: "mix test failed"
      })

    assert %Finding{} = finding
    assert finding.tag == :error
    assert finding.priority >= 70
    assert finding.plan_id == "p1"
  end

  test "DreamAnalyzer tags reusable relationship" do
    [finding] =
      DreamAnalyzer.analyze(%{
        session_id: "s1",
        relationship: "EventStore maps ACP updates to LiveView timeline cards"
      })

    assert finding.tag == :relationship
    assert finding.type == :reference
    assert finding.summary =~ "EventStore maps ACP updates"
  end

  test "FindingsAnalysis promotes priority >= 70" do
    low = Finding.new(%{tag: :noise, type: :feedback, priority: 20, summary: "low"})
    high = Finding.new(%{tag: :recipe, type: :project, priority: 70, summary: "promote me"})

    assert FindingsScorer.promoted([low, high]) == [high]
  end

  test "Gold memory retrieval feeds next plan" do
    finding =
      Finding.new(%{
        tag: :recipe,
        type: :project,
        priority: 88,
        summary: "Use focused mix test for PuppyBrain regressions",
        evidence: "mix test test/kiro_cockpit/puppy_brain"
      })

    memories = [Gold.from_finding(finding)]

    assert [%{summary: summary}] = Gold.retrieve(memories, "PuppyBrain")
    assert summary =~ "focused mix test"
  end

  test "consolidation does not duplicate memories" do
    memory = %{type: :project, tag: :recipe, summary: "Run focused tests", evidence: "a"}
    duplicate = %{type: :project, tag: :recipe, summary: "Run focused tests", evidence: "b"}
    other = %{type: :feedback, tag: :anti_pattern, summary: "Do not skip validation"}

    assert Gold.consolidate([memory, duplicate, other]) == [memory, other]
  end
end
