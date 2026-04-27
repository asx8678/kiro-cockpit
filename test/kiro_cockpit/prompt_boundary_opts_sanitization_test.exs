defmodule KiroCockpit.PromptBoundaryOptsSanitizationTest do
  @moduledoc """
  Regression tests for kiro-8v5: public KiroSession.prompt/3 opts must not
  override trusted server-derived boundary fields.

  The vulnerability: `prompt_boundary_opts/2` used `Keyword.merge(base, opts)`
  which let arbitrary caller opts overwrite server-derived trust/authorization
  keys like :plan_mode, :approved, :permission_level, :enabled, :swarm_ctx,
  etc.  A malicious caller could pass `plan_mode: :unlocked` or
  `approved: true` to bypass security controls.

  The fix: `sanitize_prompt_opts/1` strips every key not in the whitelist
  (`@safe_prompt_opt_keys`) before the merge, so only safe identifier and
  timeout opts survive.
  """

  use ExUnit.Case, async: true

  alias KiroCockpit.KiroSession

  # ── Unit tests for sanitize_prompt_opts/1 ──────────────────────────────

  describe "sanitize_prompt_opts/1" do
    test "strips :plan_mode — cannot override server-derived plan mode" do
      opts = [plan_mode: :unlocked, timeout: 5_000]
      assert KiroSession.sanitize_prompt_opts(opts) == [timeout: 5_000]
    end

    test "strips :approved — cannot fake approval signal" do
      opts = [approved: true, plan_id: "plan-1"]
      assert KiroSession.sanitize_prompt_opts(opts) == [plan_id: "plan-1"]
    end

    test "strips :policy_allows_write — cannot fake write permission" do
      opts = [policy_allows_write: true, task_id: "t-1"]
      assert KiroSession.sanitize_prompt_opts(opts) == [task_id: "t-1"]
    end

    test "strips :permission_level — cannot escalate permissions" do
      opts = [permission_level: :admin, agent_id: "agent-1"]
      assert KiroSession.sanitize_prompt_opts(opts) == [agent_id: "agent-1"]
    end

    test "strips :enabled — cannot disable boundary" do
      opts = [enabled: false, swarm_plan_id: "plan-1"]
      assert KiroSession.sanitize_prompt_opts(opts) == [swarm_plan_id: "plan-1"]
    end

    test "strips :swarm_ctx — cannot inject trusted context map" do
      opts = [
        swarm_ctx: %{approved: true, policy_allows_write: true, root_cause_stated: true},
        plan_id: "plan-1"
      ]

      assert KiroSession.sanitize_prompt_opts(opts) == [plan_id: "plan-1"]
    end

    test "strips :session_id — cannot impersonate another session" do
      opts = [session_id: "fake-session", timeout: 10_000]
      assert KiroSession.sanitize_prompt_opts(opts) == [timeout: 10_000]
    end

    test "strips :agent_id when not in safe whitelist context" do
      # agent_id IS in the safe whitelist because it's an identifier
      # needed for ActionBoundary hydration, NOT an authorization key.
      opts = [agent_id: "execution-agent", plan_id: "plan-1"]
      result = KiroSession.sanitize_prompt_opts(opts)
      assert Keyword.get(result, :agent_id) == "execution-agent"
      assert Keyword.get(result, :plan_id) == "plan-1"
    end

    test "strips :project_dir — cannot change project scope" do
      opts = [project_dir: "/malicious/path", timeout: 5_000]
      assert KiroSession.sanitize_prompt_opts(opts) == [timeout: 5_000]
    end

    test "strips :root_cause_stated trust flag" do
      opts = [root_cause_stated: true, plan_id: "plan-1"]
      assert KiroSession.sanitize_prompt_opts(opts) == [plan_id: "plan-1"]
    end

    test "strips :fixing_test_fixture trust flag" do
      opts = [fixing_test_fixture: true, plan_id: "plan-1"]
      assert KiroSession.sanitize_prompt_opts(opts) == [plan_id: "plan-1"]
    end

    test "strips :docs_scoped trust flag" do
      opts = [docs_scoped: true, plan_id: "plan-1"]
      assert KiroSession.sanitize_prompt_opts(opts) == [plan_id: "plan-1"]
    end

    test "strips :plan_id when not in whitelist" do
      # plan_id IS in the safe whitelist — it's an identifier for derivation,
      # not an authorization key.  The actual authorization is derived from
      # durable DB state by ActionBoundary.
      opts = [plan_id: "plan-1", approved: true]
      result = KiroSession.sanitize_prompt_opts(opts)
      assert Keyword.get(result, :plan_id) == "plan-1"
      refute Keyword.has_key?(result, :approved)
    end

    test "strips :test_bypass — cannot enable boundary bypass from prompt opts" do
      opts = [test_bypass: true, timeout: 5_000]
      assert KiroSession.sanitize_prompt_opts(opts) == [timeout: 5_000]
    end

    test "strips :hook_manager_module — cannot inject hook module" do
      opts = [hook_manager_module: MaliciousModule, timeout: 5_000]
      assert KiroSession.sanitize_prompt_opts(opts) == [timeout: 5_000]
    end

    test "strips :pre_hooks and :post_hooks — cannot inject hooks" do
      opts = [pre_hooks: [MaliciousHook], post_hooks: [BadHook], timeout: 5_000]
      assert KiroSession.sanitize_prompt_opts(opts) == [timeout: 5_000]
    end

    test "preserves safe opts: timeout" do
      opts = [timeout: 60_000]
      assert KiroSession.sanitize_prompt_opts(opts) == [timeout: 60_000]
    end

    test "preserves safe opts: plan_id, task_id, agent_id, swarm_plan_id" do
      opts = [
        plan_id: "plan-abc",
        task_id: "task-123",
        agent_id: "execution-agent",
        swarm_plan_id: "plan-abc"
      ]

      result = KiroSession.sanitize_prompt_opts(opts)
      assert Keyword.get(result, :plan_id) == "plan-abc"
      assert Keyword.get(result, :task_id) == "task-123"
      assert Keyword.get(result, :agent_id) == "execution-agent"
      assert Keyword.get(result, :swarm_plan_id) == "plan-abc"
      assert length(result) == 4
    end

    test "returns empty list for empty opts" do
      assert KiroSession.sanitize_prompt_opts([]) == []
    end

    test "returns empty list when all keys are trust-bearing" do
      opts = [
        plan_mode: :unlocked,
        approved: true,
        permission_level: :admin,
        enabled: false,
        swarm_ctx: %{approved: true},
        session_id: "fake",
        project_dir: "/evil"
      ]

      assert KiroSession.sanitize_prompt_opts(opts) == []
    end

    test "mixed safe and unsafe keys: only safe survive" do
      opts = [
        timeout: 30_000,
        plan_id: "plan-1",
        plan_mode: :unlocked,
        approved: true,
        policy_allows_write: true,
        permission_level: :executor_dispatch,
        enabled: false,
        swarm_ctx: %{approved: true},
        session_id: "fake-session",
        project_dir: "/evil",
        root_cause_stated: true,
        fixing_test_fixture: true,
        docs_scoped: true,
        test_bypass: true,
        task_id: "task-1",
        agent_id: "agent-1",
        swarm_plan_id: "plan-1",
        hook_manager_module: BadModule,
        pre_hooks: [BadHook]
      ]

      result = KiroSession.sanitize_prompt_opts(opts)
      assert Keyword.get(result, :timeout) == 30_000
      assert Keyword.get(result, :plan_id) == "plan-1"
      assert Keyword.get(result, :task_id) == "task-1"
      assert Keyword.get(result, :agent_id) == "agent-1"
      assert Keyword.get(result, :swarm_plan_id) == "plan-1"
      assert length(result) == 5

      # Verify ALL trust-bearing keys are gone
      refute Keyword.has_key?(result, :plan_mode)
      refute Keyword.has_key?(result, :approved)
      refute Keyword.has_key?(result, :policy_allows_write)
      refute Keyword.has_key?(result, :permission_level)
      refute Keyword.has_key?(result, :enabled)
      refute Keyword.has_key?(result, :swarm_ctx)
      refute Keyword.has_key?(result, :session_id)
      refute Keyword.has_key?(result, :project_dir)
      refute Keyword.has_key?(result, :root_cause_stated)
      refute Keyword.has_key?(result, :fixing_test_fixture)
      refute Keyword.has_key?(result, :docs_scoped)
      refute Keyword.has_key?(result, :test_bypass)
      refute Keyword.has_key?(result, :hook_manager_module)
      refute Keyword.has_key?(result, :pre_hooks)
      refute Keyword.has_key?(result, :post_hooks)
    end
  end

  # ── Regression: malicious opts cannot override locked plan_mode ──────────

  describe "kiro-8v5 regression: locked plan_mode not overridable via opts" do
    test "sanitize_prompt_opts strips plan_mode regardless of value type" do
      # Even if someone passes a PlanMode struct, it gets stripped
      opts = [plan_mode: %{status: :unlocked, reason: :evil}, timeout: 5_000]
      result = KiroSession.sanitize_prompt_opts(opts)
      refute Keyword.has_key?(result, :plan_mode)
      assert Keyword.get(result, :timeout) == 5_000
    end

    test "sanitize_prompt_opts strips approved even with non-boolean value" do
      opts = [approved: 1, approved: "true", timeout: 5_000]
      result = KiroSession.sanitize_prompt_opts(opts)
      refute Keyword.has_key?(result, :approved)
    end
  end

  # ── Regression: swarm_ctx injection blocked ──────────────────────────────

  describe "kiro-8v5 regression: swarm_ctx injection blocked" do
    test "swarm_ctx with approved: true is completely stripped" do
      # This is the NanoPlanner pattern — it passes swarm_ctx: %{approved: true}
      # through prompt opts.  After kiro-8v5, this is stripped because it's
      # a trust-bearing key.  The ActionBoundary's derive_approved_from_durable_state
      # will derive approved from DB plan status instead.
      opts = [
        swarm_ctx: %{approved: true, policy_allows_write: true},
        plan_id: "legit-plan",
        timeout: 30_000
      ]

      result = KiroSession.sanitize_prompt_opts(opts)
      refute Keyword.has_key?(result, :swarm_ctx)
      assert Keyword.get(result, :plan_id) == "legit-plan"
      assert Keyword.get(result, :timeout) == 30_000
    end

    test "swarm_ctx with nested trust flags is stripped entirely" do
      opts = [
        swarm_ctx: %{
          approved: true,
          policy_allows_write: true,
          root_cause_stated: true,
          fixing_test_fixture: true,
          docs_scoped: true
        },
        task_id: "t-1"
      ]

      result = KiroSession.sanitize_prompt_opts(opts)
      refute Keyword.has_key?(result, :swarm_ctx)
      assert Keyword.get(result, :task_id) == "t-1"
    end

    test "top-level approved key is stripped even without swarm_ctx" do
      opts = [approved: true, plan_id: "plan-1"]
      result = KiroSession.sanitize_prompt_opts(opts)
      refute Keyword.has_key?(result, :approved)
      assert Keyword.get(result, :plan_id) == "plan-1"
    end
  end

  # ── Regression: permission escalation blocked ────────────────────────────

  describe "kiro-8v5 regression: permission escalation blocked" do
    test "permission_level :admin is stripped" do
      opts = [permission_level: :admin, timeout: 5_000]
      result = KiroSession.sanitize_prompt_opts(opts)
      refute Keyword.has_key?(result, :permission_level)
    end

    test "permission_level :write is stripped" do
      opts = [permission_level: :write, timeout: 5_000]
      result = KiroSession.sanitize_prompt_opts(opts)
      refute Keyword.has_key?(result, :permission_level)
    end

    test "enabled: false (boundary disable attempt) is stripped" do
      opts = [enabled: false, timeout: 5_000]
      result = KiroSession.sanitize_prompt_opts(opts)
      refute Keyword.has_key?(result, :enabled)
    end
  end

  # ── Regression: identity impersonation blocked ──────────────────────────

  describe "kiro-8v5 regression: identity impersonation blocked" do
    test "session_id override is stripped" do
      opts = [session_id: "stolen-session", plan_id: "plan-1"]
      result = KiroSession.sanitize_prompt_opts(opts)
      refute Keyword.has_key?(result, :session_id)
      assert Keyword.get(result, :plan_id) == "plan-1"
    end

    test "project_dir override is stripped" do
      opts = [project_dir: "/etc/shadow", plan_id: "plan-1"]
      result = KiroSession.sanitize_prompt_opts(opts)
      refute Keyword.has_key?(result, :project_dir)
    end
  end
end
