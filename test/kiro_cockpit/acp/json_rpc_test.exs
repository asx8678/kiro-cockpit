defmodule KiroCockpit.Acp.JsonRpcTest do
  use ExUnit.Case, async: true

  alias KiroCockpit.Acp.JsonRpc

  describe "request/3" do
    test "builds a well-formed request with integer id" do
      assert JsonRpc.request(1, "ping", %{"x" => 1}) ==
               %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping", "params" => %{"x" => 1}}
    end

    test "builds a well-formed request with string id" do
      assert JsonRpc.request("abc", "ping", %{}) ==
               %{"jsonrpc" => "2.0", "id" => "abc", "method" => "ping", "params" => %{}}
    end

    test "defaults params to %{}" do
      assert JsonRpc.request(1, "ping") ==
               %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping", "params" => %{}}
    end

    test "nil params normalize to %{}" do
      assert JsonRpc.request(1, "ping", nil) ==
               %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping", "params" => %{}}
    end
  end

  describe "notification/2" do
    test "builds a notification (no id)" do
      msg = JsonRpc.notification("session/update", %{"k" => "v"})
      assert msg == %{"jsonrpc" => "2.0", "method" => "session/update", "params" => %{"k" => "v"}}
      refute Map.has_key?(msg, "id")
    end
  end

  describe "success_response/2" do
    test "builds a success response" do
      assert JsonRpc.success_response(7, %{"ok" => true}) ==
               %{"jsonrpc" => "2.0", "id" => 7, "result" => %{"ok" => true}}
    end
  end

  describe "error_response/4" do
    test "omits data when nil" do
      msg = JsonRpc.error_response(7, -32601, "Method not found")
      assert msg["error"] == %{"code" => -32601, "message" => "Method not found"}
      refute Map.has_key?(msg["error"], "data")
    end

    test "includes data when provided" do
      msg = JsonRpc.error_response(7, -32000, "boom", %{"detail" => "x"})

      assert msg["error"] == %{
               "code" => -32000,
               "message" => "boom",
               "data" => %{"detail" => "x"}
             }
    end
  end

  describe "classify/1" do
    test "classifies a request" do
      msg = %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping", "params" => %{"a" => 1}}
      assert JsonRpc.classify(msg) == {:request, 1, "ping", %{"a" => 1}}
    end

    test "classifies a request with a string id" do
      msg = %{"jsonrpc" => "2.0", "id" => "uuid-1", "method" => "ping", "params" => %{}}
      assert JsonRpc.classify(msg) == {:request, "uuid-1", "ping", %{}}
    end

    test "classifies a request with no params" do
      msg = %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"}
      assert JsonRpc.classify(msg) == {:request, 1, "ping", %{}}
    end

    test "classifies a notification" do
      msg = %{"jsonrpc" => "2.0", "method" => "session/update", "params" => %{"phase" => "x"}}
      assert JsonRpc.classify(msg) == {:notification, "session/update", %{"phase" => "x"}}
    end

    test "classifies a success response" do
      msg = %{"jsonrpc" => "2.0", "id" => 5, "result" => %{"ok" => true}}
      assert JsonRpc.classify(msg) == {:response, 5, {:ok, %{"ok" => true}}}
    end

    test "classifies an error response with data" do
      msg = %{
        "jsonrpc" => "2.0",
        "id" => 5,
        "error" => %{"code" => -32000, "message" => "boom", "data" => %{"trace" => "x"}}
      }

      assert JsonRpc.classify(msg) ==
               {:response, 5, {:error, %{code: -32000, message: "boom", data: %{"trace" => "x"}}}}
    end

    test "classifies an error response without data" do
      msg = %{"jsonrpc" => "2.0", "id" => 5, "error" => %{"code" => -32601, "message" => "nope"}}

      assert JsonRpc.classify(msg) ==
               {:response, 5, {:error, %{code: -32601, message: "nope"}}}
    end

    test "rejects messages that have neither result nor error nor method" do
      msg = %{"jsonrpc" => "2.0", "id" => 1}
      assert {:invalid, :unrecognized_shape, ^msg} = JsonRpc.classify(msg)
    end

    test "rejects responses with both result and error" do
      msg = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "result" => 1,
        "error" => %{"code" => 1, "message" => "x"}
      }

      assert {:invalid, :unrecognized_shape, ^msg} = JsonRpc.classify(msg)
    end

    test "rejects malformed error objects" do
      msg = %{"jsonrpc" => "2.0", "id" => 1, "error" => %{"code" => "not-an-int"}}
      assert {:invalid, {:malformed_error, _}, _} = JsonRpc.classify(msg)
    end

    test "rejects bad jsonrpc version when present" do
      msg = %{"jsonrpc" => "1.0", "id" => 1, "method" => "ping"}
      assert {:invalid, :bad_jsonrpc_version, ^msg} = JsonRpc.classify(msg)
    end

    test "tolerates missing jsonrpc version" do
      msg = %{"id" => 1, "method" => "ping", "params" => %{}}
      assert JsonRpc.classify(msg) == {:request, 1, "ping", %{}}
    end

    test "rejects non-map input" do
      assert {:invalid, :not_a_map, "stringy"} = JsonRpc.classify("stringy")
    end
  end
end
