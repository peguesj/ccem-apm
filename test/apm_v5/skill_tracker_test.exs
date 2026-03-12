defmodule ApmV5.SkillTrackerTest do
  use ExUnit.Case, async: false

  alias ApmV5.SkillTracker

  setup do
    SkillTracker.clear_all()
    :ok
  end

  describe "track_skill/4" do
    test "tracks a skill invocation" do
      SkillTracker.track_skill("session-1", "ralph", "my-project", "--verbose")
      # Give the cast time to process
      Process.sleep(50)

      skills = SkillTracker.get_session_skills("session-1")
      assert Map.has_key?(skills, "ralph")
      assert skills["ralph"].count == 1
      assert skills["ralph"].project == "my-project"
      assert skills["ralph"].args_sample == "--verbose"
    end

    test "increments count on repeated invocations" do
      SkillTracker.track_skill("session-1", "ralph", "proj")
      SkillTracker.track_skill("session-1", "ralph", "proj")
      SkillTracker.track_skill("session-1", "ralph", "proj")
      Process.sleep(50)

      skills = SkillTracker.get_session_skills("session-1")
      assert skills["ralph"].count == 3
    end

    test "tracks multiple skills in same session" do
      SkillTracker.track_skill("session-1", "ralph", "proj")
      SkillTracker.track_skill("session-1", "tdd:spawn", "proj")
      Process.sleep(50)

      skills = SkillTracker.get_session_skills("session-1")
      assert map_size(skills) == 2
      assert Map.has_key?(skills, "ralph")
      assert Map.has_key?(skills, "tdd:spawn")
    end
  end

  describe "get_project_skills/1" do
    test "aggregates skills across sessions for a project" do
      SkillTracker.track_skill("s1", "ralph", "proj-a")
      SkillTracker.track_skill("s2", "ralph", "proj-a")
      SkillTracker.track_skill("s1", "spawn", "proj-a")
      SkillTracker.track_skill("s3", "ralph", "proj-b")
      Process.sleep(50)

      skills = SkillTracker.get_project_skills("proj-a")
      assert skills["ralph"].total_count == 2
      assert skills["ralph"].session_count == 2
      assert skills["spawn"].total_count == 1
      refute Map.has_key?(skills, "other")
    end
  end

  describe "get_co_occurrence/0" do
    test "returns skill pairs that appear in the same session" do
      SkillTracker.track_skill("s1", "ralph", "proj")
      SkillTracker.track_skill("s1", "spawn", "proj")
      SkillTracker.track_skill("s2", "ralph", "proj")
      Process.sleep(50)

      co = SkillTracker.get_co_occurrence()
      # ralph and spawn appear together in s1
      assert Map.has_key?(co, {"ralph", "spawn"})
      assert co[{"ralph", "spawn"}] == 1
    end
  end

  describe "active_methodology/1" do
    test "detects ralph methodology" do
      SkillTracker.track_skill("s1", "ralph", "proj")
      Process.sleep(50)

      assert SkillTracker.active_methodology("s1") == :ralph
    end

    test "detects tdd methodology" do
      SkillTracker.track_skill("s1", "tdd:spawn", "proj")
      Process.sleep(50)

      assert SkillTracker.active_methodology("s1") == :tdd
    end

    test "detects spawn as tdd" do
      SkillTracker.track_skill("s1", "spawn", "proj")
      Process.sleep(50)

      assert SkillTracker.active_methodology("s1") == :tdd
    end

    test "returns nil for no skills" do
      assert SkillTracker.active_methodology("no-session") == nil
    end

    test "returns :custom for unknown skills" do
      SkillTracker.track_skill("s1", "docs", "proj")
      Process.sleep(50)

      assert SkillTracker.active_methodology("s1") == :custom
    end
  end

  describe "get_skill_catalog/0" do
    test "returns observed skills" do
      SkillTracker.track_skill("s1", "ralph", "proj")
      SkillTracker.track_skill("s2", "ralph", "proj")
      Process.sleep(50)

      catalog = SkillTracker.get_skill_catalog()
      assert catalog["ralph"].total_count == 2
      assert catalog["ralph"].session_count == 2
      assert catalog["ralph"].source == :observed
    end
  end

  describe "clear_all/0" do
    test "removes all tracked data" do
      SkillTracker.track_skill("s1", "ralph", "proj")
      Process.sleep(50)
      assert map_size(SkillTracker.get_session_skills("s1")) > 0

      SkillTracker.clear_all()
      assert SkillTracker.get_session_skills("s1") == %{}
    end
  end
end
