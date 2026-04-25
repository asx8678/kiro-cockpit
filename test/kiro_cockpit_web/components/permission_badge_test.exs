defmodule KiroCockpitWeb.Components.PermissionBadgeTest do
  @moduledoc """
  Tests for the PermissionBadge component.
  """
  use KiroCockpitWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import KiroCockpitWeb.Components.Planning.PermissionBadge

  describe "permission_badge/1" do
    test "renders read permission with correct styling" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.permission_badge permission={:read} />
        """)

      assert html =~ "read"
      assert html =~ "bg-emerald-100"
      assert html =~ "text-emerald-800"
    end

    test "renders write permission with correct styling" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.permission_badge permission={:write} />
        """)

      assert html =~ "write"
      assert html =~ "bg-blue-100"
      assert html =~ "text-blue-800"
    end

    test "renders shell_read permission with correct styling" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.permission_badge permission={:shell_read} />
        """)

      assert html =~ "shell read"
      assert html =~ "bg-cyan-100"
      assert html =~ "text-cyan-800"
    end

    test "renders shell_write permission with correct styling" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.permission_badge permission={:shell_write} />
        """)

      assert html =~ "shell write"
      assert html =~ "bg-amber-100"
      assert html =~ "text-amber-800"
    end

    test "renders terminal permission with correct styling" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.permission_badge permission={:terminal} />
        """)

      assert html =~ "terminal"
      assert html =~ "bg-purple-100"
      assert html =~ "text-purple-800"
    end

    test "renders external permission with correct styling" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.permission_badge permission={:external} />
        """)

      assert html =~ "external"
      assert html =~ "bg-orange-100"
      assert html =~ "text-orange-800"
    end

    test "renders destructive permission with correct styling" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.permission_badge permission={:destructive} />
        """)

      assert html =~ "destructive"
      assert html =~ "bg-rose-100"
      assert html =~ "text-rose-800"
    end

    test "accepts string permissions" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.permission_badge permission="write" />
        """)

      assert html =~ "write"
    end

    test "accepts different sizes" do
      assigns = %{}

      html_xs =
        rendered_to_string(~H"""
        <.permission_badge permission={:read} size={:xs} />
        """)

      html_lg =
        rendered_to_string(~H"""
        <.permission_badge permission={:read} size={:lg} />
        """)

      assert html_xs =~ "px-1.5"
      assert html_lg =~ "px-3"
      assert html_lg =~ "text-base"
    end

    test "can show icon when requested" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.permission_badge permission={:read} show_icon={true} />
        """)

      assert html =~ "hero-eye"
    end

    test "applies custom class" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.permission_badge permission={:read} class="custom-class" />
        """)

      assert html =~ "custom-class"
    end

    test "passes through unknown permission atoms as-is" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.permission_badge permission={:custom_perm} />
        """)

      # Unknown atoms are displayed as-is (to_string of the atom)
      assert html =~ "custom_perm"
    end

    test "normalizes invalid string to read" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.permission_badge permission="invalid" />
        """)

      assert html =~ "read"
    end
  end
end
