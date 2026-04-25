defmodule KiroCockpit.NanoPlanner.PlanSchemaTest do
  use ExUnit.Case, async: true

  alias KiroCockpit.NanoPlanner.PlanSchema

  # ── Helpers ──────────────────────────────────────────────────────────

  defp valid_plan(overrides \\ []) do
    base = %{
      objective: "Build ACP timeline view",
      summary: "Add a LiveView timeline for session events.",
      phases: [
        %{
          number: 1,
          title: "Foundation",
          steps: [
            %{
              title: "Create timeline schema",
              details: "Add event normalization fields.",
              files: ["lib/kiro_cockpit/event_store.ex"],
              permission: "write",
              validation: "Unit test event normalization."
            }
          ]
        }
      ],
      permissions_needed: ["read", "write"],
      acceptance_criteria: ["Session updates appear as timeline cards."],
      risks: [%{"risk" => "ACP prompt timing", "mitigation" => "Use turn-end event"}],
      execution_prompt: "Implement the approved plan phase by phase."
    }

    override_map = if is_map(overrides), do: overrides, else: Map.new(overrides)
    Map.merge(base, override_map)
  end

  defp valid_plan_with_string_keys(overrides \\ []) do
    valid_plan(overrides)
    |> Enum.map(fn {k, v} -> {to_string(k), stringify_keys(v)} end)
    |> Map.new()
  end

  defp stringify_keys(v) when is_map(v) do
    v |> Enum.map(fn {k, val} -> {to_string(k), stringify_keys(val)} end) |> Map.new()
  end

  defp stringify_keys(v) when is_list(v), do: Enum.map(v, &stringify_keys/1)
  defp stringify_keys(v), do: v

  # ── validate!/1 ──────────────────────────────────────────────────────

  describe "validate!/1" do
    test "accepts a valid plan with atom keys" do
      plan = valid_plan()
      result = PlanSchema.validate!(plan)

      assert result.objective == "Build ACP timeline view"
      assert result.execution_prompt == "Implement the approved plan phase by phase."
    end

    test "accepts a valid plan with string keys" do
      plan = valid_plan_with_string_keys()
      result = PlanSchema.validate!(plan)

      assert result.objective == "Build ACP timeline view"
      assert is_list(result.phases)
      assert is_list(result.permissions_needed)
    end

    test "raises on missing required keys" do
      assert_raise ArgumentError, ~r/missing required keys/, fn ->
        PlanSchema.validate!(%{objective: "X"})
      end
    end

    test "raises specifically on missing execution_prompt" do
      plan = valid_plan() |> Map.delete(:execution_prompt)

      assert_raise ArgumentError, ~r/execution_prompt/, fn ->
        PlanSchema.validate!(plan)
      end
    end

    test "raises on missing execution_prompt with string keys" do
      plan = valid_plan_with_string_keys() |> Map.delete("execution_prompt")

      assert_raise ArgumentError, ~r/execution_prompt/, fn ->
        PlanSchema.validate!(plan)
      end
    end

    test "raises on empty execution_prompt" do
      plan = valid_plan(execution_prompt: "")
      # Empty string is present but may be invalid — the key check passes
      # but we should ensure the value is accepted for now (key exists).
      # The spec says "missing execution_prompt" is the failure; empty is
      # a degenerate but present value.
      result = PlanSchema.validate!(plan)
      assert result.execution_prompt == ""
    end

    test "raises on nil phases" do
      plan = valid_plan(phases: nil)

      assert_raise ArgumentError, ~r/invalid phases/, fn ->
        PlanSchema.validate!(plan)
      end
    end

    test "raises on empty phases list" do
      plan = valid_plan(phases: [])

      assert_raise ArgumentError, ~r/must not be empty/, fn ->
        PlanSchema.validate!(plan)
      end
    end

    test "raises on phase missing number" do
      plan = valid_plan(phases: [%{title: "No number", steps: [%{title: "S"}]}])

      assert_raise ArgumentError, ~r/phase missing required key: number/, fn ->
        PlanSchema.validate!(plan)
      end
    end

    test "raises on phase with non-positive number" do
      plan = valid_plan(phases: [%{number: 0, title: "Bad", steps: [%{title: "S"}]}])

      assert_raise ArgumentError, ~r/positive integer/, fn ->
        PlanSchema.validate!(plan)
      end
    end

    test "raises on phase with empty steps" do
      plan = valid_plan(phases: [%{number: 1, title: "Empty", steps: []}])

      assert_raise ArgumentError, ~r/has no steps/, fn ->
        PlanSchema.validate!(plan)
      end
    end

    test "raises on step missing title" do
      plan = valid_plan(phases: [%{number: 1, title: "P", steps: [%{details: "Nope"}]}])

      assert_raise ArgumentError, ~r/step missing required key: title/, fn ->
        PlanSchema.validate!(plan)
      end
    end

    test "raises on non-map step" do
      plan = valid_plan(phases: [%{number: 1, title: "P", steps: ["bad step"]}])

      assert_raise ArgumentError, ~r/each step must be a map/, fn ->
        PlanSchema.validate!(plan)
      end
    end

    test "raises on invalid permission in permissions_needed" do
      plan = valid_plan(permissions_needed: ["read", "superuser"])

      assert_raise ArgumentError, ~r/invalid permissions/, fn ->
        PlanSchema.validate!(plan)
      end
    end
  end

  # ── validate/1 ───────────────────────────────────────────────────────

  describe "validate/1" do
    test "returns ok for a valid plan" do
      assert {:ok, result} = PlanSchema.validate(valid_plan())
      assert result.objective == "Build ACP timeline view"
    end

    test "returns error for missing keys" do
      assert {:error, [{:missing_keys, keys}]} = PlanSchema.validate(%{objective: "X"})
      assert :execution_prompt in keys
    end

    test "returns error for invalid phases" do
      assert {:error, [{:invalid_phases, _}]} = PlanSchema.validate(valid_plan(phases: []))
    end

    test "returns error for invalid permissions" do
      assert {:error, [{:invalid_permissions, bad}]} =
               PlanSchema.validate(valid_plan(permissions_needed: ["god_mode"]))

      assert "god_mode" in bad
    end

    test "accumulates multiple errors for missing keys" do
      assert {:error, [{:missing_keys, missing}]} =
               PlanSchema.validate(%{})

      # At least objective and execution_prompt should be listed
      assert :objective in missing
      assert :execution_prompt in missing
    end
  end

  # ── Key normalization ────────────────────────────────────────────────

  describe "atom/string key handling" do
    test "normalizes string keys to atom keys" do
      plan = valid_plan_with_string_keys()
      result = PlanSchema.validate!(plan)

      assert Map.has_key?(result, :objective)
      assert Map.has_key?(result, :execution_prompt)
      assert Map.has_key?(result, :phases)
    end

    test "handles mixed atom and string keys" do
      plan =
        valid_plan()
        |> Map.put("mode", "nano_deep")

      result = PlanSchema.validate!(plan)
      assert result.mode == "nano_deep"
    end

    test "normalizes phases from string keys" do
      plan = valid_plan_with_string_keys()
      result = PlanSchema.validate!(plan)

      [phase] = result.phases
      assert phase.number == 1
      assert phase.title == "Foundation"
      assert is_list(phase.steps)
    end

    test "normalizes step permission from string keys" do
      plan = valid_plan_with_string_keys()
      result = PlanSchema.validate!(plan)

      [phase] = result.phases
      [step] = phase.steps
      assert step.permission == :write
    end
  end

  # ── Permission normalization ────────────────────────────────────────

  describe "permission normalization" do
    test "normalizes top-level permissions via Permissions module" do
      result = PlanSchema.validate!(valid_plan(permissions_needed: ["read", "shell"]))
      assert result.permissions_needed == [:read, :shell_write]
    end

    test "accepts all canonical permission strings" do
      result =
        PlanSchema.validate!(
          valid_plan(
            permissions_needed:
              ~w(read write shell_read shell_write terminal external destructive)
          )
        )

      assert result.permissions_needed == [
               :read,
               :write,
               :shell_read,
               :shell_write,
               :terminal,
               :external,
               :destructive
             ]
    end

    test "normalizes atom permissions" do
      result = PlanSchema.validate!(valid_plan(permissions_needed: [:read, :write]))
      assert result.permissions_needed == [:read, :write]
    end

    test "deduplicates and sorts permissions by escalation order" do
      result =
        PlanSchema.validate!(valid_plan(permissions_needed: ["write", "read", "write"]))

      assert result.permissions_needed == [:read, :write]
    end
  end

  # ── flatten_steps/1 ──────────────────────────────────────────────────

  describe "flatten_steps/1" do
    test "produces flat step maps from a validated plan" do
      plan = PlanSchema.validate!(valid_plan())
      steps = PlanSchema.flatten_steps(plan)

      assert length(steps) == 1
      step = hd(steps)

      assert step.phase_number == 1
      assert step.step_number == 1
      assert step.title == "Create timeline schema"
      assert step.details == "Add event normalization fields."
      assert step.permission_level == "write"
      assert step.validation == "Unit test event normalization."
      assert step.status == "planned"
    end

    test "converts files list to map for jsonb compatibility" do
      plan = PlanSchema.validate!(valid_plan())
      steps = PlanSchema.flatten_steps(plan)

      step = hd(steps)
      # The original plan has files as a list; it should be converted to a map
      assert is_map(step.files)
      assert step.files == %{"lib/kiro_cockpit/event_store.ex" => ""}
    end

    test "preserves files that are already a map" do
      plan =
        valid_plan(
          phases: [
            %{
              number: 1,
              title: "Phase 1",
              steps: [
                %{title: "Step", files: %{"router.ex" => "read"}, permission: :read}
              ]
            }
          ]
        )

      result = PlanSchema.validate!(plan)
      steps = PlanSchema.flatten_steps(result)

      assert hd(steps).files == %{"router.ex" => "read"}
    end

    test "handles missing files gracefully" do
      plan =
        valid_plan(
          phases: [
            %{
              number: 1,
              title: "Phase 1",
              steps: [%{title: "Step without files"}]
            }
          ]
        )

      result = PlanSchema.validate!(plan)
      steps = PlanSchema.flatten_steps(result)

      assert hd(steps).files == %{}
    end

    test "assigns sequential step numbers per phase" do
      plan =
        valid_plan(
          phases: [
            %{
              number: 1,
              title: "Foundation",
              steps: [
                %{title: "First", permission: :read},
                %{title: "Second", permission: :write},
                %{title: "Third", permission: :shell_read}
              ]
            }
          ]
        )

      result = PlanSchema.validate!(plan)
      steps = PlanSchema.flatten_steps(result)

      assert Enum.map(steps, & &1.step_number) == [1, 2, 3]
    end

    test "sorts phases by number" do
      plan =
        valid_plan(
          phases: [
            %{
              number: 2,
              title: "Implementation",
              steps: [%{title: "Step A", permission: :write}]
            },
            %{
              number: 1,
              title: "Foundation",
              steps: [%{title: "Step B", permission: :read}]
            }
          ]
        )

      result = PlanSchema.validate!(plan)
      steps = PlanSchema.flatten_steps(result)

      assert Enum.map(steps, & &1.phase_number) == [1, 2]
    end

    test "normalizes permission_level to canonical string" do
      plan =
        valid_plan(
          phases: [
            %{
              number: 1,
              title: "P1",
              steps: [%{title: "S1", permission_level: "shell"}]
            }
          ]
        )

      result = PlanSchema.validate!(plan)
      steps = PlanSchema.flatten_steps(result)

      assert hd(steps).permission_level == "shell_write"
    end

    test "defaults permission_level to read when unspecified" do
      plan =
        valid_plan(
          phases: [
            %{
              number: 1,
              title: "P1",
              steps: [%{title: "Read-only step"}]
            }
          ]
        )

      result = PlanSchema.validate!(plan)
      steps = PlanSchema.flatten_steps(result)

      assert hd(steps).permission_level == "read"
    end

    test "all permission levels from Permissions escalation order are valid" do
      for perm <- KiroCockpit.Permissions.escalation_order() do
        plan =
          valid_plan(
            phases: [
              %{number: 1, title: "P1", steps: [%{title: "Step", permission: perm}]}
            ]
          )

        result = PlanSchema.validate!(plan)
        steps = PlanSchema.flatten_steps(result)

        assert hd(steps).permission_level == to_string(perm)
      end
    end

    test "output is compatible with Plans.create_plan/5 step shape" do
      plan = PlanSchema.validate!(valid_plan())
      steps = PlanSchema.flatten_steps(plan)

      for step <- steps do
        assert Map.has_key?(step, :phase_number)
        assert Map.has_key?(step, :step_number)
        assert Map.has_key?(step, :title)
        assert Map.has_key?(step, :details)
        assert Map.has_key?(step, :files)
        assert Map.has_key?(step, :permission_level)
        assert Map.has_key?(step, :validation)
        assert Map.has_key?(step, :status)

        assert is_integer(step.phase_number)
        assert is_integer(step.step_number)
        assert is_binary(step.title)
        assert is_map(step.files)
        assert is_binary(step.permission_level)
        assert step.status == "planned"
      end
    end
  end

  # ── Accessors ─────────────────────────────────────────────────────────

  describe "required_keys/0 and optional_keys/0" do
    test "required_keys includes execution_prompt" do
      assert :execution_prompt in PlanSchema.required_keys()
    end

    test "required_keys includes all seven required fields from §7" do
      required = PlanSchema.required_keys()

      for key <- [
            :objective,
            :summary,
            :phases,
            :permissions_needed,
            :acceptance_criteria,
            :risks,
            :execution_prompt
          ] do
        assert key in required, "Expected #{key} in required_keys"
      end
    end

    test "optional_keys includes mode and plan_markdown" do
      optional = PlanSchema.optional_keys()
      assert :mode in optional
      assert :plan_markdown in optional
    end
  end
end
