defmodule KiroCockpit.PuppyBrain.ModelProfileTest do
  use ExUnit.Case, async: true

  alias KiroCockpit.PuppyBrain.ModelProfile

  # -- new/3 ----------------------------------------------------------------

  describe "new/3" do
    test "creates a profile with required fields" do
      profile = ModelProfile.new("test-profile", :planning)

      assert %ModelProfile{} = profile
      assert profile.name == "test-profile"
      assert profile.purpose == :planning
    end

    test "accepts all optional fields via keyword" do
      profile =
        ModelProfile.new("custom", :steering,
          provider: "anthropic",
          reasoning_effort: :low,
          verbosity: :low,
          structured_output: true,
          max_context_policy: "compact_at_80_percent",
          context_window: 64_000,
          latency_target_ms: 300
        )

      assert profile.provider == "anthropic"
      assert profile.reasoning_effort == :low
      assert profile.verbosity == :low
      assert profile.structured_output == true
      assert profile.max_context_policy == "compact_at_80_percent"
      assert profile.context_window == 64_000
      assert profile.latency_target_ms == 300
    end

    test "defaults structured_output to false" do
      profile = ModelProfile.new("basic", :execution)
      refute profile.structured_output
    end

    test "defaults latency_target_ms to nil" do
      profile = ModelProfile.new("basic", :planning)
      assert profile.latency_target_ms == nil
    end
  end

  # -- for_purpose/1 --------------------------------------------------------

  describe "for_purpose/1" do
    test "returns planner-default for :planning" do
      assert {:ok, profile} = ModelProfile.for_purpose(:planning)
      assert profile.name == "planner-default"
      assert profile.purpose == :planning
      assert profile.reasoning_effort == :high
      assert profile.verbosity == :medium
      assert profile.structured_output == true
      assert profile.max_context_policy == "compact_at_70_percent"
    end

    test "returns steering-default for :steering" do
      assert {:ok, profile} = ModelProfile.for_purpose(:steering)
      assert profile.name == "steering-default"
      assert profile.purpose == :steering
      assert profile.reasoning_effort == :low
      assert profile.verbosity == :low
      assert profile.structured_output == true
      assert profile.latency_target_ms == 500
    end

    test "returns silver-scorer-default for :scoring" do
      assert {:ok, profile} = ModelProfile.for_purpose(:scoring)
      assert profile.name == "silver-scorer-default"
      assert profile.purpose == :scoring
      assert profile.reasoning_effort == :low
      assert profile.latency_target_ms == 2000
    end

    test "returns executor-default for :execution" do
      assert {:ok, profile} = ModelProfile.for_purpose(:execution)
      assert profile.name == "executor-default"
      assert profile.purpose == :execution
      assert profile.provider == "kiro-managed"
      assert profile.structured_output == false
    end

    test "returns error for unknown purpose" do
      assert {:error, :unknown_purpose} = ModelProfile.for_purpose(:unknown)
    end
  end

  # -- builtin_profile_names/0 ----------------------------------------------

  describe "builtin_profile_names/0" do
    test "lists all four builtin profiles" do
      names = ModelProfile.builtin_profile_names()

      assert length(names) == 4
      purposes = Enum.map(names, &elem(&1, 0))
      assert :planning in purposes
      assert :steering in purposes
      assert :scoring in purposes
      assert :execution in purposes
    end
  end

  # -- compaction_threshold/1 ------------------------------------------------

  describe "compaction_threshold/1" do
    test "compact_at_70_percent returns 70% of context window" do
      profile =
        ModelProfile.new("t", :planning,
          context_window: 100_000,
          max_context_policy: "compact_at_70_percent"
        )

      assert ModelProfile.compaction_threshold(profile) == 70_000
    end

    test "compact_at_80_percent returns 80% of context window" do
      profile =
        ModelProfile.new("t", :steering,
          context_window: 50_000,
          max_context_policy: "compact_at_80_percent"
        )

      assert ModelProfile.compaction_threshold(profile) == 40_000
    end

    test "compact_at_90_percent returns 90% of context window" do
      profile =
        ModelProfile.new("t", :scoring,
          context_window: 50_000,
          max_context_policy: "compact_at_90_percent"
        )

      assert ModelProfile.compaction_threshold(profile) == 45_000
    end

    test "unknown policy defaults to 70%" do
      profile =
        ModelProfile.new("t", :planning, context_window: 100_000, max_context_policy: "whatever")

      assert ModelProfile.compaction_threshold(profile) == 70_000
    end
  end

  # -- requires_structured_output?/1 ----------------------------------------

  describe "requires_structured_output?/1" do
    test "returns true when structured_output is true" do
      profile = ModelProfile.new("t", :planning, structured_output: true)
      assert ModelProfile.requires_structured_output?(profile)
    end

    test "returns false when structured_output is false" do
      profile = ModelProfile.new("t", :execution, structured_output: false)
      refute ModelProfile.requires_structured_output?(profile)
    end
  end

  # -- low_latency?/1 -------------------------------------------------------

  describe "low_latency?/1" do
    test "returns true when latency_target_ms is set" do
      profile = ModelProfile.new("t", :steering, latency_target_ms: 500)
      assert ModelProfile.low_latency?(profile)
    end

    test "returns false when latency_target_ms is nil" do
      profile = ModelProfile.new("t", :planning)
      refute ModelProfile.low_latency?(profile)
    end
  end

  # -- validate/1 -----------------------------------------------------------

  describe "validate/1" do
    test "returns :ok for a valid profile" do
      profile = ModelProfile.new("valid", :planning)
      assert :ok == ModelProfile.validate(profile)
    end

    test "returns error for invalid purpose" do
      # Bypass the new/3 guard by constructing directly
      profile =
        struct!(ModelProfile,
          name: "bad",
          purpose: :unknown,
          provider: "test",
          reasoning_effort: :medium,
          verbosity: :medium,
          structured_output: false,
          max_context_policy: "compact_at_70_percent",
          context_window: 1000
        )

      assert {:error, reasons} = ModelProfile.validate(profile)
      assert Enum.any?(reasons, &String.contains?(&1, "purpose"))
    end

    test "returns error for empty name" do
      profile =
        struct!(ModelProfile,
          name: "",
          purpose: :planning,
          provider: "test",
          reasoning_effort: :medium,
          verbosity: :medium,
          structured_output: false,
          max_context_policy: "compact_at_70_percent",
          context_window: 1000
        )

      assert {:error, reasons} = ModelProfile.validate(profile)
      assert Enum.any?(reasons, &String.contains?(&1, "name"))
    end

    test "returns error for invalid reasoning_effort" do
      profile =
        struct!(ModelProfile,
          name: "bad",
          purpose: :planning,
          provider: "test",
          reasoning_effort: :ultra,
          verbosity: :medium,
          structured_output: false,
          max_context_policy: "compact_at_70_percent",
          context_window: 1000
        )

      assert {:error, reasons} = ModelProfile.validate(profile)
      assert Enum.any?(reasons, &String.contains?(&1, "reasoning_effort"))
    end

    test "returns error for invalid verbosity" do
      profile =
        struct!(ModelProfile,
          name: "bad",
          purpose: :planning,
          provider: "test",
          reasoning_effort: :medium,
          verbosity: :chatty,
          structured_output: false,
          max_context_policy: "compact_at_70_percent",
          context_window: 1000
        )

      assert {:error, reasons} = ModelProfile.validate(profile)
      assert Enum.any?(reasons, &String.contains?(&1, "verbosity"))
    end

    test "returns error for non-positive context_window" do
      profile =
        struct!(ModelProfile,
          name: "bad",
          purpose: :planning,
          provider: "test",
          reasoning_effort: :medium,
          verbosity: :medium,
          structured_output: false,
          max_context_policy: "compact_at_70_percent",
          context_window: 0
        )

      assert {:error, reasons} = ModelProfile.validate(profile)
      assert Enum.any?(reasons, &String.contains?(&1, "context_window"))
    end

    test "returns multiple errors for multiple invalid fields" do
      profile =
        struct!(ModelProfile,
          name: "",
          purpose: :oops,
          provider: "test",
          reasoning_effort: :nope,
          verbosity: :nah,
          structured_output: false,
          max_context_policy: "compact_at_70_percent",
          context_window: -1
        )

      assert {:error, reasons} = ModelProfile.validate(profile)
      assert length(reasons) >= 5
    end
  end

  # -- struct enforce_keys ---------------------------------------------------

  describe "struct enforce_keys" do
    test "name and purpose are required" do
      assert_raise ArgumentError, fn ->
        struct!(ModelProfile, %{})
      end
    end
  end
end
