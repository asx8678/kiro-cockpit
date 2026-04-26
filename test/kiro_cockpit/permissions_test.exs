defmodule KiroCockpit.PermissionsTest do
  use ExUnit.Case, async: true

  alias KiroCockpit.Permissions

  # ── Permission vocabulary API ─────────────────────────────────────────

  describe "permissions/0" do
    test "returns the closed list of 9 canonical permissions (§32.1)" do
      perms = Permissions.permissions()

      assert perms == [
               :read,
               :write,
               :shell_read,
               :shell_write,
               :terminal,
               :external,
               :destructive,
               :subagent,
               :memory_write
             ]
    end
  end

  describe "canonical_permissions/0" do
    test "aliases permissions/0" do
      assert Permissions.canonical_permissions() == Permissions.permissions()
    end
  end

  describe "permission_strings/0" do
    test "returns string forms of all 9 canonical permissions" do
      strings = Permissions.permission_strings()

      assert strings == [
               "read",
               "write",
               "shell_read",
               "shell_write",
               "terminal",
               "external",
               "destructive",
               "subagent",
               "memory_write"
             ]
    end
  end

  describe "parse_permission/1" do
    test "returns {:ok, atom} for valid canonical atoms" do
      for perm <- Permissions.permissions() do
        assert {:ok, ^perm} = Permissions.parse_permission(perm)
      end
    end

    test "returns {:ok, atom} for valid canonical strings" do
      for perm <- Permissions.permission_strings() do
        assert {:ok, parsed} = Permissions.parse_permission(perm)
        assert parsed in Permissions.permissions()
      end
    end

    test "resolves aliases" do
      assert {:ok, :shell_write} = Permissions.parse_permission("shell")
      assert {:ok, :shell_read} = Permissions.parse_permission("shell_readonly")
    end

    test "returns error for invalid strings" do
      assert {:error, :invalid_permission} = Permissions.parse_permission("banana")
      assert {:error, :invalid_permission} = Permissions.parse_permission("god_mode")
    end

    test "returns error for invalid atoms" do
      assert {:error, :invalid_permission} = Permissions.parse_permission(:banana)
    end

    test "does not pollute atom table for arbitrary strings" do
      # Parse should not create new atoms — unknown strings return error
      Permissions.parse_permission("totally_made_up_permission_xyz")

      refute :totally_made_up_permission_xyz in Permissions.permissions()
    end

    test "case-insensitive parsing" do
      assert {:ok, :write} = Permissions.parse_permission("Write")
      assert {:ok, :read} = Permissions.parse_permission("READ")
      assert {:ok, :subagent} = Permissions.parse_permission("SUBAGENT")
      assert {:ok, :memory_write} = Permissions.parse_permission("MEMORY_WRITE")
    end
  end

  describe "valid_permission?/1" do
    test "returns true for all canonical atoms" do
      for perm <- Permissions.permissions() do
        assert Permissions.valid_permission?(perm)
      end
    end

    test "returns true for valid strings including aliases" do
      assert Permissions.valid_permission?("read")
      assert Permissions.valid_permission?("write")
      assert Permissions.valid_permission?("subagent")
      assert Permissions.valid_permission?("memory_write")
      assert Permissions.valid_permission?("shell")
      assert Permissions.valid_permission?("shell_readonly")
    end

    test "returns false for invalid atoms" do
      refute Permissions.valid_permission?(:banana)
    end

    test "returns false for invalid strings" do
      refute Permissions.valid_permission?("superuser")
    end

    test "returns false for non-atom non-string" do
      refute Permissions.valid_permission?(123)
      refute Permissions.valid_permission?(nil)
    end
  end

  # ── Escalation order ──────────────────────────────────────────────────

  describe "escalation_order/0" do
    test "returns the canonical 9-level permission order" do
      assert Permissions.escalation_order() ==
               [
                 :read,
                 :write,
                 :shell_read,
                 :shell_write,
                 :terminal,
                 :external,
                 :destructive,
                 :subagent,
                 :memory_write
               ]
    end
  end

  describe "escalation_rank/1" do
    test "returns 0 for :read" do
      assert Permissions.escalation_rank(:read) == 0
    end

    test "returns 6 for :destructive" do
      assert Permissions.escalation_rank(:destructive) == 6
    end

    test "returns 7 for :subagent" do
      assert Permissions.escalation_rank(:subagent) == 7
    end

    test "returns 8 for :memory_write" do
      assert Permissions.escalation_rank(:memory_write) == 8
    end

    test "accepts string input" do
      assert Permissions.escalation_rank("write") == 1
      assert Permissions.escalation_rank("subagent") == 7
      assert Permissions.escalation_rank("memory_write") == 8
    end
  end

  describe "at_or_below/1" do
    test "returns all permissions up to and including :shell_read" do
      assert Permissions.at_or_below(:shell_read) == [:read, :write, :shell_read]
    end

    test "returns only :read for :read" do
      assert Permissions.at_or_below(:read) == [:read]
    end

    test "returns full list for :destructive" do
      assert Permissions.at_or_below(:destructive) ==
               [:read, :write, :shell_read, :shell_write, :terminal, :external, :destructive]
    end

    test "returns full list including subagent and memory_write for :memory_write" do
      assert Permissions.at_or_below(:memory_write) == Permissions.escalation_order()
    end

    test "returns 8 permissions for :subagent" do
      result = Permissions.at_or_below(:subagent)
      assert length(result) == 8
      assert :memory_write not in result
      assert :subagent in result
    end
  end

  # ── Normalization ─────────────────────────────────────────────────────

  describe "normalize_permission/1" do
    test "passes through canonical atoms" do
      for perm <- Permissions.escalation_order() do
        assert Permissions.normalize_permission(perm) == perm
      end
    end

    test "normalizes string 'shell' to :shell_write" do
      assert Permissions.normalize_permission("shell") == :shell_write
    end

    test "normalizes string 'shell_readonly' to :shell_read" do
      assert Permissions.normalize_permission("shell_readonly") == :shell_read
    end

    test "normalizes string 'write' to :write" do
      assert Permissions.normalize_permission("write") == :write
    end

    test "normalizes string 'destructive' to :destructive" do
      assert Permissions.normalize_permission("destructive") == :destructive
    end

    test "normalizes string 'subagent' to :subagent" do
      assert Permissions.normalize_permission("subagent") == :subagent
    end

    test "normalizes string 'memory_write' to :memory_write" do
      assert Permissions.normalize_permission("memory_write") == :memory_write
    end

    test "falls back to :read for unknown strings" do
      assert Permissions.normalize_permission("banana") == :read
    end

    test "falls back to :read for unknown atoms" do
      assert Permissions.normalize_permission(:banana) == :read
    end

    test "normalizes string 'shell_read' to :shell_read" do
      assert Permissions.normalize_permission("shell_read") == :shell_read
    end

    test "normalizes string 'shell_write' to :shell_write" do
      assert Permissions.normalize_permission("shell_write") == :shell_write
    end

    test "case-insensitive for strings" do
      assert Permissions.normalize_permission("Write") == :write
      assert Permissions.normalize_permission("READ") == :read
      assert Permissions.normalize_permission("Shell_Read") == :shell_read
      assert Permissions.normalize_permission("SHELL_WRITE") == :shell_write
      assert Permissions.normalize_permission("SUBAGENT") == :subagent
      assert Permissions.normalize_permission("MEMORY_WRITE") == :memory_write
    end

    test "arbitrary LLM string does not create atoms" do
      # Verifies no atom table pollution — unknown strings fall back to :read
      assert Permissions.normalize_permission("totally_made_up_permission") == :read
    end
  end

  describe "normalize_step_permission/1" do
    test "passes through scalar canonical atoms" do
      assert Permissions.normalize_step_permission(:write) == :write
      assert Permissions.normalize_step_permission(:subagent) == :subagent
      assert Permissions.normalize_step_permission(:memory_write) == :memory_write
    end

    test "passes through scalar strings" do
      assert Permissions.normalize_step_permission("write") == :write
      assert Permissions.normalize_step_permission("subagent") == :subagent
    end

    test "handles list-valued permissions by picking highest" do
      assert Permissions.normalize_step_permission(["read", "write"]) == :write
      assert Permissions.normalize_step_permission(["write", "subagent"]) == :subagent
      assert Permissions.normalize_step_permission(["memory_write", "read"]) == :memory_write
    end

    test "handles list with aliases" do
      assert Permissions.normalize_step_permission(["shell", "read"]) == :shell_write
    end

    test "handles single-element list" do
      assert Permissions.normalize_step_permission(["terminal"]) == :terminal
    end

    test "handles empty list gracefully (falls back to :read)" do
      assert Permissions.normalize_step_permission([]) == :read
    end

    test "handles list with invalid values gracefully" do
      assert Permissions.normalize_step_permission(["banana", "read"]) == :read
    end

    test "deduplicates list before picking highest" do
      assert Permissions.normalize_step_permission(["write", "write", "read"]) == :write
    end
  end

  describe "normalize_permissions/1" do
    test "deduplicates and sorts by escalation" do
      assert Permissions.normalize_permissions(["write", :read, "write", :read]) ==
               [:read, :write]
    end

    test "handles mixed atoms and strings" do
      assert Permissions.normalize_permissions([:shell_write, "read", :terminal]) ==
               [:read, :shell_write, :terminal]
    end

    test "handles all 9 permissions" do
      all = Permissions.normalize_permissions(Permissions.permission_strings())
      assert all == Permissions.permissions()
    end

    test "returns empty list for empty input" do
      assert Permissions.normalize_permissions([]) == []
    end
  end

  # ── Permission prediction ──────────────────────────────────────────────

  describe "predict_permissions/1" do
    test "extracts top-level permissions_needed" do
      plan = %{"permissions_needed" => ["read", "write"]}
      assert Permissions.predict_permissions(plan) == [:read, :write]
    end

    test "handles atom-key top-level permissions_needed" do
      plan = %{permissions_needed: [:read, :shell_read]}
      assert Permissions.predict_permissions(plan) == [:read, :shell_read]
    end

    test "extracts from single permission field at step level" do
      plan = %{
        "phases" => [
          %{
            "steps" => [
              %{"permission" => "write"}
            ]
          }
        ]
      }

      assert Permissions.predict_permissions(plan) == [:read, :write]
    end

    test "extracts from permission_level field" do
      plan = %{
        "phases" => [
          %{
            "steps" => [
              %{"permission_level" => "terminal"}
            ]
          }
        ]
      }

      assert Permissions.predict_permissions(plan) == [:read, :terminal]
    end

    test "extracts from permissions list at step level" do
      plan = %{
        "phases" => [
          %{
            "steps" => [
              %{"permissions" => ["read", "shell_write"]}
            ]
          }
        ]
      }

      assert Permissions.predict_permissions(plan) == [:read, :shell_write]
    end

    test "extracts from permissions_needed at step level" do
      plan = %{
        "phases" => [
          %{
            "steps" => [
              %{"permissions_needed" => [:external]}
            ]
          }
        ]
      }

      assert Permissions.predict_permissions(plan) == [:read, :external]
    end

    test "handles list-valued step permission field" do
      plan = %{
        "phases" => [
          %{
            "steps" => [
              %{"permission" => ["subagent", "memory_write"]}
            ]
          }
        ]
      }

      result = Permissions.predict_permissions(plan)
      assert :subagent in result
      assert :memory_write in result
      assert :read in result
    end

    test "combines top-level and step-level permissions" do
      plan = %{
        "permissions_needed" => ["read", "write"],
        "phases" => [
          %{
            "steps" => [
              %{"permission" => "shell_write"}
            ]
          }
        ]
      }

      assert Permissions.predict_permissions(plan) == [:read, :write, :shell_write]
    end

    test "combines phase-level and step-level permissions" do
      plan = %{
        "phases" => [
          %{
            "permissions_needed" => ["read"],
            "steps" => [
              %{"permission" => "destructive"}
            ]
          }
        ]
      }

      assert Permissions.predict_permissions(plan) == [:read, :destructive]
    end

    test "handles atom-key phases and steps" do
      plan = %{
        phases: [
          %{
            steps: [
              %{permission: :write}
            ]
          }
        ]
      }

      assert Permissions.predict_permissions(plan) == [:read, :write]
    end

    test "predicts subagent and memory_write from plan" do
      plan = %{
        "permissions_needed" => ["subagent", "memory_write"],
        "phases" => []
      }

      result = Permissions.predict_permissions(plan)
      assert :subagent in result
      assert :memory_write in result
    end

    test "heuristic: write permission from files with 'modify' keyword" do
      plan = %{
        "phases" => [
          %{
            "steps" => [
              %{"files" => ["lib/foo.ex"], "details" => "Modify the auth controller"}
            ]
          }
        ]
      }

      result = Permissions.predict_permissions(plan)
      assert :write in result
    end

    test "heuristic: shell_write from validation with 'run' keyword" do
      plan = %{
        "phases" => [
          %{
            "steps" => [
              %{"validation" => "Run mix test to verify"}
            ]
          }
        ]
      }

      result = Permissions.predict_permissions(plan)
      assert :shell_write in result
    end

    test "heuristic: shell_write from details with 'migrate' keyword" do
      plan = %{
        "phases" => [
          %{
            "steps" => [
              %{"details" => "Migrate the database schema"}
            ]
          }
        ]
      }

      result = Permissions.predict_permissions(plan)
      assert :shell_write in result
    end

    test "heuristic: write from validation with 'create' keyword" do
      plan = %{
        "phases" => [
          %{
            "steps" => [
              %{"validation" => "Create a new schema module"}
            ]
          }
        ]
      }

      result = Permissions.predict_permissions(plan)
      assert :write in result
    end

    test "no heuristic permissions for pure read step" do
      plan = %{
        "phases" => [
          %{
            "steps" => [
              %{"details" => "Inspect the current module structure"}
            ]
          }
        ]
      }

      result = Permissions.predict_permissions(plan)
      assert result == [:read]
    end

    test "handles plan with no phases" do
      plan = %{"permissions_needed" => [:read]}
      assert Permissions.predict_permissions(plan) == [:read]
    end

    test "handles empty plan" do
      assert Permissions.predict_permissions(%{}) == []
    end

    test "deduplicates and sorts final result" do
      plan = %{
        "permissions_needed" => ["destructive", "read"],
        "phases" => [
          %{"permissions_needed" => ["write", "destructive"]}
        ]
      }

      assert Permissions.predict_permissions(plan) ==
               [:read, :write, :destructive]
    end
  end

  # ── Policy gating ─────────────────────────────────────────────────────

  describe "auto_allowed/1" do
    test "read_only allows only :read" do
      assert Permissions.auto_allowed(:read_only) == [:read]
    end

    test "auto_allow_readonly allows :read and :shell_read" do
      assert Permissions.auto_allowed(:auto_allow_readonly) == [:read, :shell_read]
    end

    test "auto_allow_all allows all 9 permissions" do
      assert Permissions.auto_allowed(:auto_allow_all) == Permissions.permissions()
    end
  end

  describe "check_policy/2" do
    test "returns :ok when all permissions are auto-allowed under read_only" do
      assert Permissions.check_policy([:read], :read_only) == :ok
    end

    test "returns needs_approval for write under read_only" do
      assert Permissions.check_policy([:read, :write], :read_only) ==
               {:needs_approval, [:write]}
    end

    test "returns :ok for read+shell_read under auto_allow_readonly" do
      assert Permissions.check_policy([:read, :shell_read], :auto_allow_readonly) == :ok
    end

    test "returns needs_approval for write under auto_allow_readonly" do
      result = Permissions.check_policy([:read, :write], :auto_allow_readonly)
      assert result == {:needs_approval, [:write]}
    end

    test "returns needs_approval for shell_write under auto_allow_readonly" do
      result = Permissions.check_policy([:shell_write], :auto_allow_readonly)
      assert result == {:needs_approval, [:shell_write]}
    end

    test "returns needs_approval for terminal under auto_allow_readonly" do
      result = Permissions.check_policy([:terminal], :auto_allow_readonly)
      assert result == {:needs_approval, [:terminal]}
    end

    test "returns needs_approval for external under auto_allow_readonly" do
      result = Permissions.check_policy([:external], :auto_allow_readonly)
      assert result == {:needs_approval, [:external]}
    end

    test "returns needs_approval for destructive under auto_allow_readonly" do
      result = Permissions.check_policy([:destructive], :auto_allow_readonly)
      assert result == {:needs_approval, [:destructive]}
    end

    test "returns needs_approval for subagent under auto_allow_readonly" do
      result = Permissions.check_policy([:subagent], :auto_allow_readonly)
      assert result == {:needs_approval, [:subagent]}
    end

    test "returns needs_approval for memory_write under auto_allow_readonly" do
      result = Permissions.check_policy([:memory_write], :auto_allow_readonly)
      assert result == {:needs_approval, [:memory_write]}
    end

    test "returns :ok for all permissions under auto_allow_all" do
      all = Permissions.permissions()
      assert Permissions.check_policy(all, :auto_allow_all) == :ok
    end

    test "subagent and memory_write need approval under read_only" do
      assert {:needs_approval, [:subagent]} =
               Permissions.check_policy([:subagent], :read_only)

      assert {:needs_approval, [:memory_write]} =
               Permissions.check_policy([:memory_write], :read_only)
    end

    test "subagent and memory_write pass under auto_allow_all" do
      assert :ok = Permissions.check_policy([:subagent, :memory_write], :auto_allow_all)
    end

    test "multiple needing-approval permissions sorted by escalation" do
      result = Permissions.check_policy([:destructive, :write, :terminal], :auto_allow_readonly)
      assert result == {:needs_approval, [:write, :terminal, :destructive]}
    end

    test "empty required list always passes" do
      for policy <- [:read_only, :auto_allow_readonly, :auto_allow_all] do
        assert Permissions.check_policy([], policy) == :ok
      end
    end
  end

  describe "requires_approval?/2" do
    test "returns false when read under read_only" do
      refute Permissions.requires_approval?([:read], :read_only)
    end

    test "returns true when write under auto_allow_readonly" do
      assert Permissions.requires_approval?([:write], :auto_allow_readonly)
    end

    test "returns true when subagent under read_only" do
      assert Permissions.requires_approval?([:subagent], :read_only)
    end

    test "returns true when memory_write under read_only" do
      assert Permissions.requires_approval?([:memory_write], :read_only)
    end

    test "returns false when all under auto_allow_all" do
      refute Permissions.requires_approval?(Permissions.permissions(), :auto_allow_all)
    end
  end

  describe "gate_plan/2" do
    test "returns :ok tuple when plan passes policy" do
      plan = %{"permissions_needed" => ["read", "shell_read"]}
      assert Permissions.gate_plan(plan, :auto_allow_readonly) == {:ok, [:read, :shell_read]}
    end

    test "returns needs_approval tuple when plan exceeds policy" do
      plan = %{
        "permissions_needed" => ["read", "write", "shell_write"],
        "phases" => [
          %{"steps" => [%{"permission" => "terminal"}]}
        ]
      }

      result = Permissions.gate_plan(plan, :auto_allow_readonly)
      assert {:needs_approval, required, needing} = result
      assert :write in required
      assert :write in needing
      assert :terminal in needing
    end

    test "read-only policy blocks write plan" do
      plan = %{"permissions_needed" => ["read", "write"]}
      result = Permissions.gate_plan(plan, :read_only)
      assert {:needs_approval, _, [:write]} = result
    end

    test "gate_plan with subagent permission under read_only" do
      plan = %{"permissions_needed" => ["read", "subagent"]}
      result = Permissions.gate_plan(plan, :read_only)
      assert {:needs_approval, _, needing} = result
      assert :subagent in needing
    end

    test "gate_plan with memory_write permission under read_only" do
      plan = %{"permissions_needed" => ["read", "memory_write"]}
      result = Permissions.gate_plan(plan, :read_only)
      assert {:needs_approval, _, needing} = result
      assert :memory_write in needing
    end

    test "gate_plan with all 9 permissions under auto_allow_all" do
      plan = %{"permissions_needed" => Permissions.permission_strings()}
      assert {:ok, perms} = Permissions.gate_plan(plan, :auto_allow_all)
      assert length(perms) == 9
    end
  end

  # ── Stale-plan hash gate ──────────────────────────────────────────────

  describe "compute_snapshot_hash/1" do
    test "returns a non-negative integer" do
      hash = Permissions.compute_snapshot_hash(%{tree: "abc", config: %{"a" => 1}})
      assert is_integer(hash)
      assert hash >= 0
    end

    test "is deterministic for the same input" do
      snapshot = %{tree: "abc", config: %{"a" => 1, "b" => 2}}

      assert Permissions.compute_snapshot_hash(snapshot) ==
               Permissions.compute_snapshot_hash(snapshot)
    end

    test "is order-independent for map keys" do
      hash1 = Permissions.compute_snapshot_hash(%{a: 1, b: 2})
      hash2 = Permissions.compute_snapshot_hash(%{b: 2, a: 1})
      assert hash1 == hash2
    end

    test "produces different hashes for different content" do
      hash1 = Permissions.compute_snapshot_hash(%{tree: "version1"})
      hash2 = Permissions.compute_snapshot_hash(%{tree: "version2"})
      refute hash1 == hash2
    end

    test "handles nested maps deterministically" do
      snapshot = %{
        config: %{
          deps: ["phoenix", "ecto"],
          version: "1.0"
        },
        tree: ["lib", "test"]
      }

      hash1 = Permissions.compute_snapshot_hash(snapshot)
      hash2 = Permissions.compute_snapshot_hash(snapshot)
      assert hash1 == hash2
    end

    test "handles atom values" do
      hash = Permissions.compute_snapshot_hash(%{status: :ok})
      assert is_integer(hash)
    end

    test "handles list values" do
      hash = Permissions.compute_snapshot_hash(%{files: ["a.ex", "b.ex"]})
      assert is_integer(hash)
    end

    test "empty map produces consistent hash" do
      hash1 = Permissions.compute_snapshot_hash(%{})
      hash2 = Permissions.compute_snapshot_hash(%{})
      assert hash1 == hash2
    end

    test "preserves string case — different hashes for different casing" do
      hash1 = Permissions.compute_snapshot_hash(%{ref: "AbC123"})
      hash2 = Permissions.compute_snapshot_hash(%{ref: "abc123"})
      refute hash1 == hash2
    end
  end

  describe "stale?/2" do
    test "returns :fresh when hashes match" do
      hash = Permissions.compute_snapshot_hash(%{tree: "abc"})
      plan = %{"project_snapshot_hash" => hash}
      assert Permissions.stale?(hash, plan) == :fresh
    end

    test "returns :stale when hashes differ" do
      current_hash = Permissions.compute_snapshot_hash(%{tree: "new"})
      plan_hash = Permissions.compute_snapshot_hash(%{tree: "old"})
      plan = %{"project_snapshot_hash" => plan_hash}
      assert Permissions.stale?(current_hash, plan) == :stale
    end

    test "returns :no_baseline when plan has no snapshot hash" do
      current_hash = 12345
      plan = %{}
      assert Permissions.stale?(current_hash, plan) == :no_baseline
    end

    test "handles atom-key project_snapshot_hash" do
      hash = 99999
      plan = %{project_snapshot_hash: hash}
      assert Permissions.stale?(hash, plan) == :fresh
    end

    test "handles string-key project_snapshot_hash" do
      hash = 99999
      plan = %{"project_snapshot_hash" => hash}
      assert Permissions.stale?(hash, plan) == :fresh
    end
  end

  describe "check_stale/2" do
    test "returns fresh tuple when hashes match" do
      snapshot = %{tree: "abc"}
      hash = Permissions.compute_snapshot_hash(snapshot)
      plan = %{"project_snapshot_hash" => hash}

      assert {:fresh, ^hash} = Permissions.check_stale(snapshot, plan)
    end

    test "returns stale tuple when hashes differ" do
      current = %{tree: "new_tree"}
      old_snapshot = %{tree: "old_tree"}
      old_hash = Permissions.compute_snapshot_hash(old_snapshot)
      plan = %{"project_snapshot_hash" => old_hash}

      result = Permissions.check_stale(current, plan)
      assert {:stale, current_hash, ^old_hash} = result
      assert current_hash == Permissions.compute_snapshot_hash(current)
    end

    test "returns no_baseline tuple for plan without hash" do
      snapshot = %{tree: "abc"}
      result = Permissions.check_stale(snapshot, %{})
      assert {:no_baseline, hash} = result
      assert hash == Permissions.compute_snapshot_hash(snapshot)
    end
  end

  # ── Integration-style tests ───────────────────────────────────────────

  describe "full pipeline: prediction + policy + stale" do
    test "write plan blocked under read_only policy, stale snapshot" do
      old_snapshot = %{tree: "v1"}
      old_hash = Permissions.compute_snapshot_hash(old_snapshot)

      plan = %{
        "permissions_needed" => ["write", "shell_write"],
        "project_snapshot_hash" => old_hash,
        "phases" => [
          %{
            "steps" => [
              %{
                "title" => "Create new module",
                "permission" => "write",
                "details" => "Add a new GenServer"
              }
            ]
          }
        ]
      }

      # Policy gate
      {:needs_approval, _required, needing} = Permissions.gate_plan(plan, :read_only)
      assert :write in needing

      # Stale gate (current snapshot differs)
      current_snapshot = %{tree: "v2"}
      assert {:stale, _, _} = Permissions.check_stale(current_snapshot, plan)
    end

    test "read plan passes auto_allow_readonly, fresh snapshot" do
      snapshot = %{tree: "v1"}
      hash = Permissions.compute_snapshot_hash(snapshot)

      plan = %{
        "permissions_needed" => ["read", "shell_read"],
        "project_snapshot_hash" => hash,
        "phases" => []
      }

      assert {:ok, [:read, :shell_read]} = Permissions.gate_plan(plan, :auto_allow_readonly)
      assert {:fresh, ^hash} = Permissions.check_stale(snapshot, plan)
    end
  end
end
