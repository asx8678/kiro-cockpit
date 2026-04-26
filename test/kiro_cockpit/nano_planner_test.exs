defmodule KiroCockpit.NanoPlannerTest do
  use KiroCockpit.DataCase

  alias KiroCockpit.NanoPlanner
  alias KiroCockpit.Plans

  # ── Fake injectable session module ──────────────────────────────────

  defmodule FakeKiroSession do
    @moduledoc false
    # Returns session state from process dictionary or a default.
    # Records all prompt/3 calls for assertion.
    def state(_session) do
      Process.get(:fake_kiro_state) ||
        %{
          session_id: "test-session",
          cwd: Process.get(:fake_kiro_cwd)
        }
    end

    def prompt(_session, prompt_text, opts) do
      calls = Process.get(:fake_kiro_prompt_calls, [])
      Process.put(:fake_kiro_prompt_calls, calls ++ [{prompt_text, opts}])

      Process.get(:fake_kiro_prompt_result) || {:ok, %{}}
    end

    def recent_stream_events(_session, opts) do
      Process.put(:fake_kiro_recent_events_opts, opts)
      Process.get(:fake_kiro_stream_events, [])
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp valid_plan_map(overrides \\ %{}) do
    base = %{
      "objective" => "Build ACP timeline view",
      "summary" => "Add a LiveView timeline for session events.",
      "phases" => [
        %{
          "number" => 1,
          "title" => "Foundation",
          "steps" => [
            %{
              "title" => "Create timeline schema",
              "details" => "Add event normalization fields.",
              "files" => %{"lib/kiro_cockpit/event_store.ex" => ""},
              "permission" => "write",
              "validation" => "Unit test event normalization."
            }
          ]
        }
      ],
      "permissions_needed" => ["read", "write"],
      "acceptance_criteria" => ["Session updates appear as timeline cards."],
      "risks" => [%{"risk" => "ACP prompt timing", "mitigation" => "Use turn-end event"}],
      "execution_prompt" => "Implement the approved plan phase by phase.",
      "plan_markdown" => "# Plan: ACP Timeline View"
    }

    Map.merge(base, overrides)
  end

  defp setup_project_dir(_) do
    dir =
      System.tmp_dir!()
      |> Path.join("nano_planner_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "mix.exs"), "defmodule Test.Project do\nend")
    File.write!(Path.join(dir, "README.md"), "# Test Project")

    Process.put(:fake_kiro_cwd, dir)
    Process.put(:fake_kiro_state, %{session_id: "test-session", cwd: dir})
    Process.put(:fake_kiro_prompt_calls, [])
    Process.put(:fake_kiro_stream_events, [])
    Process.delete(:fake_kiro_recent_events_opts)

    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, project_dir: dir}
  end

  defp default_plan_opts(dir) do
    [
      kiro_session_module: FakeKiroSession,
      project_dir: dir,
      session_id: "test-session"
    ]
  end

  # ── plan/3 ───────────────────────────────────────────────────────────

  describe "plan/3 happy path" do
    setup [:setup_project_dir]

    test "persists a draft plan from direct map model output", %{project_dir: dir} do
      Process.put(:fake_kiro_prompt_result, {:ok, valid_plan_map()})

      assert {:ok, plan} =
               NanoPlanner.plan(
                 :fake_session,
                 "Build ACP timeline view",
                 default_plan_opts(dir)
               )

      assert plan.session_id == "test-session"
      assert plan.mode == "nano"
      assert plan.status == "draft"
      assert plan.user_request == "Build ACP timeline view"
      assert plan.execution_prompt == "Implement the approved plan phase by phase."
      assert plan.plan_markdown == "# Plan: ACP Timeline View"
      assert is_binary(plan.project_snapshot_hash)
      assert plan.project_snapshot_hash != ""
      assert length(plan.plan_steps) == 1
      assert hd(plan.plan_steps).title == "Create timeline schema"
    end

    test "respects mode from opts", %{project_dir: dir} do
      Process.put(:fake_kiro_prompt_result, {:ok, valid_plan_map()})

      assert {:ok, plan} =
               NanoPlanner.plan(
                 :fake_session,
                 "Deep analysis request",
                 Keyword.put(default_plan_opts(dir), :mode, :nano_deep)
               )

      assert plan.mode == "nano_deep"
    end

    test "accepts string mode", %{project_dir: dir} do
      Process.put(:fake_kiro_prompt_result, {:ok, valid_plan_map()})

      assert {:ok, plan} =
               NanoPlanner.plan(
                 :fake_session,
                 "Fix the bug",
                 Keyword.put(default_plan_opts(dir), :mode, "nano_fix")
               )

      assert plan.mode == "nano_fix"
    end

    test "passes timeout to session prompt", %{project_dir: dir} do
      Process.put(:fake_kiro_prompt_result, {:ok, valid_plan_map()})

      assert {:ok, _plan} =
               NanoPlanner.plan(
                 :fake_session,
                 "Build ACP timeline view",
                 Keyword.put(default_plan_opts(dir), :planner_timeout, 60_000)
               )

      calls = Process.get(:fake_kiro_prompt_calls, [])
      assert length(calls) == 1
      {_, opts} = hd(calls)
      assert Keyword.get(opts, :timeout) == 60_000
    end
  end

  describe "plan/3 JSON extraction variants" do
    setup [:setup_project_dir]

    test "extracts plan from ACP-style content key", %{project_dir: dir} do
      acp_result = %{"content" => Jason.encode!(valid_plan_map()), "stopReason" => "end_turn"}
      Process.put(:fake_kiro_prompt_result, {:ok, acp_result})

      assert {:ok, plan} =
               NanoPlanner.plan(:fake_session, "Build it", default_plan_opts(dir))

      assert plan.execution_prompt == "Implement the approved plan phase by phase."
    end

    test "extracts plan from text key", %{project_dir: dir} do
      acp_result = %{"text" => Jason.encode!(valid_plan_map())}
      Process.put(:fake_kiro_prompt_result, {:ok, acp_result})

      assert {:ok, plan} =
               NanoPlanner.plan(:fake_session, "Build it", default_plan_opts(dir))

      assert plan.execution_prompt == "Implement the approved plan phase by phase."
    end

    test "extracts plan from message key", %{project_dir: dir} do
      acp_result = %{"message" => Jason.encode!(valid_plan_map())}
      Process.put(:fake_kiro_prompt_result, {:ok, acp_result})

      assert {:ok, plan} =
               NanoPlanner.plan(:fake_session, "Build it", default_plan_opts(dir))

      assert plan.execution_prompt == "Implement the approved plan phase by phase."
    end

    test "extracts plan from output key", %{project_dir: dir} do
      acp_result = %{"output" => Jason.encode!(valid_plan_map())}
      Process.put(:fake_kiro_prompt_result, {:ok, acp_result})

      assert {:ok, plan} =
               NanoPlanner.plan(:fake_session, "Build it", default_plan_opts(dir))

      assert plan.execution_prompt == "Implement the approved plan phase by phase."
    end

    test "extracts plan from plan key", %{project_dir: dir} do
      acp_result = %{"plan" => Jason.encode!(valid_plan_map())}
      Process.put(:fake_kiro_prompt_result, {:ok, acp_result})

      assert {:ok, plan} =
               NanoPlanner.plan(:fake_session, "Build it", default_plan_opts(dir))

      assert plan.execution_prompt == "Implement the approved plan phase by phase."
    end

    test "extracts plan from raw_plan key", %{project_dir: dir} do
      acp_result = %{"raw_plan" => Jason.encode!(valid_plan_map())}
      Process.put(:fake_kiro_prompt_result, {:ok, acp_result})

      assert {:ok, plan} =
               NanoPlanner.plan(:fake_session, "Build it", default_plan_opts(dir))

      assert plan.execution_prompt == "Implement the approved plan phase by phase."
    end

    test "extracts plan from direct map with atom keys", %{project_dir: dir} do
      plan_map =
        valid_plan_map()
        |> Enum.map(fn {k, v} -> {String.to_atom(k), atomize_keys(v)} end)
        |> Map.new()

      Process.put(:fake_kiro_prompt_result, {:ok, plan_map})

      assert {:ok, plan} =
               NanoPlanner.plan(:fake_session, "Build it", default_plan_opts(dir))

      assert plan.execution_prompt == "Implement the approved plan phase by phase."
    end

    test "extracts nested map from ACP content key (not JSON)", %{project_dir: dir} do
      acp_result = %{"content" => valid_plan_map()}
      Process.put(:fake_kiro_prompt_result, {:ok, acp_result})

      assert {:ok, plan} =
               NanoPlanner.plan(:fake_session, "Build it", default_plan_opts(dir))

      assert plan.execution_prompt == "Implement the approved plan phase by phase."
    end

    test "extracts plan JSON from ACP content block lists", %{project_dir: dir} do
      acp_result = %{
        "content" => [
          %{"type" => "text", "text" => "Thinking..."},
          %{"type" => "text", "text" => Jason.encode!(valid_plan_map())}
        ],
        "stopReason" => "end_turn"
      }

      Process.put(:fake_kiro_prompt_result, {:ok, acp_result})

      assert {:ok, plan} =
               NanoPlanner.plan(:fake_session, "Build it", default_plan_opts(dir))

      assert plan.execution_prompt == "Implement the approved plan phase by phase."
    end

    test "extracts planner JSON from recent stream events when prompt result is metadata only", %{
      project_dir: dir
    } do
      stream_events = [
        %{
          raw: %{
            "update" => %{
              "sessionUpdate" => "agent_message_chunk",
              "content" => [
                %{"type" => "text", "text" => Jason.encode!(valid_plan_map())}
              ]
            }
          }
        }
      ]

      Process.put(:fake_kiro_prompt_result, {:ok, %{"stopReason" => "end_turn"}})
      Process.put(:fake_kiro_stream_events, stream_events)

      assert {:ok, plan} =
               NanoPlanner.plan(
                 :fake_session,
                 "Build it",
                 Keyword.put(default_plan_opts(dir), :stream_event_limit, 7)
               )

      assert plan.execution_prompt == "Implement the approved plan phase by phase."
      assert Process.get(:fake_kiro_recent_events_opts) == [limit: 7]
    end

    test "persists decoded raw_model_output for string JSON model output", %{project_dir: dir} do
      Process.put(:fake_kiro_prompt_result, {:ok, Jason.encode!(valid_plan_map())})

      assert {:ok, plan} =
               NanoPlanner.plan(:fake_session, "Build it", default_plan_opts(dir))

      assert plan.raw_model_output["objective"] == "Build ACP timeline view"
    end
  end

  describe "plan/3 fenced JSON extraction" do
    setup [:setup_project_dir]

    test "extracts JSON from fenced ```json code block in content", %{project_dir: dir} do
      json = Jason.encode!(valid_plan_map())
      fenced = "```json\n#{json}\n```"
      acp_result = %{"content" => fenced}
      Process.put(:fake_kiro_prompt_result, {:ok, acp_result})

      assert {:ok, plan} =
               NanoPlanner.plan(:fake_session, "Build it", default_plan_opts(dir))

      assert plan.execution_prompt == "Implement the approved plan phase by phase."
    end

    test "handles fenced JSON with leading/trailing whitespace", %{project_dir: dir} do
      json = Jason.encode!(valid_plan_map())
      fenced = "  ```json\n  #{json}  \n  ```  "
      acp_result = %{"content" => fenced}
      Process.put(:fake_kiro_prompt_result, {:ok, acp_result})

      assert {:ok, plan} =
               NanoPlanner.plan(:fake_session, "Build it", default_plan_opts(dir))

      assert plan.execution_prompt == "Implement the approved plan phase by phase."
    end
  end

  describe "plan/3 invalid model output" do
    setup [:setup_project_dir]

    test "returns error for completely unparseable content", %{project_dir: dir} do
      acp_result = %{"content" => "I'm sorry, I can't help with that."}
      Process.put(:fake_kiro_prompt_result, {:ok, acp_result})

      assert {:error, {:invalid_model_output, msg}} =
               NanoPlanner.plan(:fake_session, "Bad output", default_plan_opts(dir))

      assert msg =~ "JSON parse error"
    end

    test "returns error when model returns non-map non-string", %{project_dir: dir} do
      Process.put(:fake_kiro_prompt_result, {:ok, [1, 2, 3]})

      assert {:error, {:invalid_model_output, "expected map or string, got: [1, 2, 3]"}} =
               NanoPlanner.plan(:fake_session, "Bad type", default_plan_opts(dir))
    end

    test "returns error when JSON decodes to non-map", %{project_dir: dir} do
      acp_result = %{"content" => Jason.encode!([1, 2, 3])}
      Process.put(:fake_kiro_prompt_result, {:ok, acp_result})

      assert {:error, {:invalid_model_output, msg}} =
               NanoPlanner.plan(:fake_session, "Array output", default_plan_opts(dir))

      assert msg =~ "non-map"
    end

    test "returns error for invalid JSON string", %{project_dir: dir} do
      acp_result = %{"content" => "{invalid json!!!"}
      Process.put(:fake_kiro_prompt_result, {:ok, acp_result})

      assert {:error, {:invalid_model_output, msg}} =
               NanoPlanner.plan(:fake_session, "Bad JSON", default_plan_opts(dir))

      assert msg =~ "JSON parse error"
    end

    test "returns error when ACP envelope has no recognizable keys", %{project_dir: dir} do
      acp_result = %{"stopReason" => "end_turn", "usage" => %{"tokens" => 42}}
      Process.put(:fake_kiro_prompt_result, {:ok, acp_result})

      assert {:error, {:invalid_model_output, msg}} =
               NanoPlanner.plan(:fake_session, "No plan keys", default_plan_opts(dir))

      assert msg =~ "no plan found in ACP envelope"
    end

    test "propagates model call errors", %{project_dir: dir} do
      Process.put(:fake_kiro_prompt_result, {:error, :timeout})

      assert {:error, :timeout} =
               NanoPlanner.plan(:fake_session, "Timeout test", default_plan_opts(dir))
    end
  end

  describe "plan/3 validation errors" do
    setup [:setup_project_dir]

    test "returns error when plan is missing required keys", %{project_dir: dir} do
      incomplete_plan = %{"objective" => "Do something"}
      Process.put(:fake_kiro_prompt_result, {:ok, incomplete_plan})

      assert {:error, {:invalid_plan, msg}} =
               NanoPlanner.plan(:fake_session, "Incomplete plan", default_plan_opts(dir))

      assert msg =~ "missing required keys"
    end

    test "returns error when phases are empty", %{project_dir: dir} do
      empty_phases_plan = Map.put(valid_plan_map(), "phases", [])
      Process.put(:fake_kiro_prompt_result, {:ok, empty_phases_plan})

      assert {:error, {:invalid_plan, msg}} =
               NanoPlanner.plan(:fake_session, "Empty phases", default_plan_opts(dir))

      assert msg =~ "invalid phases"
    end
  end

  describe "plan/3 mode validation" do
    setup [:setup_project_dir]

    test "returns error for invalid mode", %{project_dir: dir} do
      Process.put(:fake_kiro_prompt_result, {:ok, valid_plan_map()})

      assert {:error, {:invalid_mode, :mega}} =
               NanoPlanner.plan(
                 :fake_session,
                 "Bad mode",
                 Keyword.put(default_plan_opts(dir), :mode, :mega)
               )
    end

    test "returns error for invalid string mode", %{project_dir: dir} do
      Process.put(:fake_kiro_prompt_result, {:ok, valid_plan_map()})

      assert {:error, {:invalid_mode, "invalid"}} =
               NanoPlanner.plan(
                 :fake_session,
                 "Bad mode",
                 Keyword.put(default_plan_opts(dir), :mode, "invalid")
               )
    end

    test "defaults mode to :nano", %{project_dir: dir} do
      Process.put(:fake_kiro_prompt_result, {:ok, valid_plan_map()})

      assert {:ok, plan} =
               NanoPlanner.plan(:fake_session, "Default mode", default_plan_opts(dir))

      assert plan.mode == "nano"
    end
  end

  # ── approve/3 ────────────────────────────────────────────────────────

  describe "Staleness.check/3" do
    alias KiroCockpit.NanoPlanner.Staleness

    setup [:setup_project_dir]

    test "returns :ok when hashes match", %{project_dir: dir} do
      Process.put(:fake_kiro_prompt_result, {:ok, valid_plan_map()})

      assert {:ok, plan} =
               NanoPlanner.plan(:fake_session, "Build it", default_plan_opts(dir))

      assert :ok = Staleness.check(plan, dir, [])
    end

    test "returns {:error, :stale_plan} when hashes differ", %{project_dir: dir} do
      Process.put(:fake_kiro_prompt_result, {:ok, valid_plan_map()})

      assert {:ok, plan} =
               NanoPlanner.plan(:fake_session, "Build it", default_plan_opts(dir))

      File.write!(Path.join(dir, "NEW_FILE.md"), "# Changed")

      assert {:error, :stale_plan} = Staleness.check(plan, dir, [])
    end

    test "returns {:error, :stale_plan_unknown} when project_dir is nil" do
      plan = %KiroCockpit.Plans.Plan{project_snapshot_hash: "abc123"}
      assert {:error, :stale_plan_unknown} = Staleness.check(plan, nil, [])
    end

    test "returns {:error, :stale_plan_unknown} when project_dir is empty" do
      plan = %KiroCockpit.Plans.Plan{project_snapshot_hash: "abc123"}
      assert {:error, :stale_plan_unknown} = Staleness.check(plan, "", [])
    end

    test "returns {:error, :stale_plan_unknown} when snapshot build fails", %{project_dir: dir} do
      Process.put(:fake_kiro_prompt_result, {:ok, valid_plan_map()})

      assert {:ok, plan} =
               NanoPlanner.plan(:fake_session, "Build it", default_plan_opts(dir))

      # Remove the project dir so snapshot build fails
      File.rm_rf!(dir)

      assert {:error, :stale_plan_unknown} = Staleness.check(plan, dir, [])

      File.mkdir_p!(dir)
    end

    test "returns {:error, :stale_plan_unknown} with injectable broken context_builder_module", %{
      project_dir: dir
    } do
      Process.put(:fake_kiro_prompt_result, {:ok, valid_plan_map()})

      assert {:ok, plan} =
               NanoPlanner.plan(:fake_session, "Build it", default_plan_opts(dir))

      defmodule StalenessTestBrokenBuilder do
        @moduledoc false
        def build(_opts), do: {:error, :simulated_failure}
      end

      assert {:error, :stale_plan_unknown} =
               Staleness.check(plan, dir, context_builder_module: StalenessTestBrokenBuilder)
    end
  end

  describe "Staleness.trusted_context/3" do
    alias KiroCockpit.NanoPlanner.Staleness

    setup [:setup_project_dir]

    test "returns %{stale_plan?: false} when fresh", %{project_dir: dir} do
      Process.put(:fake_kiro_prompt_result, {:ok, valid_plan_map()})

      assert {:ok, plan} =
               NanoPlanner.plan(:fake_session, "Build it", default_plan_opts(dir))

      assert %{stale_plan?: false} = Staleness.trusted_context(plan, dir, [])
    end

    test "returns %{stale_plan?: true, reason: :stale_plan} when stale", %{project_dir: dir} do
      Process.put(:fake_kiro_prompt_result, {:ok, valid_plan_map()})

      assert {:ok, plan} =
               NanoPlanner.plan(:fake_session, "Build it", default_plan_opts(dir))

      File.write!(Path.join(dir, "NEW_FILE.md"), "# Changed")

      assert %{stale_plan?: true, reason: :stale_plan} =
               Staleness.trusted_context(plan, dir, [])
    end

    test "returns %{stale_plan?: true, reason: :stale_plan_unknown} when dir is nil" do
      plan = %KiroCockpit.Plans.Plan{project_snapshot_hash: "abc123"}

      assert %{stale_plan?: true, reason: :stale_plan_unknown} =
               Staleness.trusted_context(plan, nil, [])
    end
  end

  describe "approve/3 happy path" do
    setup [:setup_project_dir]

    test "approves a plan and sends execution prompt", %{project_dir: dir} do
      Process.put(:fake_kiro_prompt_result, {:ok, valid_plan_map()})
      Process.put(:fake_kiro_prompt_calls, [])

      assert {:ok, plan} =
               NanoPlanner.plan(:fake_session, "Build it", default_plan_opts(dir))

      # Now approve: the model call for execution prompt
      Process.put(:fake_kiro_prompt_result, {:ok, %{"stopReason" => "end_turn"}})
      Process.put(:fake_kiro_prompt_calls, [])

      assert {:ok, %{plan: approved_plan, prompt_result: result}} =
               NanoPlanner.approve(:fake_session, plan.id,
                 kiro_session_module: FakeKiroSession,
                 project_dir: dir
               )

      assert approved_plan.status == "approved"
      assert approved_plan.approved_at != nil

      # Verify prompt was called with the execution prompt
      calls = Process.get(:fake_kiro_prompt_calls, [])
      assert length(calls) == 1
      {prompt_text, _opts} = hd(calls)
      assert prompt_text == "Implement the approved plan phase by phase."

      assert result == %{"stopReason" => "end_turn"}
    end

    test "returns error when plan not found", %{project_dir: dir} do
      assert {:error, :not_found} =
               NanoPlanner.approve(:fake_session, Ecto.UUID.generate(),
                 kiro_session_module: FakeKiroSession,
                 project_dir: dir
               )
    end

    test "returns error with approved plan when prompt send fails", %{project_dir: dir} do
      Process.put(:fake_kiro_prompt_result, {:ok, valid_plan_map()})
      Process.put(:fake_kiro_prompt_calls, [])

      assert {:ok, plan} =
               NanoPlanner.plan(:fake_session, "Build it", default_plan_opts(dir))

      # Prompt send fails
      Process.put(:fake_kiro_prompt_result, {:error, :connection_lost})
      Process.put(:fake_kiro_prompt_calls, [])

      assert {:error, {:prompt_failed, failed_plan, :connection_lost}} =
               NanoPlanner.approve(:fake_session, plan.id,
                 kiro_session_module: FakeKiroSession,
                 project_dir: dir
               )

      # The plan was still approved in the DB
      assert failed_plan.status == "approved"
      assert failed_plan.id == plan.id
    end
  end

  describe "approve/3 stale plan detection" do
    setup [:setup_project_dir]

    test "rejects stale plan when snapshot hash differs via boundary", %{project_dir: dir} do
      Process.put(:fake_kiro_prompt_result, {:ok, valid_plan_map()})
      session_id = "stale-approve-hash-#{System.unique_integer([:positive])}"

      plan_opts = default_plan_opts(dir) |> Keyword.put(:session_id, session_id)

      assert {:ok, plan} =
               NanoPlanner.plan(:fake_session, "Build it", plan_opts)

      # Modify the project so the snapshot hash changes
      File.write!(Path.join(dir, "NEW_FILE.md"), "# New content changes the hash")

      Process.put(:fake_kiro_prompt_calls, [])

      # With hooks enabled, staleness is checked inside ActionBoundary
      assert {:error, {:swarm_blocked, reason, _messages}} =
               NanoPlanner.approve(:fake_session, plan.id,
                 kiro_session_module: FakeKiroSession,
                 project_dir: dir,
                 session_id: session_id,
                 swarm_hooks: true,
                 pre_hooks: [KiroCockpit.Swarm.Hooks.TaskEnforcementHook],
                 post_hooks: []
               )

      assert reason =~ "Stale plan"

      # Plan should still be draft (not approved)
      refreshed = Plans.get_plan(plan.id)
      assert refreshed.status == "draft"

      # No prompt should have been sent
      calls = Process.get(:fake_kiro_prompt_calls, [])
      assert calls == []

      # Bronze trace should be persisted
      events = KiroCockpit.Swarm.Events.list_by_session(session_id, limit: 10)
      assert length(events) >= 1
      trace = List.first(events)
      assert trace.event_type == "hook_trace"
      assert trace.hook_results["outcome"] == "blocked"
      assert trace.hook_results["action"] == "nano_plan_approve"
    end

    test "fails closed when project dir is unavailable", %{project_dir: dir} do
      Process.put(:fake_kiro_prompt_result, {:ok, valid_plan_map()})

      assert {:ok, plan} =
               NanoPlanner.plan(:fake_session, "Build it", default_plan_opts(dir))

      # Session state has no cwd, and no :project_dir opt
      Process.put(:fake_kiro_state, %{session_id: "test-session", cwd: nil})
      # Reset prompt calls from plan/3 — we only care about approve prompts
      Process.put(:fake_kiro_prompt_calls, [])

      # Approval must be blocked — fail closed
      assert {:error, :stale_plan_unknown} =
               NanoPlanner.approve(:fake_session, plan.id, kiro_session_module: FakeKiroSession)

      # Plan should still be draft, not approved
      refreshed = Plans.get_plan(plan.id)
      assert refreshed.status == "draft"

      # No prompt should have been sent during approve
      calls = Process.get(:fake_kiro_prompt_calls, [])
      assert calls == []

      # Restore state
      Process.put(:fake_kiro_state, %{session_id: "test-session", cwd: dir})
    end

    test "fails closed when snapshot build fails via boundary", %{project_dir: dir} do
      Process.put(:fake_kiro_prompt_result, {:ok, valid_plan_map()})
      session_id = "stale-approve-fail-#{System.unique_integer([:positive])}"

      plan_opts = default_plan_opts(dir) |> Keyword.put(:session_id, session_id)

      assert {:ok, plan} =
               NanoPlanner.plan(:fake_session, "Build it", plan_opts)

      # Delete the project dir so snapshot build fails
      File.rm_rf!(dir)

      # Reset prompt calls from plan/3
      Process.put(:fake_kiro_prompt_calls, [])

      # With hooks enabled, snapshot build failure triggers stale_plan_unknown
      # inside the boundary, which TaskEnforcementHook blocks.
      assert {:error, {:swarm_blocked, reason, _messages}} =
               NanoPlanner.approve(:fake_session, plan.id,
                 kiro_session_module: FakeKiroSession,
                 project_dir: dir,
                 session_id: session_id,
                 swarm_hooks: true,
                 pre_hooks: [KiroCockpit.Swarm.Hooks.TaskEnforcementHook],
                 post_hooks: []
               )

      assert reason =~ "Stale plan"

      # Plan should still be draft
      refreshed = Plans.get_plan(plan.id)
      assert refreshed.status == "draft"

      # No prompt should have been sent during approve
      calls = Process.get(:fake_kiro_prompt_calls, [])
      assert calls == []

      # Re-create dir for on_exit cleanup (though it was already removed)
      File.mkdir_p!(dir)

      # Bronze trace should be persisted
      events = KiroCockpit.Swarm.Events.list_by_session(session_id, limit: 10)
      assert length(events) >= 1
      trace = List.first(events)
      assert trace.event_type == "hook_trace"
      assert trace.hook_results["outcome"] == "blocked"
      assert trace.hook_results["action"] == "nano_plan_approve"
    end

    test "fails closed with injectable context_builder_module that errors via boundary", %{
      project_dir: dir
    } do
      Process.put(:fake_kiro_prompt_result, {:ok, valid_plan_map()})
      session_id = "stale-approve-cb-#{System.unique_integer([:positive])}"

      plan_opts = default_plan_opts(dir) |> Keyword.put(:session_id, session_id)

      assert {:ok, plan} =
               NanoPlanner.plan(:fake_session, "Build it", plan_opts)

      defmodule BrokenContextBuilder do
        @moduledoc false
        def build(_opts), do: {:error, :simulated_failure}
      end

      # Reset prompt calls from plan/3
      Process.put(:fake_kiro_prompt_calls, [])

      # With hooks enabled, the broken context builder triggers stale_plan_unknown
      # inside the boundary, which TaskEnforcementHook blocks.
      assert {:error, {:swarm_blocked, reason, _messages}} =
               NanoPlanner.approve(:fake_session, plan.id,
                 kiro_session_module: FakeKiroSession,
                 project_dir: dir,
                 session_id: session_id,
                 swarm_hooks: true,
                 context_builder_module: BrokenContextBuilder,
                 pre_hooks: [KiroCockpit.Swarm.Hooks.TaskEnforcementHook],
                 post_hooks: []
               )

      assert reason =~ "Stale plan"

      # Plan should still be draft
      refreshed = Plans.get_plan(plan.id)
      assert refreshed.status == "draft"

      # No prompt should have been sent
      calls = Process.get(:fake_kiro_prompt_calls, [])
      assert calls == []

      # Bronze trace should be persisted
      events = KiroCockpit.Swarm.Events.list_by_session(session_id, limit: 10)
      assert length(events) >= 1
      trace = List.first(events)
      assert trace.event_type == "hook_trace"
      assert trace.hook_results["outcome"] == "blocked"
      assert trace.hook_results["action"] == "nano_plan_approve"
    end
  end

  # ── revise/4 ─────────────────────────────────────────────────────────

  describe "revise/4" do
    setup [:setup_project_dir]

    test "supersedes old plan only after new plan succeeds", %{project_dir: dir} do
      Process.put(:fake_kiro_prompt_result, {:ok, valid_plan_map()})

      assert {:ok, old_plan} =
               NanoPlanner.plan(:fake_session, "Original request", default_plan_opts(dir))

      assert old_plan.status == "draft"

      # Revise with a different plan output
      revised_plan_map =
        Map.merge(valid_plan_map(), %{
          "objective" => "Revised objective",
          "execution_prompt" => "Execute the revised plan."
        })

      Process.put(:fake_kiro_prompt_result, {:ok, revised_plan_map})

      assert {:ok, new_plan} =
               NanoPlanner.revise(
                 :fake_session,
                 old_plan.id,
                 "Please add more testing phases",
                 default_plan_opts(dir)
               )

      assert new_plan.status == "draft"
      assert new_plan.execution_prompt == "Execute the revised plan."

      # Old plan should be superseded
      refreshed_old = Plans.get_plan(old_plan.id)
      assert refreshed_old.status == "superseded"
    end

    test "does NOT supersede old plan when model call fails", %{project_dir: dir} do
      Process.put(:fake_kiro_prompt_result, {:ok, valid_plan_map()})

      assert {:ok, old_plan} =
               NanoPlanner.plan(:fake_session, "Original request", default_plan_opts(dir))

      # Model call fails
      Process.put(:fake_kiro_prompt_result, {:error, :timeout})

      assert {:error, :timeout} =
               NanoPlanner.revise(
                 :fake_session,
                 old_plan.id,
                 "Please revise",
                 default_plan_opts(dir)
               )

      # Old plan should still be draft (not superseded)
      refreshed_old = Plans.get_plan(old_plan.id)
      assert refreshed_old.status == "draft"
    end

    test "does NOT supersede old plan when validation fails", %{project_dir: dir} do
      Process.put(:fake_kiro_prompt_result, {:ok, valid_plan_map()})

      assert {:ok, old_plan} =
               NanoPlanner.plan(:fake_session, "Original request", default_plan_opts(dir))

      # Model returns invalid plan
      Process.put(:fake_kiro_prompt_result, {:ok, %{"objective" => "Only objective"}})

      assert {:error, {:invalid_plan, _}} =
               NanoPlanner.revise(
                 :fake_session,
                 old_plan.id,
                 "Please revise",
                 default_plan_opts(dir)
               )

      # Old plan should still be draft
      refreshed_old = Plans.get_plan(old_plan.id)
      assert refreshed_old.status == "draft"
    end

    test "does NOT supersede old plan when persistence fails", %{project_dir: dir} do
      Process.put(:fake_kiro_prompt_result, {:ok, valid_plan_map()})

      assert {:ok, old_plan} =
               NanoPlanner.plan(:fake_session, "Original request", default_plan_opts(dir))

      # New plan returns an invalid mode (will fail at persistence)
      # We simulate this by having the model return a valid plan
      # but with opts that cause a failure. Since we can't easily
      # make Plans.create_plan fail, we test the indirect case:
      # If plan/3 returns an error, old plan is not superseded.
      Process.put(:fake_kiro_prompt_result, {:error, :model_error})

      assert {:error, :model_error} =
               NanoPlanner.revise(
                 :fake_session,
                 old_plan.id,
                 "Please revise",
                 default_plan_opts(dir)
               )

      refreshed_old = Plans.get_plan(old_plan.id)
      assert refreshed_old.status == "draft"
    end

    test "returns not_found for missing plan", %{project_dir: dir} do
      assert {:error, :not_found} =
               NanoPlanner.revise(
                 :fake_session,
                 Ecto.UUID.generate(),
                 "Revision",
                 default_plan_opts(dir)
               )
    end

    test "preserves old plan mode in revision", %{project_dir: dir} do
      Process.put(:fake_kiro_prompt_result, {:ok, valid_plan_map()})

      assert {:ok, old_plan} =
               NanoPlanner.plan(
                 :fake_session,
                 "Original request",
                 Keyword.put(default_plan_opts(dir), :mode, :nano_deep)
               )

      assert old_plan.mode == "nano_deep"

      Process.put(:fake_kiro_prompt_result, {:ok, valid_plan_map()})

      assert {:ok, new_plan} =
               NanoPlanner.revise(
                 :fake_session,
                 old_plan.id,
                 "Please revise",
                 default_plan_opts(dir)
               )

      assert new_plan.mode == "nano_deep"
    end

    test "includes old plan context in revision request", %{project_dir: dir} do
      Process.put(:fake_kiro_prompt_result, {:ok, valid_plan_map()})

      assert {:ok, old_plan} =
               NanoPlanner.plan(:fake_session, "Original request", default_plan_opts(dir))

      Process.put(:fake_kiro_prompt_result, {:ok, valid_plan_map()})
      Process.put(:fake_kiro_prompt_calls, [])

      assert {:ok, _new_plan} =
               NanoPlanner.revise(
                 :fake_session,
                 old_plan.id,
                 "Add more tests",
                 default_plan_opts(dir)
               )

      # The plan/3 call should have received the combined revision request
      calls = Process.get(:fake_kiro_prompt_calls, [])
      assert length(calls) == 1
      {prompt_text, _opts} = hd(calls)

      assert prompt_text =~ "Add more tests"
      assert prompt_text =~ "Previous plan_markdown:"
      assert prompt_text =~ "# Plan: ACP Timeline View"
      assert prompt_text =~ "Previous execution_prompt:"
      assert prompt_text =~ "Implement the approved plan phase by phase."
    end
  end

  # ── parse_model_output/1 (unit-level) ────────────────────────────────

  describe "parse_model_output/1" do
    test "accepts direct map with plan keys" do
      plan = valid_plan_map()
      assert {:ok, ^plan} = NanoPlanner.parse_model_output(plan)
    end

    test "accepts JSON string" do
      plan = valid_plan_map()
      json = Jason.encode!(plan)
      assert {:ok, decoded} = NanoPlanner.parse_model_output(json)
      assert decoded["objective"] == "Build ACP timeline view"
    end

    test "accepts fenced JSON string" do
      plan = valid_plan_map()
      json = Jason.encode!(plan)
      fenced = "```json\n#{json}\n```"
      assert {:ok, decoded} = NanoPlanner.parse_model_output(fenced)
      assert decoded["objective"] == "Build ACP timeline view"
    end

    test "extracts from ACP content key" do
      plan = valid_plan_map()
      result = %{"content" => Jason.encode!(plan)}
      assert {:ok, decoded} = NanoPlanner.parse_model_output(result)
      assert decoded["objective"] == "Build ACP timeline view"
    end

    test "extracts from ACP content block list" do
      plan = valid_plan_map()

      result = %{
        "content" => [
          %{"type" => "text", "text" => "Thinking..."},
          %{"type" => "text", "text" => Jason.encode!(plan)}
        ]
      }

      assert {:ok, decoded} = NanoPlanner.parse_model_output(result)
      assert decoded["objective"] == "Build ACP timeline view"
    end

    test "returns error for garbage string" do
      assert {:error, {:invalid_model_output, msg}} = NanoPlanner.parse_model_output("not json")
      assert msg =~ "JSON parse error"
    end

    test "returns error for list value" do
      assert {:error, {:invalid_model_output, msg}} = NanoPlanner.parse_model_output([1, 2])
      assert msg =~ "expected map or string"
    end
  end

  # ── Private helpers ──────────────────────────────────────────────────

  defp atomize_keys(map) when is_map(map) do
    map
    |> Enum.map(fn {k, v} -> {String.to_atom(k), atomize_keys(v)} end)
    |> Map.new()
  end

  defp atomize_keys(list) when is_list(list) do
    Enum.map(list, &atomize_keys/1)
  end

  defp atomize_keys(value), do: value
end
