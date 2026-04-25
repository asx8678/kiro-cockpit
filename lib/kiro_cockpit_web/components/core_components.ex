defmodule KiroCockpitWeb.CoreComponents do
  @moduledoc """
  Core UI components for KiroCockpit.

  Provides common interface elements: buttons, inputs, flash messages,
  modal dialogs, etc.
  """
  use Phoenix.Component

  alias Phoenix.LiveView.JS
  use PhoenixHTMLHelpers

  attr :id, :string, required: true
  attr :class, :string, default: nil
  attr :autoshow, :boolean, default: false
  attr :on_cancel, JS, default: %JS{}
  slot :inner_block, required: true

  def modal(assigns) do
    ~H"""
    <div
      id={@id}
      phx-mounted={@autoshow && show_modal(@id)}
      phx-remove={hide_modal(@id)}
      data-cancel={JS.exec(@on_cancel, "phx-remove")}
      class="relative z-50 hidden"
    >
      <div id={"#{@id}-bg"} class="fixed inset-0 bg-zinc-50/90 transition-opacity" aria-hidden="true" />
      <div
        class="fixed inset-0 overflow-y-auto"
        aria-labelledby={"#{@id}-title"}
        aria-describedby={"#{@id}-description"}
        role="dialog"
        aria-modal="true"
        tabindex="0"
      >
        <div class="flex min-h-full items-center justify-center p-4">
          <div class="phx-modal-content w-full max-w-3xl p-4 sm:p-6 lg:py-8">
            <.focus_wrapper
              id={"#{@id}-container"}
              phx-window-keydown={JS.exec("data-cancel", to: "##{@id}")}
              phx-key="escape"
              class="shadow-zinc-700/10 ring-zinc-700/10 relative rounded-2xl bg-white p-8 shadow-lg ring-1"
            >
              <div class="absolute top-6 right-5">
                <button
                  phx-click={JS.exec("data-cancel", to: "##{@id}")}
                  type="button"
                  class="-m-3 flex-none p-3 opacity-20 hover:opacity-40"
                  aria-label="close"
                >
                  <.icon name="hero-x-mark-solid" class="h-5 w-5" />
                </button>
              </div>
              <div id={"#{@id}-content"}>
                {render_slot(@inner_block)}
              </div>
            </.focus_wrapper>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :flashes, :map, required: true
  attr :title, :string, default: nil
  attr :kind, :atom, default: nil
  attr :rest, :global

  def flash_group(assigns) do
    ~H"""
    <div id={@id} {@rest}>
      <.flash :if={@kind != :error} kind={:info} title={@title || "Success!"} flash={@flashes} />
      <.flash :if={@kind != :info} kind={:error} title={@title || "Error!"} flash={@flashes} />
      <.flash
        id="disconnected-flash"
        kind={:error}
        title="We can't find the internet"
        close={false}
        autoshow={false}
        phx-disconnected={
          show("#disconnected-flash") |> JS.remove_attribute("hidden", to: "#disconnected-flash")
        }
        phx-connected={
          hide("#disconnected-flash") |> JS.set_attribute({"hidden", ""}, to: "#disconnected-flash")
        }
        hidden
      >
        Attempting to reconnect <.icon name="hero-arrow-path" class="ml-1 h-3 w-3 animate-spin" />
      </.flash>
    </div>
    """
  end

  attr :id, :string, default: "flash", required: false
  attr :close, :boolean, default: true
  attr :autoshow, :boolean, default: true
  attr :kind, :atom, values: [:info, :error]
  attr :title, :string, default: nil
  attr :hidden, :boolean, default: false
  attr :flash, :map, default: %{}, required: false
  attr :rest, :global
  slot :inner_block

  def flash(assigns) do
    ~H"""
    <div
      :if={msg = Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-mounted={@autoshow && show("##{@id}")}
      phx-remove={hide("##{@id}")}
      phx-click={JS.push("lv:clear-flash") |> JS.remove_class("fade-in-scale", to: "##{@id}")}
      role="alert"
      class={[
        "fixed top-2 right-2 w-80 sm:w-96 z-50 rounded-lg p-3 shadow-md",
        @kind == :info && "bg-emerald-50 text-emerald-800 ring-emerald-500 fill-cyan-900",
        @kind == :error && "bg-rose-50 p-3 text-rose-900 shadow-md ring-rose-500 fill-rose-900"
      ]}
      {@rest}
    >
      <div :if={@title} class="flex items-start gap-1.5">
        <.icon
          :if={@kind == :info}
          name="hero-information-circle-mini"
          class="h-4 w-4 fill-emerald-900 mt-1"
        />
        <.icon
          :if={@kind == :error}
          name="hero-exclamation-circle-mini"
          class="h-4 w-4 fill-rose-900 mt-1"
        />
        <div class="flex-1 text-sm leading-5">{@title}</div>
        <button :if={@close} type="button" class="group flex-none" aria-label="close">
          <.icon name="hero-x-mark-solid" class="h-5 w-5 opacity-40 group-hover:opacity-70" />
        </button>
      </div>
      <div class="mt-2 text-sm leading-5">{msg}</div>
    </div>
    """
  end

  attr :for, :string, required: true
  attr :as, :any, default: nil
  attr :rest, :global, include: ~w(autocomplete name rel action enctype method novalidate target)

  slot :inner_block, required: true

  def simple_form(assigns) do
    ~H"""
    <.form :let={f} for={@for} as={@as} {@rest}>
      <div class="space-y-8 bg-white">
        {render_slot(@inner_block, f)}
      </div>
    </.form>
    """
  end

  attr :type, :string, default: nil
  attr :class, :string, default: nil
  attr :rest, :global, include: ~w(disabled form name value)

  slot :inner_block, required: true

  def button(assigns) do
    ~H"""
    <button
      type={@type}
      class={[
        "phx-submit-loading:opacity-75 rounded-lg bg-zinc-900 py-2 px-3",
        "text-sm font-semibold leading-6 text-white hover:bg-zinc-700",
        "active:text-white/80 disabled:opacity-50",
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :id, :string, doc: "the id for the input field"
  attr :name, :string, doc: "the name for the input field"
  attr :label, :string, doc: "the label for the input field"
  attr :value, :any
  attr :type, :string, default: "text"
  attr :class, :string, default: nil

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  def input(assigns) do
    ~H"""
    <div class={@class}>
      <label :if={@label} for={@id}>{@label}</label>
      <input
        type={@type}
        name={@name}
        id={@id}
        value={Phoenix.HTML.Form.normalize_value(@type, @value)}
        class="rounded border-zinc-300 focus:border-zinc-900 focus:ring-zinc-900"
        {@rest}
      />
      <p :for={err <- @errors} class="mt-3 flex gap-3 text-sm leading-6 text-rose-600">
        <.icon name="hero-exclamation-circle-mini" class="mt-0.5 h-5 w-5 flex-none" />
        {err}
      </p>
    </div>
    """
  end

  attr :errors, :list, required: true

  def error(assigns) do
    ~H"""
    <p
      :for={msg <- @errors}
      class="phx-no-feedback:hidden mt-3 flex gap-3 text-sm leading-6 text-rose-600"
    >
      <.icon name="hero-exclamation-circle-mini" class="mt-0.5 h-5 w-5 flex-none" />
      {msg}
    </p>
    """
  end

  attr :name, :string, required: true
  attr :class, :string, default: nil

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      transition:
        {"transition-all ease-out duration-300", "opacity-0 translate-y-4",
         "opacity-100 translate-y-0"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-in duration-200", "opacity-100 translate-y-0",
         "opacity-0 translate-y-4"}
    )
  end

  def show_modal(js \\ %JS{}, id) when is_binary(id) do
    js
    |> JS.show(to: "##{id}")
    |> JS.show(
      to: "##{id}-bg",
      transition: {"transition-all ease-out duration-300", "opacity-0", "opacity-100"}
    )
    |> show("##{id}-container")
    |> JS.focus_first(to: "##{id}-content")
    |> JS.add_class("overflow-hidden", to: "body")
    |> JS.pop_focus()
  end

  def hide_modal(js \\ %JS{}, id) do
    js
    |> JS.hide(
      to: "##{id}-bg",
      transition: {"transition-all ease-in duration-200", "opacity-100", "opacity-0"}
    )
    |> hide("##{id}-container")
    |> JS.hide(to: "##{id}", transition: {"block", "block", "hidden"})
    |> JS.remove_class("overflow-hidden", to: "body")
    |> JS.pop_focus()
  end

  def focus_wrapper(assigns) do
    ~H"""
    <div id={@id} phx-hook="FocusWrap">
      <span id={"#{@id}-start"} tabindex="0" aria-hidden="true" />
      {render_slot(@inner_block)}
      <span id={"#{@id}-end"} tabindex="0" aria-hidden="true" />
    </div>
    """
  end
end
