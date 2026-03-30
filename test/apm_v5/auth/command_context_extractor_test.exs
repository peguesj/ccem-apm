defmodule ApmV5.Auth.CommandContextExtractorTest do
  use ExUnit.Case, async: true

  alias ApmV5.Auth.CommandContextExtractor

  describe "analyze/2 with Bash destructive commands" do
    test "rm -rf pattern" do
      {:ok, context} = CommandContextExtractor.analyze("Bash", %{"command" => "rm -rf /tmp/*"})

      assert context[:action_type] == :destructive
      assert context[:action_detail] =~ "delete recursive"
      assert context[:approval_reasoning] =~ "DELETE FILES"
    end

    test "drop table SQL pattern" do
      {:ok, context} =
        CommandContextExtractor.analyze("Bash", %{
          "command" => "DROP TABLE users"
        })

      assert context[:action_type] == :destructive
      assert context[:approval_reasoning] =~ "DELETE"
    end

    test "git push --force pattern" do
      {:ok, context} =
        CommandContextExtractor.analyze("Bash", %{"command" => "git push --force origin main"})

      assert context[:action_type] == :destructive
      assert context[:approval_reasoning] =~ "DELETE"
    end

    test "pkill -9 pattern" do
      {:ok, context} =
        CommandContextExtractor.analyze("Bash", %{"command" => "pkill -9 -f 'mix phx.server'"})

      assert context[:action_type] == :destructive
      assert context[:action_detail] =~ "kill"
    end
  end

  describe "analyze/2 with Bash read commands" do
    test "cat file pattern" do
      {:ok, context} = CommandContextExtractor.analyze("Bash", %{"command" => "cat /etc/passwd"})

      assert context[:action_type] == :read
      assert context[:action_detail] =~ "read"
      assert context[:approval_reasoning] =~ "READ"
      assert context[:approval_reasoning] =~ "modified"
    end

    test "find files pattern" do
      {:ok, context} =
        CommandContextExtractor.analyze("Bash", %{"command" => "find /app -name '*.log' -type f"})

      assert context[:action_type] == :read
      assert context[:action_detail] =~ "find"
    end

    test "grep pattern" do
      {:ok, context} =
        CommandContextExtractor.analyze("Bash", %{"command" => "grep -r 'TODO' /app/src"})

      assert context[:action_type] == :read
      assert context[:approval_reasoning] =~ "READ"
    end

    test "ls command" do
      {:ok, context} = CommandContextExtractor.analyze("Bash", %{"command" => "ls -la /app"})

      assert context[:action_type] == :read
      assert context[:approval_reasoning] =~ "READ"
    end
  end

  describe "analyze/2 with Bash write commands" do
    test "cp command" do
      {:ok, context} =
        CommandContextExtractor.analyze("Bash", %{"command" => "cp /tmp/file.txt /app/file.txt"})

      assert context[:action_type] == :write
      assert context[:action_detail] =~ "copy"
      assert context[:approval_reasoning] =~ "CREATE, COPY, MOVE"
    end

    test "sed command" do
      {:ok, context} =
        CommandContextExtractor.analyze("Bash", %{"command" => "sed -i 's/old/new/g' /app/config"})

      assert context[:action_type] == :write
      assert context[:approval_reasoning] =~ "MODIFY"
    end

    test "mv command" do
      {:ok, context} =
        CommandContextExtractor.analyze("Bash", %{"command" => "mv /tmp/src /app/dest"})

      assert context[:action_type] == :write
    end

    test "tee command" do
      {:ok, context} =
        CommandContextExtractor.analyze("Bash", %{"command" => "tee output.txt"})

      assert context[:action_type] == :write
      assert context[:approval_reasoning] =~ "CREATE, COPY, MOVE"
    end
  end

  describe "analyze/2 with Bash unknown commands" do
    test "unrecognized command" do
      {:ok, context} =
        CommandContextExtractor.analyze("Bash", %{"command" => "echo 'hello world'"})

      assert context[:action_type] == :unknown
      assert context[:approval_reasoning] =~ "Review the command carefully"
    end
  end

  describe "analyze/2 with Write tool" do
    test "write to file" do
      {:ok, context} =
        CommandContextExtractor.analyze("Write", %{"file_path" => "/app/lib/module.ex", "content" => "..."})

      assert context[:action_type] == :write
      assert context[:action_detail] =~ "write to file"
      assert context[:action_detail] =~ "module.ex"
      assert context[:approval_reasoning] =~ "permanently modify"
    end

    test "missing file_path" do
      {:error, :missing_file_path} = CommandContextExtractor.analyze("Write", %{"content" => "..."})
    end
  end

  describe "analyze/2 with Edit tool" do
    test "edit file" do
      {:ok, context} =
        CommandContextExtractor.analyze("Edit", %{"file_path" => "/app/config.ex"})

      assert context[:action_type] == :write
      assert context[:action_detail] =~ "edit file"
      assert context[:approval_reasoning] =~ "modifying"
    end
  end

  describe "analyze/2 with Read tool" do
    test "read command" do
      {:ok, context} = CommandContextExtractor.analyze("Read", %{"file_path" => "/app/README.md"})

      assert context[:action_type] == :read
      assert context[:approval_reasoning] =~ "reading"
      assert context[:approval_reasoning] =~ "modified"
    end
  end

  describe "analyze/2 with Grep tool" do
    test "grep with pattern" do
      {:ok, context} =
        CommandContextExtractor.analyze("Grep", %{"pattern" => "defmodule.*Handler"})

      assert context[:action_type] == :read
      assert context[:action_detail] =~ "grep"
      assert context[:action_detail] =~ "defmodule"
    end

    test "grep without pattern" do
      {:ok, context} = CommandContextExtractor.analyze("Grep", %{})

      assert context[:action_type] == :read
      assert context[:action_detail] =~ "grep"
    end
  end

  describe "analyze/2 with Glob tool" do
    test "glob with pattern" do
      {:ok, context} =
        CommandContextExtractor.analyze("Glob", %{"pattern" => "**/*.ex"})

      assert context[:action_type] == :read
      assert context[:action_detail] =~ "glob"
      assert context[:action_detail] =~ "*.ex"
    end
  end

  describe "analyze/2 error cases" do
    test "missing command for Bash" do
      {:error, :missing_command} = CommandContextExtractor.analyze("Bash", %{"other" => "value"})
    end

    test "invalid params" do
      {:error, :invalid_params} = CommandContextExtractor.analyze("Bash", "not a map")
    end

    test "unknown tool" do
      {:ok, context} =
        CommandContextExtractor.analyze("UnknownTool", %{"some_param" => "value"})

      assert context[:action_type] == :unknown
    end
  end

  describe "analyze/2 string truncation" do
    test "long file path is truncated" do
      long_path = "/very/long/path/to/some/deeply/nested/file/structure/here.ex"

      {:ok, context} = CommandContextExtractor.analyze("Write", %{"file_path" => long_path})

      # Should truncate to ~35 chars, ending with …
      action_detail = context[:action_detail]
      assert String.length(action_detail) <= 50
      assert String.contains?(action_detail, "…")
    end

    test "long command is truncated" do
      long_cmd =
        "find /very/long/path/structure/with/many/nested/directories -name '*.log' -type f -mtime +30"

      {:ok, context} = CommandContextExtractor.analyze("Bash", %{"command" => long_cmd})

      # Should still identify as read
      assert context[:action_type] == :read
    end
  end

  describe "case insensitivity" do
    test "rm command lowercase" do
      {:ok, context} = CommandContextExtractor.analyze("Bash", %{"command" => "rm -rf /tmp"})
      assert context[:action_type] == :destructive
    end

    test "RM command uppercase" do
      {:ok, context} = CommandContextExtractor.analyze("Bash", %{"command" => "RM -RF /tmp"})
      assert context[:action_type] == :destructive
    end

    test "CAT command uppercase" do
      {:ok, context} = CommandContextExtractor.analyze("Bash", %{"command" => "CAT /etc/passwd"})
      assert context[:action_type] == :read
    end
  end
end
