defmodule KiroCockpit.Swarm.TraceContextTest do
  use ExUnit.Case, async: true

  alias KiroCockpit.Swarm.TraceContext

  describe "new/0" do
    test "creates a root trace context with trace_id and span_id" do
      ctx = TraceContext.new()

      assert %TraceContext{} = ctx
      assert is_binary(ctx.trace_id)
      assert is_binary(ctx.span_id)
      assert nil == ctx.parent_span_id
    end

    test "trace_id and span_id are 16 hex characters" do
      ctx = TraceContext.new()
      hex_pattern = ~r/^[0-9a-f]{16}$/

      assert ctx.trace_id =~ hex_pattern
      assert ctx.span_id =~ hex_pattern
    end

    test "each call generates unique IDs" do
      ctx1 = TraceContext.new()
      ctx2 = TraceContext.new()

      refute ctx1.trace_id == ctx2.trace_id
      refute ctx1.span_id == ctx2.span_id
    end
  end

  describe "child_span/1" do
    test "creates a child with same trace_id and new span_id" do
      parent = TraceContext.new()
      child = TraceContext.child_span(parent)

      assert child.trace_id == parent.trace_id
      refute child.span_id == parent.span_id
      assert child.parent_span_id == parent.span_id
    end

    test "grandchild spans share the same trace_id" do
      root = TraceContext.new()
      child = TraceContext.child_span(root)
      grandchild = TraceContext.child_span(child)

      assert grandchild.trace_id == root.trace_id
      assert grandchild.parent_span_id == child.span_id
    end
  end
end
