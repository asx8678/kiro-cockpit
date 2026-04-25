defmodule KiroCockpitWeb.Components.Planning do
  @moduledoc """
  Planning UI components for KiroCockpit.

  This module provides components for rendering NanoPlanner plans:

    * `PermissionBadge` — displays permission levels with color coding
    * `PlanCard` — displays plan details with expandable sections

  ## Usage

  Import the components you need:

      import KiroCockpitWeb.Components.Planning.PermissionBadge
      import KiroCockpitWeb.Components.Planning.PlanCard

  Or use the consolidated module:

      use KiroCockpitWeb.Components.Planning
  """

  defmacro __using__(_) do
    quote do
      import KiroCockpitWeb.Components.Planning.PermissionBadge
      import KiroCockpitWeb.Components.Planning.PlanCard
    end
  end
end
