defmodule KiroCockpit.CLI.ResultTest do
  use ExUnit.Case, async: true

  alias KiroCockpit.CLI.Result

  describe "ok/2" do
    test "wraps a payload with a stable :kind atom" do
      assert {:ok, %{kind: :plan_created, plan_id: "abc"}} =
               Result.ok(:plan_created, %{plan_id: "abc"})
    end

    test "preserves all other fields" do
      assert {:ok, %{kind: :x, a: 1, b: 2}} = Result.ok(:x, %{a: 1, b: 2})
    end
  end

  describe "error/3" do
    test "wraps an error with code and message (no extras)" do
      assert {:error, %{code: :foo, message: "bad"}} = Result.error(:foo, "bad")
    end

    test "accepts a keyword list of extras" do
      assert {:error, %{code: :foo, message: "bad", plan_id: "abc"}} =
               Result.error(:foo, "bad", plan_id: "abc")
    end

    test "accepts a map of extras" do
      assert {:error, %{code: :foo, message: "bad", plan_id: "abc"}} =
               Result.error(:foo, "bad", %{plan_id: "abc"})
    end

    test "extras cannot override :code or :message" do
      # Defensive: map merge order means our :code/:message win.
      assert {:error, %{code: :foo, message: "bad", code_str: "should-not-overwrite"}} =
               Result.error(:foo, "bad", code_str: "should-not-overwrite", code: :evil)
    end
  end
end
