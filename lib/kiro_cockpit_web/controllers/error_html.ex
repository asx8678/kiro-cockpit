defmodule KiroCockpitWeb.ErrorHTML do
  @moduledoc """
  Error HTML views for 404, 500, etc.
  """
  use KiroCockpitWeb, :html

  embed_templates "error_html/*"

  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
