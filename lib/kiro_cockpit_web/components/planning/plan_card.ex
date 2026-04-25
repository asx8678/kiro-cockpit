defmodule KiroCockpitWeb.Components.Planning.PlanCard do
  @moduledoc """
  Component for rendering a NanoPlanner plan card.

  Displays plan details including:
  - Objective and summary
  - Status badge with color coding
  - Mode indicator (nano, nano_deep, nano_fix)
  - Phases and steps with permission levels
  - Acceptance criteria
  - Risks
  - Permission requirements
  - Execution prompt preview

  ## Examples

      <.plan_card
        plan={@plan}
        expanded={false}
        on_approve="approve_plan"
        on_revise="revise_plan"
        on_reject="reject_plan"
        on_run="run_plan"
      />
  """
  use Phoenix.Component

  import KiroCockpitWeb.Components.Planning.PermissionBadge

  alias KiroCockpit.Permissions
  alias KiroCockpit.Plans.Plan

  @event_styles %{
    "created" => {"hero-document-plus", "text-blue-500"},
    "approved" => {"hero-check-circle", "text-emerald-500"},
    "rejected" => {"hero-x-circle", "text-rose-500"},
    "revised" => {"hero-arrow-path", "text-amber-500"},
    "running" => {"hero-play-circle", "text-blue-500"},
    "completed" => {"hero-flag", "text-green-500"},
    "failed" => {"hero-exclamation-circle", "text-red-500"},
    "superseded" => {"hero-archive-box", "text-gray-500"}
  }
  @default_event_style {"hero-clock", "text-gray-400"}

  @status_configs %{
    "draft" => %{color: "bg-slate-100 text-slate-800 border-slate-200", icon: "hero-document"},
    "approved" => %{
      color: "bg-emerald-100 text-emerald-800 border-emerald-200",
      icon: "hero-check-circle"
    },
    "running" => %{color: "bg-blue-100 text-blue-800 border-blue-200", icon: "hero-play-circle"},
    "completed" => %{color: "bg-green-100 text-green-800 border-green-200", icon: "hero-flag"},
    "rejected" => %{color: "bg-rose-100 text-rose-800 border-rose-200", icon: "hero-x-circle"},
    "superseded" => %{color: "bg-gray-100 text-gray-800 border-gray-200", icon: "hero-arrow-path"},
    "failed" => %{
      color: "bg-red-100 text-red-800 border-red-200",
      icon: "hero-exclamation-circle"
    }
  }

  @mode_labels %{
    "nano" => "Nano",
    "nano_deep" => "Nano Deep",
    "nano_fix" => "Nano Fix"
  }

  attr :plan, Plan, required: true
  attr :expanded, :boolean, default: false
  attr :selected, :boolean, default: false
  attr :on_approve, :string, default: nil
  attr :on_revise, :string, default: nil
  attr :on_reject, :string, default: nil
  attr :on_run, :string, default: nil
  attr :on_expand, :string, default: nil
  attr :on_select, :string, default: nil
  attr :class, :string, default: nil

  def plan_card(assigns) do
    assigns
    |> assign(
      :status_config,
      Map.get(@status_configs, assigns.plan.status, @status_configs["draft"])
    )
    |> assign(:mode_label, Map.get(@mode_labels, assigns.plan.mode, assigns.plan.mode))
    |> assign(:permissions, extract_permissions(assigns.plan))
    |> render_card()
  end

  defp render_card(assigns) do
    ~H"""
    <div class={[
      "rounded-lg border bg-white shadow-sm transition-all",
      @selected && "ring-2 ring-blue-500 border-blue-500",
      !@selected && "border-gray-200 hover:border-gray-300",
      @class
    ]}>
      <%!-- Card Header --%>
      <div class="flex items-start justify-between p-4 border-b border-gray-100">
        <div class="flex-1 min-w-0">
          <div class="flex items-center gap-2 mb-1">
            <.status_badge status={@plan.status} config={@status_config} />
            <.mode_badge mode={@plan.mode} label={@mode_label} />
            <span class="text-xs text-gray-400">
              {format_timestamp(@plan.inserted_at)}
            </span>
          </div>
          <h3
            class="font-semibold text-gray-900 truncate cursor-pointer"
            phx-click={@on_select}
            phx-value-id={@plan.id}
          >
            {truncate(@plan.user_request, 80)}
          </h3>
        </div>
        <div class="flex items-center gap-1 ml-2">
          <button
            :if={@on_expand}
            type="button"
            phx-click={@on_expand}
            phx-value-id={@plan.id}
            class="p-1.5 rounded-md hover:bg-gray-100 text-gray-500"
            aria-label={(@expanded && "Collapse") || "Expand"}
          >
            <.icon
              name={(@expanded && "hero-chevron-up") || "hero-chevron-down"}
              class="h-5 w-5"
            />
          </button>
        </div>
      </div>

      <%!-- Summary Section --%>
      <div class="px-4 py-3 border-b border-gray-100">
        <p class="text-sm text-gray-600 line-clamp-2">
          {@plan.plan_markdown || "No summary available"}
        </p>
      </div>

      <%!-- Permissions Rail --%>
      <div :if={@permissions != []} class="px-4 py-2 bg-gray-50 border-b border-gray-100">
        <div class="flex items-center gap-1.5 flex-wrap">
          <span class="text-xs text-gray-500 mr-1">Permissions:</span>
          <%= for perm <- @permissions do %>
            <.permission_badge permission={perm} size={:sm} />
          <% end %>
        </div>
      </div>

      <%!-- Expanded Content --%>
      <div :if={@expanded} class="border-t border-gray-100">
        <%!-- Phases and Steps --%>
        <div :if={@plan.plan_steps != []} class="p-4 border-b border-gray-100">
          <h4 class="text-sm font-semibold text-gray-900 mb-3">Phases & Steps</h4>
          <.phases_list steps={@plan.plan_steps} />
        </div>

        <%!-- Acceptance Criteria --%>
        <.criteria_section plan={@plan} />

        <%!-- Risks --%>
        <.risks_section plan={@plan} />

        <%!-- Execution Preview --%>
        <div
          :if={@plan.execution_prompt && @plan.execution_prompt != ""}
          class="p-4 border-b border-gray-100"
        >
          <h4 class="text-sm font-semibold text-gray-900 mb-2">Execution Prompt Preview</h4>
          <div class="bg-gray-900 rounded-md p-3 overflow-x-auto">
            <pre class="text-xs text-gray-300 whitespace-pre-wrap"><%= truncate(@plan.execution_prompt, 500) %></pre>
          </div>
        </div>

        <%!-- Raw Model Output --%>
        <div :if={has_raw_output?(@plan)} class="p-4 border-b border-gray-100">
          <h4 class="text-sm font-semibold text-gray-900 mb-2">Raw Model Output</h4>
          <div class="bg-gray-50 rounded-md p-3 overflow-x-auto border border-gray-200">
            <pre class="text-xs text-gray-600 whitespace-pre-wrap"><%= format_raw_output(@plan.raw_model_output) %></pre>
          </div>
        </div>

        <%!-- Plan Events --%>
        <div :if={@plan.plan_events != []} class="p-4 border-b border-gray-100">
          <h4 class="text-sm font-semibold text-gray-900 mb-2">History</h4>
          <.events_list events={@plan.plan_events} />
        </div>
      </div>

      <%!-- Action Buttons --%>
      <div class="flex items-center gap-2 p-3 bg-gray-50 rounded-b-lg">
        <button
          :if={@on_approve && @plan.status == "draft"}
          type="button"
          phx-click={@on_approve}
          phx-value-id={@plan.id}
          class="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-md bg-emerald-600 text-white text-sm font-medium hover:bg-emerald-700"
        >
          <.icon name="hero-check" class="h-4 w-4" /> Approve
        </button>

        <button
          :if={@on_revise}
          type="button"
          phx-click={@on_revise}
          phx-value-id={@plan.id}
          class="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-md bg-amber-100 text-amber-800 text-sm font-medium hover:bg-amber-200"
        >
          <.icon name="hero-arrow-path" class="h-4 w-4" /> Revise
        </button>

        <button
          :if={@on_reject && @plan.status in ["draft", "approved"]}
          type="button"
          phx-click={@on_reject}
          phx-value-id={@plan.id}
          class="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-md bg-rose-100 text-rose-800 text-sm font-medium hover:bg-rose-200"
        >
          <.icon name="hero-x-mark" class="h-4 w-4" /> Reject
        </button>

        <button
          :if={@on_run && @plan.status == "approved"}
          type="button"
          phx-click={@on_run}
          phx-value-id={@plan.id}
          class="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-md bg-blue-600 text-white text-sm font-medium hover:bg-blue-700"
        >
          <.icon name="hero-play" class="h-4 w-4" /> Run
        </button>

        <div class="flex-1"></div>

        <span class="text-xs text-gray-400">
          {count_steps(@plan.plan_steps)} steps
        </span>
      </div>
    </div>
    """
  end

  defp status_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs font-medium border",
      @config.color
    ]}>
      <.icon name={@config.icon} class="h-3.5 w-3.5" />
      {String.capitalize(@status)}
    </span>
    """
  end

  defp mode_badge(assigns) do
    ~H"""
    <span class="inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium bg-purple-100 text-purple-800 border border-purple-200">
      {@label}
    </span>
    """
  end

  defp phases_list(assigns) do
    steps_by_phase = Enum.group_by(assigns.steps, & &1.phase_number)
    sorted_phases = Enum.sort_by(Map.keys(steps_by_phase), & &1)

    assigns
    |> assign(:phases, sorted_phases)
    |> assign(:steps_by_phase, steps_by_phase)
    |> render_phases()
  end

  defp render_phases(assigns) do
    ~H"""
    <div class="space-y-4">
      <%= for phase_num <- @phases do %>
        <% steps = Map.get(@steps_by_phase, phase_num) %>
        <div class="border-l-2 border-blue-200 pl-3">
          <div class="flex items-center gap-2 mb-2">
            <span class="text-xs font-semibold text-blue-700 bg-blue-50 px-2 py-0.5 rounded">
              Phase {phase_num}
            </span>
          </div>
          <div class="space-y-2">
            <%= for step <- Enum.sort_by(steps, & &1.step_number) do %>
              <.step_item step={step} />
            <% end %>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  defp step_item(assigns) do
    ~H"""
    <div class="flex items-start gap-2 text-sm">
      <span class="flex-none w-6 h-6 rounded-full bg-gray-100 text-gray-600 flex items-center justify-center text-xs font-medium">
        {@step.step_number}
      </span>
      <div class="flex-1 min-w-0">
        <div class="flex items-center gap-2">
          <span class="font-medium text-gray-900">{@step.title}</span>
          <.permission_badge permission={@step.permission_level} size={:xs} />
        </div>
        <p :if={@step.details} class="text-gray-600 text-xs mt-0.5">{@step.details}</p>
        <p :if={@step.validation} class="text-gray-500 text-xs mt-0.5">
          <span class="font-medium">Validation:</span> {@step.validation}
        </p>
      </div>
    </div>
    """
  end

  defp criteria_section(assigns) do
    criteria = extract_criteria(assigns.plan)

    assigns
    |> assign(:criteria, criteria)
    |> render_criteria()
  end

  defp render_criteria(%{criteria: []} = assigns) do
    ~H"""
    <div></div>
    """
  end

  defp render_criteria(assigns) do
    ~H"""
    <div class="p-4 border-b border-gray-100">
      <h4 class="text-sm font-semibold text-gray-900 mb-2">Acceptance Criteria</h4>
      <ul class="space-y-1">
        <%= for criterion <- @criteria do %>
          <li class="flex items-start gap-2 text-sm text-gray-600">
            <.icon name="hero-check-badge" class="h-4 w-4 text-emerald-500 flex-none mt-0.5" />
            <span>{criterion}</span>
          </li>
        <% end %>
      </ul>
    </div>
    """
  end

  defp risks_section(assigns) do
    risks = extract_risks(assigns.plan)

    assigns
    |> assign(:risks, risks)
    |> render_risks()
  end

  defp render_risks(%{risks: []} = assigns) do
    ~H"""
    <div></div>
    """
  end

  defp render_risks(assigns) do
    ~H"""
    <div class="p-4 border-b border-gray-100">
      <h4 class="text-sm font-semibold text-gray-900 mb-2">Risks</h4>
      <ul class="space-y-2">
        <%= for risk <- @risks do %>
          <li class="flex items-start gap-2 text-sm">
            <.icon name="hero-exclamation-triangle" class="h-4 w-4 text-amber-500 flex-none mt-0.5" />
            <div class="text-gray-600">
              <%= if is_map(risk) do %>
                <div class="font-medium text-gray-800">
                  {Map.get(risk, "description") || Map.get(risk, :description) || "Risk"}
                </div>
                <div
                  :if={Map.get(risk, "mitigation") || Map.get(risk, :mitigation)}
                  class="text-xs mt-0.5"
                >
                  <span class="font-medium">Mitigation:</span> {Map.get(risk, "mitigation") ||
                    Map.get(risk, :mitigation)}
                </div>
              <% else %>
                {risk}
              <% end %>
            </div>
          </li>
        <% end %>
      </ul>
    </div>
    """
  end

  defp events_list(assigns) do
    sorted_events = Enum.sort_by(assigns.events, & &1.created_at, {:desc, DateTime})

    assigns
    |> assign(:sorted_events, sorted_events)
    |> render_events()
  end

  defp render_events(assigns) do
    ~H"""
    <div class="space-y-2 max-h-48 overflow-y-auto">
      <%= for event <- @sorted_events do %>
        <div class="flex items-center gap-2 text-sm">
          <.event_type_icon type={event.event_type} />
          <span class="text-gray-600">{String.capitalize(event.event_type)}</span>
          <span class="text-gray-400 text-xs ml-auto">
            {format_timestamp(event.created_at)}
          </span>
        </div>
      <% end %>
    </div>
    """
  end

  defp event_type_icon(assigns) do
    {icon_name, color_class} = event_style(Map.get(assigns, :type, ""))

    assigns
    |> assign(:icon_name, icon_name)
    |> assign(:color_class, color_class)
    |> render_event_icon()
  end

  defp event_style(type) when is_binary(type) do
    Map.get(@event_styles, type, @default_event_style)
  end

  defp event_style(_), do: @default_event_style

  defp render_event_icon(assigns) do
    ~H"""
    <.icon name={@icon_name} class={["h-4 w-4 flex-none", @color_class]} />
    """
  end

  # Helper functions

  defp extract_permissions(%Plan{raw_model_output: nil}), do: []

  defp extract_permissions(%Plan{raw_model_output: raw}) when is_map(raw) do
    perms = Map.get(raw, "permissions_needed") || Map.get(raw, :permissions_needed) || []
    Permissions.normalize_permissions(perms)
  end

  defp extract_permissions(_), do: []

  defp extract_criteria(%Plan{raw_model_output: nil}), do: []

  defp extract_criteria(%Plan{raw_model_output: raw}) when is_map(raw) do
    Map.get(raw, "acceptance_criteria") || Map.get(raw, :acceptance_criteria) || []
  end

  defp extract_criteria(_), do: []

  defp extract_risks(%Plan{raw_model_output: nil}), do: []

  defp extract_risks(%Plan{raw_model_output: raw}) when is_map(raw) do
    Map.get(raw, "risks") || Map.get(raw, :risks) || []
  end

  defp extract_risks(_), do: []

  defp has_raw_output?(%Plan{raw_model_output: nil}), do: false
  defp has_raw_output?(%Plan{raw_model_output: raw}) when is_map(raw), do: map_size(raw) > 0
  defp has_raw_output?(_), do: false

  defp count_steps(%Ecto.Association.NotLoaded{}), do: 0
  defp count_steps(nil), do: 0
  defp count_steps(steps) when is_list(steps), do: length(steps)
  defp count_steps(_), do: 0

  defp format_raw_output(raw) when is_map(raw) do
    raw
    |> Jason.encode!(pretty: true)
    |> truncate(2000)
  rescue
    _ -> inspect(raw, pretty: true, limit: 100)
  end

  defp format_raw_output(raw), do: inspect(raw, pretty: true, limit: 100)

  defp truncate(nil, _), do: ""

  defp truncate(text, max_length) when is_binary(text) do
    if String.length(text) > max_length do
      String.slice(text, 0, max_length) <> "..."
    else
      text
    end
  end

  defp truncate(other, _), do: to_string(other)

  defp format_timestamp(nil), do: "—"

  defp format_timestamp(%DateTime{} = dt) do
    dt
    |> DateTime.to_naive()
    |> NaiveDateTime.to_string()
    |> String.replace(~r/\.\d+$/, "")
  end

  defp format_timestamp(other), do: to_string(other)

  # Icon component
  defp icon(assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end
end
