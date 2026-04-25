defmodule KiroCockpit.ProjectSnapshotTest do
  use ExUnit.Case, async: true

  alias KiroCockpit.ProjectSnapshot

  describe "new/2" do
    test "creates a snapshot with a computed hash" do
      snapshot = ProjectSnapshot.new("/tmp/test_project", root_tree: "file1\nfile2")

      assert %ProjectSnapshot{} = snapshot
      assert snapshot.project_dir == "/tmp/test_project"
      assert snapshot.hash != nil
      assert byte_size(snapshot.hash) == 64
    end

    test "computes the same hash for the same content" do
      opts = [
        root_tree: "file1\nfile2",
        detected_stack: ["elixir/phoenix"],
        config_excerpts: %{"mix.exs" => "defmodule MixProject do"},
        existing_plans: "plan A",
        session_summary: "session 1"
      ]

      s1 = ProjectSnapshot.new("/tmp/proj", opts)
      s2 = ProjectSnapshot.new("/tmp/proj", opts)

      assert s1.hash == s2.hash
    end

    test "computes different hash when content changes" do
      s1 = ProjectSnapshot.new("/tmp/proj", root_tree: "file1\nfile2")
      s2 = ProjectSnapshot.new("/tmp/proj", root_tree: "file1\nfile3")

      refute s1.hash == s2.hash
    end

    test "hash is deterministic regardless of map key order" do
      excerpts_a = %{"a.conf" => "aaa", "b.conf" => "bbb"}
      excerpts_b = %{"b.conf" => "bbb", "a.conf" => "aaa"}

      fingerprints_a = %{"lib/a.ex" => "file:size=1:mtime=1", "mix.exs" => "file:size=2:mtime=2"}
      fingerprints_b = %{"mix.exs" => "file:size=2:mtime=2", "lib/a.ex" => "file:size=1:mtime=1"}

      s1 =
        ProjectSnapshot.new("/tmp/proj",
          config_excerpts: excerpts_a,
          file_fingerprints: fingerprints_a
        )

      s2 =
        ProjectSnapshot.new("/tmp/proj",
          config_excerpts: excerpts_b,
          file_fingerprints: fingerprints_b
        )

      assert s1.hash == s2.hash
    end

    test "defaults detected_stack to empty list" do
      snapshot = ProjectSnapshot.new("/tmp/proj")

      assert snapshot.detected_stack == []
    end

    test "defaults config_excerpts to empty map" do
      snapshot = ProjectSnapshot.new("/tmp/proj")

      assert snapshot.config_excerpts == %{}
    end

    test "defaults file_fingerprints to empty map" do
      snapshot = ProjectSnapshot.new("/tmp/proj")

      assert snapshot.file_fingerprints == %{}
    end
  end

  describe "compute_hash/1" do
    test "produces a lowercase hex SHA-256 string" do
      snapshot = ProjectSnapshot.new("/tmp/proj", root_tree: "abc")

      assert snapshot.hash =~ ~r/^[0-9a-f]{64}$/
    end

    test "hash changes when detected_stack changes" do
      s1 = ProjectSnapshot.new("/tmp/proj", detected_stack: ["elixir/phoenix"])
      s2 = ProjectSnapshot.new("/tmp/proj", detected_stack: ["node"])

      refute s1.hash == s2.hash
    end

    test "hash changes when config_excerpts change" do
      s1 = ProjectSnapshot.new("/tmp/proj", config_excerpts: %{"mix.exs" => "v1"})
      s2 = ProjectSnapshot.new("/tmp/proj", config_excerpts: %{"mix.exs" => "v2"})

      refute s1.hash == s2.hash
    end

    test "hash changes when file_fingerprints change" do
      s1 =
        ProjectSnapshot.new("/tmp/proj",
          file_fingerprints: %{"lib/a.ex" => "file:size=1:mtime=1"}
        )

      s2 =
        ProjectSnapshot.new("/tmp/proj",
          file_fingerprints: %{"lib/a.ex" => "file:size=2:mtime=2"}
        )

      refute s1.hash == s2.hash
    end

    test "hash changes when existing_plans change" do
      s1 = ProjectSnapshot.new("/tmp/proj", existing_plans: "plan1")
      s2 = ProjectSnapshot.new("/tmp/proj", existing_plans: "plan2")

      refute s1.hash == s2.hash
    end

    test "hash does not change when session_summary changes" do
      s1 = ProjectSnapshot.new("/tmp/proj", session_summary: "session1")
      s2 = ProjectSnapshot.new("/tmp/proj", session_summary: "session2")

      assert s1.hash == s2.hash
    end
  end

  describe "to_markdown/1" do
    test "renders all sections" do
      snapshot =
        ProjectSnapshot.new("/tmp/proj",
          root_tree: "mix.exs\nlib/",
          detected_stack: ["elixir/phoenix"],
          config_excerpts: %{"mix.exs" => "defmodule MixProject"},
          existing_plans: "Build ACP view",
          session_summary: "3 turns completed"
        )

      md = ProjectSnapshot.to_markdown(snapshot)

      assert md =~ "# Project Snapshot"
      assert md =~ "## Root files"
      assert md =~ "mix.exs"
      assert md =~ "## Detected stack"
      assert md =~ "elixir/phoenix"
      assert md =~ "## Important config excerpts"
      assert md =~ "### mix.exs"
      assert md =~ "defmodule MixProject"
      assert md =~ "## Existing plans"
      assert md =~ "Build ACP view"
      assert md =~ "## Session summary"
      assert md =~ "3 turns completed"
    end

    test "renders placeholder for missing sections" do
      snapshot = ProjectSnapshot.new("/tmp/proj")

      md = ProjectSnapshot.to_markdown(snapshot)

      assert md =~ "(empty)"
      assert md =~ "(undetected)"
      assert md =~ "(none)"
    end

    test "config excerpts are sorted by filename" do
      snapshot =
        ProjectSnapshot.new("/tmp/proj",
          config_excerpts: %{
            "z_last.conf" => "z",
            "a_first.conf" => "a",
            "m_middle.conf" => "m"
          }
        )

      md = ProjectSnapshot.to_markdown(snapshot)

      assert md =~ ~r/a_first\.conf.*m_middle\.conf.*z_last\.conf/s
    end
  end
end
