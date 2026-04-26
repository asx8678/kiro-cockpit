defmodule KiroCockpit.Swarm.HookManagerTest do
  use ExUnit.Case, async: true

  alias KiroCockpit.Swarm.{Event, Hook, HookManager, HookResult}

  # -- Fake hook modules for testing ----------------------------------------

  defmodule HighHook do
    @behaviour Hook

    @impl true
    def name, do: :alpha_high
    @impl true
    def priority, do: 100
    @impl true
    def filter(_event), do: true
    @impl true
    def on_event(%Event{} = event, _ctx) do
      HookResult.continue(event, ["alpha_high ran"])
    end
  end

  defmodule MidHook do
    @behaviour Hook

    @impl true
    def name, do: :bravo_mid
    @impl true
    def priority, do: 50
    @impl true
    def filter(_event), do: true
    @impl true
    def on_event(%Event{} = event, _ctx) do
      HookResult.continue(event, ["bravo_mid ran"])
    end
  end

  defmodule LowHook do
    @behaviour Hook

    @impl true
    def name, do: :charlie_low
    @impl true
    def priority, do: 10
    @impl true
    def filter(_event), do: true
    @impl true
    def on_event(%Event{} = event, _ctx) do
      HookResult.continue(event, ["charlie_low ran"])
    end
  end

  # Hook that modifies the event payload
  defmodule ModifyHook do
    @behaviour Hook

    @impl true
    def name, do: :delta_modify
    @impl true
    def priority, do: 90
    @impl true
    def filter(_event), do: true
    @impl true
    def on_event(%Event{} = event, _ctx) do
      modified = %{event | payload: Map.put(event.payload, :redacted, true)}
      HookResult.modify(modified, ["delta_modify redacted"])
    end
  end

  # Hook that blocks
  defmodule BlockHook do
    @behaviour Hook

    @impl true
    def name, do: :echo_block
    @impl true
    def priority, do: 80
    @impl true
    def filter(_event), do: true
    @impl true
    def on_event(%Event{} = event, _ctx) do
      HookResult.block(event, "action denied", ["echo_block blocked"])
    end
  end

  # Hook that only applies to file_write actions
  defmodule SelectiveHook do
    @behaviour Hook

    @impl true
    def name, do: :foxtrot_selective
    @impl true
    def priority, do: 70
    @impl true
    def filter(%Event{action_name: :file_write}), do: true
    @impl true
    def filter(_event), do: false
    @impl true
    def on_event(%Event{} = event, _ctx) do
      HookResult.continue(event, ["foxtrot_selective ran"])
    end
  end

  # Hooks with same priority for tie-breaker testing
  defmodule SamePrioAlpha do
    @behaviour Hook

    @impl true
    def name, do: :aaa_tie
    @impl true
    def priority, do: 50
    @impl true
    def filter(_event), do: true
    @impl true
    def on_event(%Event{} = event, _ctx) do
      HookResult.continue(event, ["aaa_tie ran"])
    end
  end

  defmodule SamePrioZulu do
    @behaviour Hook

    @impl true
    def name, do: :zzz_tie
    @impl true
    def priority, do: 50
    @impl true
    def filter(_event), do: true
    @impl true
    def on_event(%Event{} = event, _ctx) do
      HookResult.continue(event, ["zzz_tie ran"])
    end
  end

  # -- Tests ----------------------------------------------------------------

  describe "run/4 — pre-action ordering" do
    test "hooks run in descending priority for pre-action (§36.1)" do
      event = Event.new(:read)
      hooks = [LowHook, MidHook, HighHook]

      {:ok, _event, messages} = HookManager.run(event, hooks, %{}, :pre)

      assert messages == ["alpha_high ran", "bravo_mid ran", "charlie_low ran"]
    end
  end

  describe "run/4 — post-action ordering" do
    test "hooks run in ascending priority for post-action (§36.1)" do
      event = Event.new(:read)
      hooks = [HighHook, LowHook, MidHook]

      {:ok, _event, messages} = HookManager.run(event, hooks, %{}, :post)

      assert messages == ["charlie_low ran", "bravo_mid ran", "alpha_high ran"]
    end
  end

  describe "run/4 — deterministic tie-breaking by hook name" do
    test "same-priority hooks break ties alphabetically by name" do
      event = Event.new(:read)
      hooks = [SamePrioZulu, SamePrioAlpha, HighHook]

      {:ok, _event, messages} = HookManager.run(event, hooks, %{}, :pre)

      # HighHook (100) first, then SamePrioAlpha (50, name :aaa_tie), then SamePrioZulu (50, name :zzz_tie)
      assert messages == ["alpha_high ran", "aaa_tie ran", "zzz_tie ran"]
    end

    test "same tie-breaking applies for post-action phase" do
      event = Event.new(:read)
      hooks = [SamePrioZulu, SamePrioAlpha, LowHook]

      {:ok, _event, messages} = HookManager.run(event, hooks, %{}, :post)

      # LowHook (10) first, then SamePrioAlpha (50, :aaa_tie), then SamePrioZulu (50, :zzz_tie)
      assert messages == ["charlie_low ran", "aaa_tie ran", "zzz_tie ran"]
    end
  end

  describe "run/4 — block behavior" do
    test "block prevents lower-priority hooks from running (§36.1)" do
      event = Event.new(:read)
      # HighHook (100), BlockHook (80), LowHook (10)
      hooks = [HighHook, BlockHook, LowHook]

      result = HookManager.run(event, hooks, %{}, :pre)

      assert {:blocked, _event, "action denied", messages} = result
      # HighHook ran, BlockHook ran and blocked, LowHook never ran
      assert messages == ["alpha_high ran", "echo_block blocked"]
    end

    test "block reason is propagated" do
      event = Event.new(:read)
      hooks = [BlockHook]

      {:blocked, _event, reason, _messages} = HookManager.run(event, hooks, %{}, :pre)

      assert reason == "action denied"
    end

    test "block in post-action stops chain" do
      event = Event.new(:read)
      # In post: LowHook (10) runs first, then BlockHook (80)
      hooks = [BlockHook, LowHook]

      {:blocked, _event, "action denied", messages} =
        HookManager.run(event, hooks, %{}, :post)

      # LowHook (10) ran, BlockHook (80) ran and blocked
      assert messages == ["charlie_low ran", "echo_block blocked"]
    end
  end

  describe "run/4 — modify behavior" do
    test "modify passes changed event to later hooks (§36.1)" do
      event = Event.new(:read, payload: %{secret: "abc123"})
      # ModifyHook (90) modifies, HighHook (100) continues
      # Pre: HighHook (100) first, ModifyHook (90) second
      hooks = [HighHook, ModifyHook, LowHook]

      {:ok, final_event, messages} = HookManager.run(event, hooks, %{}, :pre)

      # HighHook gets original event, ModifyHook gets original, modifies it,
      # LowHook gets the modified event
      assert final_event.payload == %{secret: "abc123", redacted: true}
      assert messages == ["alpha_high ran", "delta_modify redacted", "charlie_low ran"]
    end

    test "modify in post-action threads modified event" do
      event = Event.new(:read, payload: %{})
      # Post: LowHook (10) first, ModifyHook (90) second, HighHook (100) third
      hooks = [HighHook, ModifyHook, LowHook]

      {:ok, final_event, _messages} = HookManager.run(event, hooks, %{}, :post)

      assert final_event.payload == %{redacted: true}
    end

    test "modify threads event — later hooks receive modified event, not original (§36.1)" do
      # A modify hook at 70 adds :threaded flag; a continue hook at 50
      # asserts it sees the modified event, not the original.
      defmodule ThreadVerifyA do
        @behaviour Hook

        @impl true
        def name, do: :thread_a
        @impl true
        def priority, do: 70
        @impl true
        def filter(_), do: true
        @impl true
        def on_event(%Event{} = event, _ctx) do
          HookResult.modify(
            %{event | payload: Map.put(event.payload, :threaded, :a)},
            ["thread_a modified"]
          )
        end
      end

      defmodule ThreadVerifyB do
        @behaviour Hook

        @impl true
        def name, do: :thread_b
        @impl true
        def priority, do: 50
        @impl true
        def filter(_), do: true
        @impl true
        def on_event(%Event{} = event, _ctx) do
          # B must see the modification from A
          assert event.payload[:threaded] == :a
          HookResult.continue(event, ["thread_b saw modification"])
        end
      end

      event = Event.new(:read, payload: %{})
      hooks = [ThreadVerifyA, ThreadVerifyB]

      {:ok, final_event, messages} = HookManager.run(event, hooks, %{}, :pre)

      assert final_event.payload[:threaded] == :a
      assert "thread_b saw modification" in messages
    after
      :code.delete(:"Elixir.KiroCockpit.Swarm.HookManagerTest.ThreadVerifyA")
      :code.delete(:"Elixir.KiroCockpit.Swarm.HookManagerTest.ThreadVerifyB")
    end

    test "chained modifications accumulate" do
      defmodule ChainModifyA do
        @behaviour Hook

        @impl true
        def name, do: :chain_a
        @impl true
        def priority, do: 60
        @impl true
        def filter(_), do: true
        @impl true
        def on_event(%Event{} = event, _ctx) do
          HookResult.modify(%{event | payload: Map.put(event.payload, :a, true)}, ["chain_a"])
        end
      end

      defmodule ChainModifyB do
        @behaviour Hook

        @impl true
        def name, do: :chain_b
        @impl true
        def priority, do: 40
        @impl true
        def filter(_), do: true
        @impl true
        def on_event(%Event{} = event, _ctx) do
          HookResult.modify(%{event | payload: Map.put(event.payload, :b, true)}, ["chain_b"])
        end
      end

      event = Event.new(:read, payload: %{})
      hooks = [ChainModifyB, ChainModifyA]

      {:ok, final_event, messages} = HookManager.run(event, hooks, %{}, :pre)

      # Pre: ChainModifyA (60) first, ChainModifyB (40) second
      assert final_event.payload == %{a: true, b: true}
      assert messages == ["chain_a", "chain_b"]
    end
  end

  describe "run/4 — hook messages captured" do
    test "messages from all hooks are accumulated (§36.1)" do
      event = Event.new(:read)
      hooks = [HighHook, MidHook, LowHook]

      {:ok, _event, messages} = HookManager.run(event, hooks, %{}, :pre)

      assert messages == ["alpha_high ran", "bravo_mid ran", "charlie_low ran"]
    end

    test "messages from hooks before block are included" do
      event = Event.new(:read)
      hooks = [HighHook, BlockHook, LowHook]

      {:blocked, _event, _reason, messages} = HookManager.run(event, hooks, %{}, :pre)

      assert "alpha_high ran" in messages
      assert "echo_block blocked" in messages
      refute "charlie_low ran" in messages
    end
  end

  describe "filter_applicable/2" do
    test "filters out hooks whose filter returns false" do
      event = Event.new(:read)
      hooks = [HighHook, SelectiveHook]

      applicable = HookManager.filter_applicable(hooks, event)

      # SelectiveHook only applies to :file_write
      assert applicable == [HighHook]
    end

    test "keeps hooks whose filter returns true" do
      event = Event.new(:file_write)
      hooks = [HighHook, SelectiveHook]

      applicable = HookManager.filter_applicable(hooks, event)

      assert HighHook in applicable
      assert SelectiveHook in applicable
    end

    test "returns empty list when no hooks apply" do
      event = Event.new(:read)
      hooks = [SelectiveHook]

      assert HookManager.filter_applicable(hooks, event) == []
    end
  end

  describe "sort_for_phase/2" do
    test "pre sorts descending by priority, ascending by name" do
      hooks = [LowHook, SamePrioZulu, SamePrioAlpha, HighHook]

      sorted = HookManager.sort_for_phase(hooks, :pre)

      assert sorted == [HighHook, SamePrioAlpha, SamePrioZulu, LowHook]
    end

    test "post sorts ascending by priority, ascending by name" do
      hooks = [HighHook, SamePrioZulu, SamePrioAlpha, LowHook]

      sorted = HookManager.sort_for_phase(hooks, :post)

      assert sorted == [LowHook, SamePrioAlpha, SamePrioZulu, HighHook]
    end
  end

  describe "run/4 — with empty hooks list" do
    test "returns ok with original event when no hooks apply" do
      event = Event.new(:read)

      assert {:ok, ^event, []} = HookManager.run(event, [], %{}, :pre)
    end

    test "returns ok when all hooks are filtered out" do
      event = Event.new(:read)
      hooks = [SelectiveHook]

      assert {:ok, ^event, []} = HookManager.run(event, hooks, %{}, :pre)
    end
  end
end
