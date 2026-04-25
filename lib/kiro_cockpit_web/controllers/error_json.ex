defmodule KiroCockpitWeb.ErrorJSON do
  @moduledoc """
  JSON error responses for API endpoints.
  """

  def render(template, _assigns) do
    %{errors: %{detail: Phoenix.Controller.status_message_from_template(template)}}
  end
end
