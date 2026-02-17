defmodule ApmV4.RalphTest do
  use ExUnit.Case, async: true

  alias ApmV4.Ralph

  describe "load/1" do
    test "returns empty data for nil path" do
      assert {:ok, data} = Ralph.load(nil)
      assert data.stories == []
      assert data.total == 0
      assert data.passed == 0
    end

    test "returns empty data for empty string path" do
      assert {:ok, data} = Ralph.load("")
      assert data.stories == []
    end

    test "returns error for non-existent file" do
      assert {:error, {:file_read, :enoent}} = Ralph.load("/tmp/nonexistent_prd.json")
    end

    test "parses valid prd.json file" do
      prd = %{
        "project" => "Test Project",
        "branchName" => "main",
        "description" => "Test description",
        "userStories" => [
          %{"id" => "US-001", "title" => "Story 1", "passes" => true, "priority" => 1},
          %{"id" => "US-002", "title" => "Story 2", "passes" => false, "priority" => 2}
        ]
      }

      path = Path.join(System.tmp_dir!(), "test_prd_#{:rand.uniform(100_000)}.json")
      File.write!(path, Jason.encode!(prd))

      assert {:ok, data} = Ralph.load(path)
      assert data.project == "Test Project"
      assert data.branch == "main"
      assert data.total == 2
      assert data.passed == 1
      assert length(data.stories) == 2

      File.rm!(path)
    end

    test "handles invalid JSON gracefully" do
      path = Path.join(System.tmp_dir!(), "bad_prd_#{:rand.uniform(100_000)}.json")
      File.write!(path, "not valid json {{{")

      assert {:error, {:json_parse, _}} = Ralph.load(path)

      File.rm!(path)
    end
  end

  describe "flowchart/1" do
    test "generates nodes and edges from stories" do
      stories = [
        %{"id" => "US-001", "title" => "First", "passes" => true, "priority" => 1},
        %{"id" => "US-002", "title" => "Second", "passes" => false, "priority" => 2},
        %{"id" => "US-003", "title" => "Third", "passes" => false, "priority" => 3}
      ]

      result = Ralph.flowchart(stories)
      assert length(result.nodes) == 3
      assert length(result.edges) == 2

      # First node should be green (passed)
      first = hd(result.nodes)
      assert first.color == "#22c55e"
      assert first.status == "passed"

      # Second node should be red (pending)
      second = Enum.at(result.nodes, 1)
      assert second.color == "#ef4444"
      assert second.status == "pending"
    end

    test "returns empty for nil input" do
      result = Ralph.flowchart(nil)
      assert result.nodes == []
      assert result.edges == []
    end

    test "returns empty for empty list" do
      result = Ralph.flowchart([])
      assert result.nodes == []
      assert result.edges == []
    end

    test "edges form linear chain" do
      stories = [
        %{"id" => "A", "title" => "A", "passes" => false},
        %{"id" => "B", "title" => "B", "passes" => false},
        %{"id" => "C", "title" => "C", "passes" => false}
      ]

      result = Ralph.flowchart(stories)
      assert [edge1, edge2] = result.edges
      assert edge1.source == "A"
      assert edge1.target == "B"
      assert edge2.source == "B"
      assert edge2.target == "C"
    end
  end
end
