defmodule KiroCockpitWeb.SessionPlanLive do
  @moduledoc """
  LiveView for session planning UI.

  Allows users to:
  - Enter a request and choose planning mode (nano, nano_deep, nano_fix)
  - Generate plans via KiroCockpit.NanoPlanner.plan/3
  - View existing plans with details, steps, permissions, risks
  - Approve, revise, reject, and run plans

  ## Routes

      live "/sessions/:id/plan", SessionPlanLive

  ## URL Parameters

    * `id` — Session ID to plan for

  ## Query Parameters

    * `plan_id` — Optional plan ID to pre-select and expand
    * `mode` — Optional mode pre-selection (nano, nano_deep, nano_fix)
  """
  use KiroCockpitWeb, :live_view

  import KiroCockpitWeb.Components.Planning.PlanCard

  alias KiroCockpit.NanoPlanner
  alias KiroCockpit.Plans

  @supported_modes ["nano", "nano_deep", "nano_fix"]
  @default_mode "nano"

  # ── Lifecycle ─────────────────────────────────────────────────────────

  @impl true
  def mount(%{"id" => session_id} = params, _session, socket) do
    # Subscribe to plan updates for this session
    if connected?(socket) do
      Phoenix.PubSub.subscribe(KiroCockpit.PubSub, "session:#{session_id}:plans")
    end

    # Load existing plans
    plans = Plans.list_plans(session_id)

    # Determine initial selection
    selected_plan_id = params["plan_id"]
    preselected_plan = find_plan(plans, selected_plan_id)

    socket =
      socket
      |> assign(:session_id, session_id)
      |> assign(:page_title, "Session Plan - #{truncate(session_id, 20)}")
      |> assign(:plans, plans)
      |> assign(:selected_plan, preselected_plan)
      |> assign(:expanded_plan_id, preselected_plan && preselected_plan.id)
      |> assign(:request_text, "")
      |> assign(:mode, Map.get(params, "mode", @default_mode))
      |> assign(:supported_modes, @supported_modes)
      |> assign(:generating, false)
      |> assign(:form_errors, [])
      |> assign(:flash_message, nil)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    # Handle query param updates after initial mount
    socket =
      if plan_id = params["plan_id"] do
        plan = find_plan(socket.assigns.plans, plan_id)
        assign(socket, selected_plan: plan, expanded_plan_id: plan_id)
      else
        socket
      end

    {:noreply, socket}
  end

  # ── Event Handlers ───────────────────────────────────────────────────

  @impl true
  def handle_event("validate_request", %{"request" => request, "mode" => mode}, socket) do
    socket =
      socket
      |> assign(:request_text, request)
      |> assign(:mode, mode)
      |> clear_form_errors()

    {:noreply, socket}
  end

  @impl true
  def handle_event("generate_plan", %{"request" => request, "mode" => mode}, socket) do
    socket = assign(socket, request_text: request, mode: mode)

    case validate_generate_params(request, mode) do
      :ok ->
        session_id = socket.assigns.session_id
        socket = assign(socket, generating: true, form_errors: [])
        # Start async generation
        {:noreply,
         start_async(socket, :plan_generation, fn -> generate_plan(session_id, request, mode) end)}

      {:error, errors} ->
        {:noreply, assign(socket, form_errors: errors)}
    end
  end

  @impl true
  def handle_event("select_plan", %{"id" => plan_id}, socket) do
    plan = find_plan(socket.assigns.plans, plan_id)
    {:noreply, assign(socket, selected_plan: plan)}
  end

  @impl true
  def handle_event("expand_plan", %{"id" => plan_id}, socket) do
    current = socket.assigns.expanded_plan_id

    # Toggle: if clicking already expanded, collapse it
    new_expanded = if current == plan_id, do: nil, else: plan_id

    {:noreply,
     socket
     |> assign(:expanded_plan_id, new_expanded)
     |> assign(:selected_plan, find_plan(socket.assigns.plans, new_expanded))}
  end

  @impl true
  def handle_event("approve_plan", %{"id" => plan_id}, socket) do
    # Note: In a real implementation, we'd get the session process reference
    # For now, we use a mock approach - the Plans context handles state transitions
    case Plans.approve_plan(plan_id) do
      {:ok, plan} ->
        broadcast_plan_update(socket.assigns.session_id, plan)
        socket = refresh_plans_and_notify(socket, "Plan approved successfully")
        {:noreply, socket}

      {:error, :invalid_transition} ->
        {:noreply, put_flash(socket, :error, "Cannot approve plan: invalid status transition")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to approve plan: #{format_error(reason)}")}
    end
  end

  @impl true
  def handle_event("reject_plan", %{"id" => plan_id} = params, socket) do
    reason = Map.get(params, "reason", nil)

    case Plans.reject_plan(plan_id, reason) do
      {:ok, plan} ->
        broadcast_plan_update(socket.assigns.session_id, plan)
        socket = refresh_plans_and_notify(socket, "Plan rejected")
        {:noreply, socket}

      {:error, :invalid_transition} ->
        {:noreply, put_flash(socket, :error, "Cannot reject plan: invalid status transition")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to reject plan: #{format_error(reason)}")}
    end
  end

  @impl true
  def handle_event("revise_plan", %{"id" => plan_id}, socket) do
    # Show a prompt for revision request (simplified - could be a modal in full implementation)
    # For now, we use a default revision message or extract from params
    revision_request = "Please revise this plan with improvements"

    # Get the plan to find its session
    case Plans.get_plan(plan_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Plan not found")}

      plan ->
        session_id = socket.assigns.session_id
        socket = assign(socket, generating: true)

        {:noreply,
         start_async(socket, :plan_generation, fn ->
           do_revise_plan(session_id, plan, revision_request)
         end)}
    end
  end

  @impl true
  def handle_event("run_plan", %{"id" => plan_id}, socket) do
    # Transition plan to running status
    case Plans.update_status(plan_id, "running", %{"started_at" => DateTime.utc_now()}) do
      {:ok, plan} ->
        broadcast_plan_update(socket.assigns.session_id, plan)
        socket = refresh_plans_and_notify(socket, "Plan execution started")
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to run plan: #{format_error(reason)}")}
    end
  end

  @impl true
  def handle_event("dismiss_flash", _, socket) do
    {:noreply, assign(socket, :flash_message, nil)}
  end

  @impl true
  def handle_event("refresh_plans", _, socket) do
    {:noreply, refresh_plans(socket)}
  end

  # ── Async Handlers ───────────────────────────────────────────────────

  @impl true
  def handle_async(:plan_generation, {:ok, {:ok, plan}}, socket) do
    socket =
      socket
      |> assign(:generating, false)
      |> assign(:expanded_plan_id, plan.id)
      |> refresh_plans()
      |> put_flash(:info, "Plan generated successfully")

    {:noreply, socket}
  end

  @impl true
  def handle_async(:plan_generation, {:ok, {:error, reason}}, socket) do
    socket =
      socket
      |> assign(:generating, false)
      |> put_flash(:error, "Failed to generate plan: #{format_error(reason)}")

    {:noreply, socket}
  end

  @impl true
  def handle_async(:plan_generation, {:exit, reason}, socket) do
    socket =
      socket
      |> assign(:generating, false)
      |> put_flash(:error, "Plan generation crashed: #{format_exit(reason)}")

    {:noreply, socket}
  end

  # ── Info Handlers (PubSub) ───────────────────────────────────────────

  @impl true
  def handle_info({:plan_updated, plan}, socket) do
    # Refresh the plans list when we receive a broadcast
    # Check if this plan belongs to our session
    if plan.session_id == socket.assigns.session_id do
      {:noreply, refresh_plan_in_list(socket, plan)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:plan_created, plan}, socket) do
    if plan.session_id == socket.assigns.session_id do
      socket =
        socket
        |> refresh_plans()
        |> assign(:expanded_plan_id, plan.id)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # ── Render ────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-50">
      <%!-- Header --%>
      <div class="bg-white border-b border-gray-200">
        <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-4">
          <div class="flex items-center justify-between">
            <div>
              <h1 class="text-2xl font-bold text-gray-900">Session Planning</h1>
              <p class="text-sm text-gray-500 mt-1">
                Session: <code class="bg-gray-100 px-1.5 py-0.5 rounded text-xs">{@session_id}</code>
              </p>
            </div>
            <div class="flex items-center gap-3">
              <span class="text-sm text-gray-500">
                {length(@plans)} plan{if length(@plans) != 1, do: "s", else: ""}
              </span>
              <button
                type="button"
                phx-click="refresh_plans"
                class="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-md bg-gray-100 text-gray-700 text-sm font-medium hover:bg-gray-200"
              >
                <.icon name="hero-arrow-path" class="h-4 w-4" /> Refresh
              </button>
            </div>
          </div>
        </div>
      </div>

      <div class="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-6">
        <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
          <%!-- Left Column: Plan Generator --%>
          <div class="lg:col-span-1 space-y-6">
            <%!-- Generate Plan Form --%>
            <div class="bg-white rounded-lg shadow-sm border border-gray-200">
              <div class="p-4 border-b border-gray-100">
                <h2 class="text-lg font-semibold text-gray-900">Generate Plan</h2>
                <p class="text-sm text-gray-500 mt-1">Enter your request and choose a mode</p>
              </div>

              <form
                phx-submit="generate_plan"
                phx-change="validate_request"
                class="p-4 space-y-4"
              >
                <div>
                  <label class="block text-sm font-medium text-gray-700 mb-1">Request</label>
                  <textarea
                    name="request"
                    rows="4"
                    value={@request_text}
                    placeholder="Describe what you want to accomplish..."
                    class={[
                      "w-full rounded-md border-gray-300 shadow-sm focus:border-blue-500 focus:ring-blue-500 text-sm",
                      has_error?(@form_errors, :request) &&
                        "border-rose-500 focus:border-rose-500 focus:ring-rose-500"
                    ]}
                    required
                  ></textarea>
                  <p :if={msg = get_error(@form_errors, :request)} class="mt-1 text-sm text-rose-600">
                    {msg}
                  </p>
                </div>

                <div>
                  <label class="block text-sm font-medium text-gray-700 mb-1">Mode</label>
                  <div class="grid grid-cols-3 gap-2">
                    <%= for mode <- @supported_modes do %>
                      <label class={[
                        "cursor-pointer rounded-md border px-3 py-2 text-center text-sm font-medium transition-colors",
                        @mode == mode && "border-blue-500 bg-blue-50 text-blue-700",
                        @mode != mode && "border-gray-200 hover:border-gray-300 text-gray-700"
                      ]}>
                        <input
                          type="radio"
                          name="mode"
                          value={mode}
                          checked={@mode == mode}
                          class="sr-only"
                        />
                        {format_mode(mode)}
                      </label>
                    <% end %>
                  </div>
                  <p class="mt-1 text-xs text-gray-500">
                    {mode_description(@mode)}
                  </p>
                </div>

                <button
                  type="submit"
                  disabled={@generating || @request_text == ""}
                  class={[
                    "w-full inline-flex items-center justify-center gap-2 rounded-md px-4 py-2 text-sm font-medium text-white",
                    @generating && "bg-gray-400 cursor-not-allowed",
                    !@generating && @request_text != "" && "bg-blue-600 hover:bg-blue-700",
                    !@generating && @request_text == "" && "bg-gray-300 cursor-not-allowed"
                  ]}
                >
                  <%= if @generating do %>
                    <.icon name="hero-arrow-path" class="h-4 w-4 animate-spin" /> Generating...
                  <% else %>
                    <.icon name="hero-sparkles" class="h-4 w-4" /> Generate Plan
                  <% end %>
                </button>
              </form>
            </div>

            <%!-- Quick Stats --%>
            <div class="bg-white rounded-lg shadow-sm border border-gray-200 p-4">
              <h3 class="text-sm font-semibold text-gray-900 mb-3">Plan Status</h3>
              <div class="space-y-2">
                <%= for {status, count} <- plan_counts_by_status(@plans) do %>
                  <div class="flex items-center justify-between text-sm">
                    <span class="text-gray-600 flex items-center gap-2">
                      <span class={["w-2 h-2 rounded-full", status_color_dot(status)]}></span>
                      {String.capitalize(status)}
                    </span>
                    <span class="font-medium text-gray-900">{count}</span>
                  </div>
                <% end %>
              </div>
            </div>
          </div>

          <%!-- Right Column: Plan List --%>
          <div class="lg:col-span-2 space-y-4">
            <%= if @plans == [] do %>
              <div class="bg-white rounded-lg shadow-sm border border-gray-200 p-12 text-center">
                <.icon
                  name="hero-clipboard-document-list"
                  class="h-12 w-12 text-gray-300 mx-auto mb-4"
                />
                <h3 class="text-lg font-medium text-gray-900 mb-1">No plans yet</h3>
                <p class="text-sm text-gray-500">Generate your first plan to get started</p>
              </div>
            <% else %>
              <div class="space-y-4">
                <%= for plan <- sort_plans(@plans) do %>
                  <.plan_card
                    plan={plan}
                    expanded={@expanded_plan_id == plan.id}
                    selected={@selected_plan && @selected_plan.id == plan.id}
                    on_approve="approve_plan"
                    on_revise="revise_plan"
                    on_reject="reject_plan"
                    on_run="run_plan"
                    on_expand="expand_plan"
                    on_select="select_plan"
                  />
                <% end %>
              </div>
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ── Private Functions ─────────────────────────────────────────────────

  defp generate_plan(session_id, request, mode) do
    # Use the injectable kiro_session_module if configured
    # In production, this would call NanoPlanner.plan with a real session
    # For testing, we can use a mock
    opts = [
      mode: mode,
      session_id: session_id
    ]

    # Check if we have a configured mock/fake module for testing
    planner_module = Application.get_env(:kiro_cockpit, :nano_planner_module, NanoPlanner)

    # Build a mock session reference (in production, this would be a real session PID)
    # We use self() as a placeholder since NanoPlanner expects a GenServer.server()
    mock_session = self()

    planner_module.plan(mock_session, request, opts)
  rescue
    e ->
      # Handle cases where NanoPlanner might not be available
      require Logger
      Logger.warning("NanoPlanner.plan failed: #{inspect(e)}")
      {:error, :planner_unavailable}
  end

  defp do_revise_plan(session_id, plan, revision_request) do
    opts = [
      mode: plan.mode,
      session_id: session_id
    ]

    planner_module = Application.get_env(:kiro_cockpit, :nano_planner_module, NanoPlanner)
    mock_session = self()

    planner_module.revise(mock_session, plan.id, revision_request, opts)
  rescue
    _ -> {:error, :planner_unavailable}
  end

  defp validate_generate_params(request, mode) do
    errors = []

    errors =
      if is_nil(request) || String.trim(request) == "" do
        [{:request, "Request is required"} | errors]
      else
        errors
      end

    errors =
      if mode in @supported_modes do
        errors
      else
        [{:mode, "Invalid mode: #{mode}"} | errors]
      end

    if errors == [], do: :ok, else: {:error, errors}
  end

  defp find_plan(_plans, nil), do: nil

  defp find_plan(plans, plan_id) when is_binary(plan_id) do
    Enum.find(plans, &(&1.id == plan_id))
  end

  defp find_plan(_, _), do: nil

  defp refresh_plans(socket) do
    plans = Plans.list_plans(socket.assigns.session_id)
    assign(socket, :plans, plans)
  end

  defp refresh_plan_in_list(socket, updated_plan) do
    plans =
      Enum.map(socket.assigns.plans, fn plan ->
        if plan.id == updated_plan.id, do: updated_plan, else: plan
      end)

    selected =
      if socket.assigns.selected_plan && socket.assigns.selected_plan.id == updated_plan.id do
        updated_plan
      else
        socket.assigns.selected_plan
      end

    socket
    |> assign(:plans, plans)
    |> assign(:selected_plan, selected)
  end

  defp refresh_plans_and_notify(socket, message) do
    socket
    |> refresh_plans()
    |> put_flash(:info, message)
  end

  defp broadcast_plan_update(session_id, plan) do
    Phoenix.PubSub.broadcast(
      KiroCockpit.PubSub,
      "session:#{session_id}:plans",
      {:plan_updated, plan}
    )
  end

  defp clear_form_errors(socket) do
    assign(socket, :form_errors, [])
  end

  defp has_error?(errors, field) do
    Enum.any?(errors, fn {f, _} -> f == field end)
  end

  defp get_error(errors, field) do
    case Enum.find(errors, fn {f, _} -> f == field end) do
      {_, msg} -> msg
      nil -> nil
    end
  end

  defp format_error(%Ecto.Changeset{} = changeset) do
    changeset.errors
    |> Enum.map_join(", ", fn {field, {msg, _}} -> "#{field}: #{msg}" end)
  end

  defp format_error(reason) when is_atom(reason), do: to_string(reason)
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp format_exit(:normal), do: "normal exit"
  defp format_exit(:shutdown), do: "shutdown"
  defp format_exit({:shutdown, reason}), do: "shutdown: #{inspect(reason)}"
  defp format_exit(reason), do: inspect(reason)

  defp truncate(text, max_length) do
    if String.length(text) > max_length do
      String.slice(text, 0, max_length) <> "..."
    else
      text
    end
  end

  defp format_mode("nano"), do: "Nano"
  defp format_mode("nano_deep"), do: "Deep"
  defp format_mode("nano_fix"), do: "Fix"
  defp format_mode(other), do: other

  defp mode_description("nano"), do: "Quick planning for straightforward tasks"
  defp mode_description("nano_deep"), do: "Deep analysis for complex changes"
  defp mode_description("nano_fix"), do: "Focused planning for bug fixes"
  defp mode_description(_), do: ""

  defp plan_counts_by_status(plans) do
    plans
    |> Enum.group_by(& &1.status)
    |> Enum.map(fn {status, plans} -> {status, length(plans)} end)
    |> Enum.sort_by(fn {status, _} -> status_order(status) end)
  end

  defp status_order("draft"), do: 0
  defp status_order("approved"), do: 1
  defp status_order("running"), do: 2
  defp status_order("completed"), do: 3
  defp status_order("rejected"), do: 4
  defp status_order("superseded"), do: 5
  defp status_order("failed"), do: 6
  defp status_order(_), do: 99

  defp status_color_dot("draft"), do: "bg-gray-400"
  defp status_color_dot("approved"), do: "bg-emerald-500"
  defp status_color_dot("running"), do: "bg-blue-500"
  defp status_color_dot("completed"), do: "bg-green-500"
  defp status_color_dot("rejected"), do: "bg-rose-500"
  defp status_color_dot("superseded"), do: "bg-gray-300"
  defp status_color_dot("failed"), do: "bg-red-500"
  defp status_color_dot(_), do: "bg-gray-300"

  defp sort_plans(plans) do
    Enum.sort_by(plans, & &1.inserted_at, {:desc, DateTime})
  end
end
