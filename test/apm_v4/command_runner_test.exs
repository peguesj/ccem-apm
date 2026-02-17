defmodule ApmV4.CommandRunnerTest do
  use ExUnit.Case, async: false

  alias ApmV4.CommandRunner

  test "exec returns error for unknown environment" do
    assert {:error, :environment_not_found} = CommandRunner.exec("nonexistent_xyz", "echo hello")
  end

  test "exec rejects dangerous commands" do
    assert {:error, :dangerous_command} = CommandRunner.exec("anything", "sudo rm -rf /")
    assert {:error, :dangerous_command} = CommandRunner.exec("anything", "rm -rf /")
  end

  test "list_running returns empty list initially" do
    assert CommandRunner.list_running() == []
  end

  test "kill returns error for unknown request" do
    assert {:error, :not_found} = CommandRunner.kill("nonexistent")
  end
end
