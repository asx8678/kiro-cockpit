defmodule KiroCockpit.Swarm.Tasks.CategoryMatrixTest do
  use ExUnit.Case, async: true

  alias KiroCockpit.Swarm.Tasks.CategoryMatrix
  alias KiroCockpit.Swarm.Tasks.CategoryMatrix.Decision

  # -----------------------------------------------------------------
  # Structure / invariants
  # -----------------------------------------------------------------

  describe "categories/0" do
    test "returns the six canonical categories from §27.5" do
      assert CategoryMatrix.categories() ==
               [:researching, :planning, :acting, :verifying, :debugging, :documenting]
    end
  end

  describe "permissions/0" do
    test "returns the nine canonical permissions from §32.1" do
      perms = CategoryMatrix.permissions()

      for p <- [
            :read,
            :write,
            :shell_read,
            :shell_write,
            :terminal,
            :external,
            :destructive,
            :subagent,
            :memory_write
          ] do
        assert p in perms, "Expected #{p} in permissions"
      end

      assert length(perms) == 9
    end
  end

  describe "matrix structure" do
    test "every category has entries for every permission" do
      for cat <- CategoryMatrix.categories(),
          perm <- CategoryMatrix.permissions() do
        decision = CategoryMatrix.decision(cat, perm)
        assert %Decision{} = decision
        assert decision.verdict in [:allow, :ask, :block]
        assert is_binary(decision.reason)
        assert String.length(decision.reason) > 0
      end
    end

    test "all categories allow :read" do
      for cat <- CategoryMatrix.categories() do
        decision = CategoryMatrix.decision(cat, :read)

        assert decision.verdict == :allow,
               "Category #{cat} should auto-allow :read (§32.2)"
      end
    end

    test "no category auto-allows :destructive" do
      for cat <- CategoryMatrix.categories() do
        decision = CategoryMatrix.decision(cat, :destructive)

        assert decision.verdict != :allow,
               "Category #{cat} should not auto-allow :destructive"
      end
    end
  end

  # -----------------------------------------------------------------
  # Researching (§27.5, §32.2)
  # -----------------------------------------------------------------

  describe "researching category" do
    test "allows read and shell_read" do
      assert CategoryMatrix.decision("researching", :read).verdict == :allow
      assert CategoryMatrix.decision("researching", :shell_read).verdict == :allow
    end

    test "blocks writes, shell_write, terminal, destructive" do
      for perm <- [:write, :shell_write, :terminal, :destructive] do
        assert CategoryMatrix.decision("researching", perm).verdict == :block,
               "researching should block #{perm}"
      end
    end

    test "asks for external and memory_write" do
      for perm <- [:external, :memory_write] do
        assert CategoryMatrix.decision("researching", perm).verdict == :ask,
               "researching should ask for #{perm}"
      end
    end

    test "subagent requires trusted read-only role" do
      assert CategoryMatrix.decision("researching", :subagent).verdict == :block

      decision = CategoryMatrix.decision("researching", :subagent, subagent_kind: :read_only)
      assert decision.verdict == :ask
      assert decision.guidance =~ "read-only"
    end

    test "external guidance mentions approval" do
      decision = CategoryMatrix.decision("researching", :external)
      assert decision.guidance =~ "approval"
    end
  end

  # -----------------------------------------------------------------
  # Planning (§27.5, §32.2)
  # -----------------------------------------------------------------

  describe "planning category" do
    test "allows read" do
      assert CategoryMatrix.decision("planning", :read).verdict == :allow
    end

    test "blocks write, shell_read, shell_write, terminal, destructive" do
      for perm <- [:write, :shell_read, :shell_write, :terminal, :destructive] do
        assert CategoryMatrix.decision("planning", perm).verdict == :block,
               "planning should block #{perm}"
      end
    end

    test "asks for external and memory_write" do
      for perm <- [:external, :memory_write] do
        assert CategoryMatrix.decision("planning", perm).verdict == :ask,
               "planning should ask for #{perm}"
      end
    end

    test "subagent requires trusted read-only reviewer role" do
      assert CategoryMatrix.decision("planning", :subagent).verdict == :block

      decision =
        CategoryMatrix.decision("planning", :subagent, subagent_kind: :read_only_reviewer)

      assert decision.verdict == :ask
      assert decision.guidance =~ "reviewer"
    end
  end

  # -----------------------------------------------------------------
  # Acting (§27.5, §32.2)
  # -----------------------------------------------------------------

  describe "acting category" do
    test "allows read" do
      assert CategoryMatrix.decision("acting", :read).verdict == :allow
    end

    test "asks for write (policy and approval gated per §32.2)" do
      decision = CategoryMatrix.decision("acting", :write)
      assert decision.verdict == :ask
      assert decision.condition == nil
    end

    test "asks for shell_read, shell_write, terminal, external" do
      for perm <- [:shell_read, :shell_write, :terminal, :external] do
        assert CategoryMatrix.decision("acting", perm).verdict == :ask,
               "acting should ask for #{perm}"
      end
    end

    test "asks for destructive (explicit ask per §32.2)" do
      decision = CategoryMatrix.decision("acting", :destructive)
      assert decision.verdict == :ask
      assert decision.guidance =~ "Explicit approval"
    end

    test "asks for subagent (approved only per §32.2)" do
      decision = CategoryMatrix.decision("acting", :subagent)
      assert decision.verdict == :ask
    end

    test "asks for memory_write" do
      assert CategoryMatrix.decision("acting", :memory_write).verdict == :ask
    end

    test "write is not promoted by policy alone" do
      decision = CategoryMatrix.decision("acting", :write, policy_allows_write: true)
      assert decision.verdict == :ask
    end

    test "no blocks in acting" do
      for perm <- CategoryMatrix.permissions() do
        decision = CategoryMatrix.decision("acting", perm)

        assert decision.verdict != :block,
               "acting should not hard-block #{perm}"
      end
    end
  end

  # -----------------------------------------------------------------
  # Verifying (§27.5, §32.2)
  # -----------------------------------------------------------------

  describe "verifying category" do
    test "allows read and shell_read" do
      assert CategoryMatrix.decision("verifying", :read).verdict == :allow
      assert CategoryMatrix.decision("verifying", :shell_read).verdict == :allow
    end

    test "blocks write (unless fixing test fixture)" do
      decision = CategoryMatrix.decision("verifying", :write)
      assert decision.verdict == :block
      assert decision.condition == :fixing_test_fixture
    end

    test "blocks destructive" do
      assert CategoryMatrix.decision("verifying", :destructive).verdict == :block
    end

    test "asks for shell_write, terminal, external" do
      for perm <- [:shell_write, :terminal, :external] do
        assert CategoryMatrix.decision("verifying", perm).verdict == :ask,
               "verifying should ask for #{perm}"
      end
    end

    test "subagent requires trusted QA/review role" do
      assert CategoryMatrix.decision("verifying", :subagent).verdict == :block

      decision = CategoryMatrix.decision("verifying", :subagent, subagent_kind: :qa_reviewer)
      assert decision.verdict == :ask
      assert decision.guidance =~ "QA"
    end

    test "asks for memory_write" do
      assert CategoryMatrix.decision("verifying", :memory_write).verdict == :ask
    end

    test "write promoted to ask when fixing_test_fixture" do
      decision = CategoryMatrix.decision("verifying", :write, fixing_test_fixture: true)
      assert decision.verdict == :ask
    end
  end

  # -----------------------------------------------------------------
  # Debugging (§27.5, §32.2)
  # -----------------------------------------------------------------

  describe "debugging category" do
    test "allows read and shell_read (diagnostics)" do
      assert CategoryMatrix.decision("debugging", :read).verdict == :allow
      assert CategoryMatrix.decision("debugging", :shell_read).verdict == :allow
    end

    test "blocks write until root cause stated" do
      decision = CategoryMatrix.decision("debugging", :write)
      assert decision.verdict == :block
      assert decision.condition == :root_cause_stated
    end

    test "blocks shell_write until root cause stated" do
      decision = CategoryMatrix.decision("debugging", :shell_write)
      assert decision.verdict == :block
      assert decision.condition == :root_cause_stated
    end

    test "blocks destructive" do
      assert CategoryMatrix.decision("debugging", :destructive).verdict == :block
    end

    test "asks for terminal, external" do
      for perm <- [:terminal, :external] do
        assert CategoryMatrix.decision("debugging", perm).verdict == :ask,
               "debugging should ask for #{perm}"
      end
    end

    test "subagent requires trusted diagnostic reviewer role" do
      assert CategoryMatrix.decision("debugging", :subagent).verdict == :block

      decision =
        CategoryMatrix.decision("debugging", :subagent, subagent_kind: :diagnostic_reviewer)

      assert decision.verdict == :ask
      assert decision.guidance =~ "diagnostic"
    end

    test "asks for memory_write" do
      assert CategoryMatrix.decision("debugging", :memory_write).verdict == :ask
    end

    test "write promoted to ask when root_cause_stated" do
      decision = CategoryMatrix.decision("debugging", :write, root_cause_stated: true)
      assert decision.verdict == :ask
    end

    test "shell_write promoted to ask when root_cause_stated" do
      decision = CategoryMatrix.decision("debugging", :shell_write, root_cause_stated: true)
      assert decision.verdict == :ask
    end

    test "write NOT promoted further even with root_cause_stated" do
      # root_cause_stated promotes :block → :ask, NOT :allow
      decision = CategoryMatrix.decision("debugging", :write, root_cause_stated: true)
      assert decision.verdict == :ask
    end
  end

  # -----------------------------------------------------------------
  # Documenting (§27.5, §32.2)
  # -----------------------------------------------------------------

  describe "documenting category" do
    test "allows read and shell_read" do
      for perm <- [:read, :shell_read] do
        assert CategoryMatrix.decision("documenting", perm).verdict == :allow,
               "documenting should auto-allow #{perm}"
      end
    end

    test "memory_write requires approval/pipeline policy" do
      assert CategoryMatrix.decision("documenting", :memory_write).verdict == :ask
    end

    test "asks for write (docs-scoped per §32.2)" do
      decision = CategoryMatrix.decision("documenting", :write)
      assert decision.verdict == :ask
      assert decision.condition == :docs_scoped
    end

    test "asks for external" do
      assert CategoryMatrix.decision("documenting", :external).verdict == :ask
    end

    test "subagent requires trusted docs reviewer role" do
      assert CategoryMatrix.decision("documenting", :subagent).verdict == :block

      decision = CategoryMatrix.decision("documenting", :subagent, subagent_kind: :docs_reviewer)
      assert decision.verdict == :ask
    end

    test "blocks shell_write, terminal, destructive" do
      for perm <- [:shell_write, :terminal, :destructive] do
        assert CategoryMatrix.decision("documenting", perm).verdict == :block,
               "documenting should block #{perm}"
      end
    end

    test "write promoted to allow when docs_scoped" do
      decision = CategoryMatrix.decision("documenting", :write, docs_scoped: true)
      assert decision.verdict == :allow
    end

    test "subagent guidance mentions docs reviewer" do
      decision = CategoryMatrix.decision("documenting", :subagent, subagent_kind: :docs_reviewer)
      assert decision.guidance =~ "documentation"
    end
  end

  # -----------------------------------------------------------------
  # Condition promotion rules
  # -----------------------------------------------------------------

  describe "condition promotion" do
    test "block → ask when condition met" do
      decision = CategoryMatrix.decision("debugging", :write, root_cause_stated: true)
      assert decision.verdict == :ask
    end

    test "ask → allow when condition met" do
      decision = CategoryMatrix.decision("documenting", :write, docs_scoped: true)
      assert decision.verdict == :allow
    end

    test "block stays block when condition not met" do
      decision = CategoryMatrix.decision("debugging", :write)
      assert decision.verdict == :block
    end

    test "ask stays ask when condition not met" do
      decision = CategoryMatrix.decision("documenting", :write)
      assert decision.verdict == :ask
    end

    test "allow stays allow regardless of opts" do
      decision = CategoryMatrix.decision("researching", :read, some_condition: true)
      assert decision.verdict == :allow
    end

    test "unrelated opts do not affect verdicts" do
      decision = CategoryMatrix.decision("researching", :write, irrelevant_opt: true)
      assert decision.verdict == :block
    end
  end

  # -----------------------------------------------------------------
  # Unknown category / permission
  # -----------------------------------------------------------------

  describe "unknown inputs" do
    test "unknown category returns block" do
      decision = CategoryMatrix.decision("unknown_category", :read)
      assert decision.verdict == :block
      assert decision.reason =~ "Unknown"
    end

    test "unknown permission returns block" do
      decision = CategoryMatrix.decision("researching", :unknown_perm)
      assert decision.verdict == :block
      assert decision.reason =~ "Unknown"
    end

    test "unknown strings do not create atoms" do
      unknown_category = "totally_unknown_category_#{System.unique_integer([:positive])}"
      unknown_permission = "totally_unknown_permission_#{System.unique_integer([:positive])}"

      assert_raise ArgumentError, fn -> String.to_existing_atom(unknown_category) end
      assert_raise ArgumentError, fn -> String.to_existing_atom(unknown_permission) end

      decision = CategoryMatrix.decision(unknown_category, unknown_permission)

      assert decision.verdict == :block
      assert_raise ArgumentError, fn -> String.to_existing_atom(unknown_category) end
      assert_raise ArgumentError, fn -> String.to_existing_atom(unknown_permission) end
    end

    test "atom category accepted" do
      decision = CategoryMatrix.decision(:researching, :read)
      assert decision.verdict == :allow
    end

    test "string category accepted" do
      decision = CategoryMatrix.decision("researching", :read)
      assert decision.verdict == :allow
    end
  end

  # -----------------------------------------------------------------
  # permissions_with_verdict/2
  # -----------------------------------------------------------------

  describe "permissions_with_verdict/2" do
    test "returns correct :allow permissions for researching" do
      perms = CategoryMatrix.permissions_with_verdict("researching", :allow)
      assert :read in perms
      assert :shell_read in perms
      refute :write in perms
      refute :external in perms
    end

    test "returns correct :ask permissions for researching" do
      perms = CategoryMatrix.permissions_with_verdict("researching", :ask)
      assert :external in perms
      assert :subagent in perms
      assert :memory_write in perms
    end

    test "returns correct :block permissions for researching" do
      perms = CategoryMatrix.permissions_with_verdict("researching", :block)
      assert :write in perms
      assert :shell_write in perms
      assert :terminal in perms
      assert :destructive in perms
    end

    test "returns empty list for unknown category" do
      assert CategoryMatrix.permissions_with_verdict("unknown", :allow) == []
    end

    test "acting has no :block permissions" do
      assert CategoryMatrix.permissions_with_verdict("acting", :block) == []
    end

    test "permissions are sorted by canonical order" do
      perms = CategoryMatrix.permissions_with_verdict("researching", :block)

      indices =
        Enum.map(perms, &Enum.find_index(CategoryMatrix.permissions(), fn p -> p == &1 end))

      assert indices == Enum.sort(indices)
    end
  end

  # -----------------------------------------------------------------
  # non_blocked_permissions/1
  # -----------------------------------------------------------------

  describe "non_blocked_permissions/1" do
    test "returns allow + ask for acting" do
      perms = CategoryMatrix.non_blocked_permissions("acting")
      # Acting has :read :allow, everything else :ask
      assert :read in perms
      assert :write in perms
      assert :shell_read in perms
      refute :something_fake in perms
    end

    test "returns empty list for unknown category" do
      assert CategoryMatrix.non_blocked_permissions("unknown") == []
    end
  end

  # -----------------------------------------------------------------
  # auto_allowed_permissions/1
  # -----------------------------------------------------------------

  describe "auto_allowed_permissions/1" do
    test "returns only :allow verdict permissions" do
      for cat <- CategoryMatrix.categories() do
        perms = CategoryMatrix.auto_allowed_permissions(cat)

        for perm <- perms do
          assert CategoryMatrix.decision(cat, perm).verdict == :allow,
                 "#{cat} auto_allowed includes #{perm} but verdict isn't :allow"
        end
      end
    end
  end

  # -----------------------------------------------------------------
  # Category classification helpers
  # -----------------------------------------------------------------

  describe "write_capable_categories/0" do
    test "acting and documenting are write-capable" do
      cats = CategoryMatrix.write_capable_categories()
      assert :acting in cats
      assert :documenting in cats
    end

    test "researching and planning are NOT write-capable" do
      cats = CategoryMatrix.write_capable_categories()
      refute :researching in cats
      refute :planning in cats
    end
  end

  describe "read_only_categories/0" do
    test "researching and planning are read-only (unconditional block)" do
      cats = CategoryMatrix.read_only_categories()
      assert :researching in cats
      assert :planning in cats
    end

    test "acting and documenting are NOT read-only" do
      cats = CategoryMatrix.read_only_categories()
      refute :acting in cats
      refute :documenting in cats
    end
  end

  describe "conditional_write_categories/0" do
    test "verifying and debugging have conditional write" do
      cats = CategoryMatrix.conditional_write_categories()
      assert :verifying in cats
      assert :debugging in cats
    end

    test "unconditional read-only and ask-write categories are NOT conditional-write" do
      cats = CategoryMatrix.conditional_write_categories()
      refute :researching in cats
      refute :planning in cats
      refute :acting in cats
      refute :documenting in cats
    end
  end

  describe "ask_write_categories/0" do
    test "acting and documenting ask for write" do
      cats = CategoryMatrix.ask_write_categories()
      assert :acting in cats
      assert :documenting in cats
    end

    test "researching is NOT an ask-write category" do
      cats = CategoryMatrix.ask_write_categories()
      refute :researching in cats
    end
  end

  describe "diagnostic_categories/0" do
    test "verifying and debugging are diagnostic" do
      assert CategoryMatrix.diagnostic_categories() == [:verifying, :debugging]
    end

    test "researching/planning/acting/documenting are NOT diagnostic" do
      cats = CategoryMatrix.diagnostic_categories()
      refute :researching in cats
      refute :planning in cats
      refute :acting in cats
      refute :documenting in cats
    end
  end

  # -----------------------------------------------------------------
  # debugging_write_unlocked?/1 and documenting_write_docs_scoped?/1
  # -----------------------------------------------------------------

  describe "debugging_write_unlocked?/1" do
    test "returns true when root_cause_stated" do
      assert CategoryMatrix.debugging_write_unlocked?(root_cause_stated: true)
    end

    test "returns true when task notes contain root cause" do
      task = %{notes: [%{"type" => "root_cause", "content" => "bad query"}]}
      assert CategoryMatrix.debugging_write_unlocked?(task)
    end

    test "returns false by default" do
      refute CategoryMatrix.debugging_write_unlocked?([])
    end
  end

  describe "documenting_write_docs_scoped?/1" do
    test "returns true when docs_scoped" do
      assert CategoryMatrix.documenting_write_docs_scoped?(docs_scoped: true)
    end

    test "returns true for documentation paths" do
      assert CategoryMatrix.documenting_write_docs_scoped?(path: "docs/swarm.md")

      assert CategoryMatrix.documenting_write_docs_scoped?(
               paths: ["README.md", "guides/setup.mdx"]
             )
    end

    test "returns false for code paths" do
      refute CategoryMatrix.documenting_write_docs_scoped?(path: "lib/kiro_cockpit/swarm.ex")
      refute CategoryMatrix.documenting_write_docs_scoped?(path: "docs/../lib/code.md")
      refute CategoryMatrix.documenting_write_docs_scoped?(paths: ["README.md", "lib/code.ex"])
    end

    test "returns false by default" do
      refute CategoryMatrix.documenting_write_docs_scoped?([])
    end
  end

  # -----------------------------------------------------------------
  # hard_blocks/1
  # -----------------------------------------------------------------

  describe "hard_blocks/1" do
    test "researching hard-blocks write, shell_write, terminal, destructive" do
      blocks = CategoryMatrix.hard_blocks("researching")
      assert :write in blocks
      assert :shell_write in blocks
      assert :terminal in blocks
      assert :destructive in blocks
    end

    test "acting has no hard blocks" do
      assert CategoryMatrix.hard_blocks("acting") == []
    end
  end

  # -----------------------------------------------------------------
  # guidance_summary/1
  # -----------------------------------------------------------------

  describe "guidance_summary/1" do
    test "returns guidance for non-allowed permissions" do
      summary = CategoryMatrix.guidance_summary("researching")

      # Should have entries for :ask and :block permissions
      assert length(summary) > 0

      for {perm, guidance} <- summary do
        assert is_atom(perm)
        assert is_binary(guidance)
      end
    end

    test "acting guidance summary includes all ask permissions" do
      summary = CategoryMatrix.guidance_summary("acting")
      ask_perms = Enum.map(summary, fn {p, _} -> p end)

      for perm <- [
            :write,
            :shell_read,
            :shell_write,
            :terminal,
            :external,
            :destructive,
            :subagent,
            :memory_write
          ] do
        assert perm in ask_perms, "acting guidance should include #{perm}"
      end
    end

    test "unknown category returns empty list" do
      assert CategoryMatrix.guidance_summary("unknown") == []
    end
  end

  # -----------------------------------------------------------------
  # Full matrix cross-product test (§27.5 × §32.2)
  # -----------------------------------------------------------------

  describe "full category × permission matrix (§27.5, §32.2)" do
    # Expected matrix from §32.2 — maps {category, permission} → expected verdict
    # (conditions are tested separately above)
    @expected_verdicts %{
      researching: %{
        read: :allow,
        write: :block,
        shell_read: :allow,
        shell_write: :block,
        terminal: :block,
        external: :ask,
        destructive: :block,
        subagent: :block,
        memory_write: :ask
      },
      planning: %{
        read: :allow,
        write: :block,
        shell_read: :block,
        shell_write: :block,
        terminal: :block,
        external: :ask,
        destructive: :block,
        subagent: :block,
        memory_write: :ask
      },
      acting: %{
        read: :allow,
        write: :ask,
        shell_read: :ask,
        shell_write: :ask,
        terminal: :ask,
        external: :ask,
        destructive: :ask,
        subagent: :ask,
        memory_write: :ask
      },
      verifying: %{
        read: :allow,
        write: :block,
        shell_read: :allow,
        shell_write: :ask,
        terminal: :ask,
        external: :ask,
        destructive: :block,
        subagent: :block,
        memory_write: :ask
      },
      debugging: %{
        read: :allow,
        write: :block,
        shell_read: :allow,
        shell_write: :block,
        terminal: :ask,
        external: :ask,
        destructive: :block,
        subagent: :block,
        memory_write: :ask
      },
      documenting: %{
        read: :allow,
        write: :ask,
        shell_read: :allow,
        shell_write: :block,
        terminal: :block,
        external: :ask,
        destructive: :block,
        subagent: :block,
        memory_write: :ask
      }
    }

    test "every entry matches the §32.2 permission matrix" do
      for {cat, perms} <- @expected_verdicts,
          {perm, expected_verdict} <- perms do
        actual = CategoryMatrix.decision(cat, perm).verdict

        assert actual == expected_verdict,
               "#{cat} × #{perm}: expected #{expected_verdict}, got #{actual}"
      end
    end

    test "researching/planning block mutating actions" do
      for cat <- [:researching, :planning],
          perm <- [:write, :shell_write, :destructive] do
        assert CategoryMatrix.decision(cat, perm).verdict == :block,
               "#{cat} should block #{perm}"
      end

      assert CategoryMatrix.decision(:planning, :shell_read).verdict == :block
    end

    test "acting allows scoped implementation but blocks destructive without approval" do
      assert CategoryMatrix.decision(:acting, :write).verdict == :ask
      assert CategoryMatrix.decision(:acting, :destructive).verdict == :ask
    end

    test "verifying allows reads/non-mutating shell, blocks new writes by default" do
      assert CategoryMatrix.decision(:verifying, :read).verdict == :allow
      assert CategoryMatrix.decision(:verifying, :shell_read).verdict == :allow
      assert CategoryMatrix.decision(:verifying, :write).verdict == :block
    end

    test "debugging blocks writes until root-cause, allows diagnostics" do
      assert CategoryMatrix.decision(:debugging, :read).verdict == :allow
      assert CategoryMatrix.decision(:debugging, :shell_read).verdict == :allow
      assert CategoryMatrix.decision(:debugging, :write).verdict == :block
      assert CategoryMatrix.decision(:debugging, :write, root_cause_stated: true).verdict == :ask
    end

    test "documenting allows docs-scoped writes, blocks code writes" do
      assert CategoryMatrix.decision(:documenting, :write).verdict == :ask
      assert CategoryMatrix.decision(:documenting, :write, docs_scoped: true).verdict == :allow
      assert CategoryMatrix.decision(:documenting, :shell_write).verdict == :block
      assert CategoryMatrix.decision(:documenting, :terminal).verdict == :block
    end

    test "ask/approval states for external across categories" do
      for cat <- CategoryMatrix.categories() do
        decision = CategoryMatrix.decision(cat, :external)
        # External is always :ask (never :allow or :block)
        assert decision.verdict == :ask,
               "#{cat} × external: expected :ask, got #{decision.verdict}"
      end
    end

    test "subagent is blocked without trusted role qualifiers" do
      for cat <- [:researching, :planning, :verifying, :debugging, :documenting] do
        decision = CategoryMatrix.decision(cat, :subagent)

        assert decision.verdict == :block,
               "#{cat} × subagent: expected :block without kind, got #{decision.verdict}"
      end
    end

    test "subagent is ask with trusted category-specific role qualifiers" do
      assert CategoryMatrix.decision(:researching, :subagent, subagent_kind: :read_only).verdict ==
               :ask

      assert CategoryMatrix.decision(:planning, :subagent, subagent_kind: :read_only_reviewer).verdict ==
               :ask

      assert CategoryMatrix.decision(:verifying, :subagent, subagent_kind: :qa_reviewer).verdict ==
               :ask

      assert CategoryMatrix.decision(:debugging, :subagent, subagent_kind: :diagnostic_reviewer).verdict ==
               :ask

      assert CategoryMatrix.decision(:documenting, :subagent, subagent_kind: :docs_reviewer).verdict ==
               :ask
    end
  end
end
