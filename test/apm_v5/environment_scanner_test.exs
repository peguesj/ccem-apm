defmodule ApmV5.EnvironmentScannerTest do
  use ExUnit.Case, async: false

  alias ApmV5.EnvironmentScanner

  setup do
    # Create a temp directory structure with .claude/ dirs
    tmp = Path.join(System.tmp_dir!(), "env_scanner_test_#{:rand.uniform(100_000)}")
    File.mkdir_p!(Path.join([tmp, "project_a", ".claude"]))
    File.mkdir_p!(Path.join([tmp, "project_b", ".claude"]))
    File.write!(Path.join([tmp, "project_a", "mix.exs"]), "# elixir project")
    File.write!(Path.join([tmp, "project_b", "package.json"]), "{}")
    File.write!(Path.join([tmp, "project_a", "CLAUDE.md"]), "# Project A instructions")
    File.mkdir_p!(Path.join([tmp, "no_claude"]))

    on_exit(fn -> File.rm_rf!(tmp) end)

    %{tmp: tmp}
  end

  test "list_environments returns discovered environments" do
    envs = EnvironmentScanner.list_environments()
    assert is_list(envs)
  end

  test "get_environment returns not_found for unknown" do
    assert {:error, :not_found} = EnvironmentScanner.get_environment("nonexistent_project_xyz")
  end

  test "rescan triggers immediate scan" do
    result = EnvironmentScanner.rescan()
    assert is_list(result)
  end

  test "rescan discovers real .claude directories" do
    envs = EnvironmentScanner.rescan()
    # Should find at least the apm-v5 project itself
    names = Enum.map(envs, & &1.name)
    assert length(envs) > 0
    assert Enum.any?(names, fn n -> is_binary(n) end)
  end

  test "environment has expected fields" do
    envs = EnvironmentScanner.list_environments()

    if length(envs) > 0 do
      env = hd(envs)
      assert Map.has_key?(env, :name)
      assert Map.has_key?(env, :path)
      assert Map.has_key?(env, :stack)
      assert Map.has_key?(env, :has_claude_md)
      assert Map.has_key?(env, :has_git)
      assert Map.has_key?(env, :sessions)
      assert Map.has_key?(env, :last_modified)
    end
  end
end
