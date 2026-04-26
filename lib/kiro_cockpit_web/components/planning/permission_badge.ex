defmodule KiroCockpitWeb.Components.Planning.PermissionBadge do
  @moduledoc """
  Component for rendering permission level badges.

  Displays permission levels with appropriate color coding based on
  the escalation hierarchy: read, write, shell_read, shell_write,
  terminal, external, destructive.

  ## Examples

      <.permission_badge permission={:read} />
      <.permission_badge permission="write" size={:sm} />
      <.permission_badge permission={:destructive} show_icon={true} />
  """
  use Phoenix.Component

  alias KiroCockpit.Permissions

  @permission_configs %{
    read: %{color: "bg-emerald-100 text-emerald-800 border-emerald-200", icon: "hero-eye"},
    write: %{color: "bg-blue-100 text-blue-800 border-blue-200", icon: "hero-pencil-square"},
    shell_read: %{
      color: "bg-cyan-100 text-cyan-800 border-cyan-200",
      icon: "hero-magnifying-glass"
    },
    shell_write: %{
      color: "bg-amber-100 text-amber-800 border-amber-200",
      icon: "hero-command-line"
    },
    terminal: %{color: "bg-purple-100 text-purple-800 border-purple-200", icon: "hero-window"},
    external: %{color: "bg-orange-100 text-orange-800 border-orange-200", icon: "hero-globe-alt"},
    destructive: %{
      color: "bg-rose-100 text-rose-800 border-rose-200",
      icon: "hero-exclamation-triangle"
    },
    subagent: %{
      color: "bg-indigo-100 text-indigo-800 border-indigo-200",
      icon: "hero-user-group"
    },
    memory_write: %{
      color: "bg-violet-100 text-violet-800 border-violet-200",
      icon: "hero-archive-box"
    }
  }

  @sizes %{
    xs: "px-1.5 py-0.5 text-xs",
    sm: "px-2 py-0.5 text-xs",
    md: "px-2.5 py-1 text-sm",
    lg: "px-3 py-1.5 text-base"
  }

  attr :permission, :any, required: true, doc: "Permission atom or string"
  attr :size, :atom, default: :md, values: [:xs, :sm, :md, :lg]
  attr :show_icon, :boolean, default: false
  attr :class, :string, default: nil

  def permission_badge(assigns) do
    permission = normalize_permission(assigns.permission)
    config = Map.get(@permission_configs, permission, @permission_configs.read)

    assigns
    |> assign(:permission, permission)
    |> assign(:config, config)
    |> assign(:size_class, Map.get(@sizes, assigns.size))
    |> render_badge()
  end

  defp render_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center gap-1 rounded-full border font-medium",
      @size_class,
      @config.color,
      @class
    ]}>
      <.icon :if={@show_icon} name={@config.icon} class="h-3.5 w-3.5" />
      {format_permission_label(@permission)}
    </span>
    """
  end

  defp normalize_permission(perm) when is_atom(perm), do: perm

  defp normalize_permission(perm) when is_binary(perm) do
    Permissions.normalize_permission(perm)
  end

  defp normalize_permission(_), do: :read

  defp format_permission_label(:shell_read), do: "shell read"
  defp format_permission_label(:shell_write), do: "shell write"
  defp format_permission_label(:memory_write), do: "memory write"
  defp format_permission_label(perm), do: to_string(perm)

  # Icon component for use within this module
  defp icon(assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end
end
