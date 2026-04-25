defmodule KiroCockpit.Support.FakeNanoPlanner do
  @moduledoc """
  Fake implementation of NanoPlanner for testing.

  Does not require a real Kiro subprocess or model. Generates
  deterministic test plans directly via KiroCockpit.Plans context.
  """

  alias KiroCockpit.Plans

  @doc """
  Fake plan/3 that creates a plan directly in the database.
  """
  def plan(_session, user_request, opts \\ []) do
    session_id = Keyword.get(opts, :session_id, "test-session")
    mode = Keyword.get(opts, :mode, :nano)

    steps = generate_fake_steps()

    raw_output = %{
      "objective" => user_request,
      "summary" => "Fake plan for testing: #{user_request}",
      "phases" => [
        %{
          "number" => 1,
          "title" => "Phase 1",
          "steps" => [
            %{"title" => "Step 1", "permission" => "read"},
            %{"title" => "Step 2", "permission" => "write"}
          ]
        }
      ],
      "permissions_needed" => ["read", "write"],
      "acceptance_criteria" => ["Test passes", "Code compiles"],
      "risks" => [
        %{"description" => "May break existing tests", "mitigation" => "Run full test suite"}
      ],
      "execution_prompt" => "Execute the plan: #{user_request}"
    }

    opts = [
      plan_markdown: "## #{user_request}\n\nThis is a fake plan for testing.",
      execution_prompt: raw_output["execution_prompt"],
      raw_model_output: raw_output,
      project_snapshot_hash: "fake-hash-#{System.unique_integer([:positive])}"
    ]

    Plans.create_plan(session_id, user_request, mode, steps, opts)
  end

  @doc """
  Fake approve/3 that just delegates to Plans context.
  """
  def approve(_session, plan_id, _opts \\ []) do
    case Plans.approve_plan(plan_id) do
      {:ok, plan} -> {:ok, %{plan: plan, prompt_result: %{"status" => "sent"}}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Fake revise/4 that creates a new plan version.
  """
  def revise(_session, plan_id, revision_request, opts \\ []) do
    with {:ok, old_plan} <- fetch_plan(plan_id) do
      session_id = Keyword.get(opts, :session_id, old_plan.session_id)
      mode = Keyword.get(opts, :mode, old_plan.mode)

      combined_request = "#{revision_request}\n\n(Revision of: #{old_plan.user_request})"

      steps = generate_fake_steps()

      opts = [
        plan_markdown: "## Revised: #{combined_request}",
        execution_prompt: "Execute revised plan: #{combined_request}",
        raw_model_output: %{
          "objective" => combined_request,
          "summary" => "Revised fake plan",
          "phases" => [
            %{
              "number" => 1,
              "title" => "Revised Phase",
              "steps" => [%{"title" => "Revised Step"}]
            }
          ],
          "permissions_needed" => ["read"],
          "acceptance_criteria" => ["Revised criterion"],
          "risks" => [],
          "execution_prompt" => "Execute revised plan"
        },
        project_snapshot_hash: old_plan.project_snapshot_hash
      ]

      case Plans.create_plan(session_id, combined_request, mode, steps, opts) do
        {:ok, new_plan} ->
          # Supersede the old plan
          Plans.update_status(plan_id, "superseded", %{"replaced_by" => new_plan.id})
          {:ok, new_plan}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp fetch_plan(plan_id) do
    case Plans.get_plan(plan_id) do
      nil -> {:error, :not_found}
      plan -> {:ok, plan}
    end
  end

  defp generate_fake_steps do
    [
      %{
        phase_number: 1,
        step_number: 1,
        title: "Read project structure",
        details: "Analyze existing code",
        permission_level: "read",
        validation: "Tree visible",
        files: %{}
      },
      %{
        phase_number: 1,
        step_number: 2,
        title: "Modify files",
        details: "Apply requested changes",
        permission_level: "write",
        validation: "Changes applied",
        files: %{"test.ex" => "content"}
      }
    ]
  end
end
