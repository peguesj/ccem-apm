defmodule ApmV4.SessionParserTest do
  use ExUnit.Case, async: true

  alias ApmV4.SessionParser

  @zero_metrics %{
    tokens: %{input: 0, output: 0},
    tools: %{},
    skills: %{},
    duration_seconds: 0,
    turns: 0
  }

  setup do
    # Create a temp directory for test fixtures
    tmp_dir = Path.join(System.tmp_dir!(), "session_parser_test_#{:rand.uniform(999_999)}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    {:ok, tmp_dir: tmp_dir}
  end

  describe "parse_jsonl/1" do
    test "returns zero metrics for missing file" do
      assert SessionParser.parse_jsonl("/nonexistent/path/session.jsonl") == @zero_metrics
    end

    test "returns zero metrics for empty file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "empty.jsonl")
      File.write!(path, "")
      assert SessionParser.parse_jsonl(path) == @zero_metrics
    end

    test "extracts token usage from assistant messages", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "tokens.jsonl")

      lines = [
        jsonl_entry("assistant", %{
          "usage" => %{
            "input_tokens" => 100,
            "output_tokens" => 50,
            "cache_creation_input_tokens" => 20,
            "cache_read_input_tokens" => 10
          },
          "content" => [%{"type" => "text", "text" => "Hello"}]
        }),
        jsonl_entry("assistant", %{
          "usage" => %{
            "input_tokens" => 200,
            "output_tokens" => 75
          },
          "content" => [%{"type" => "text", "text" => "World"}]
        })
      ]

      File.write!(path, Enum.join(lines, "\n"))
      result = SessionParser.parse_jsonl(path)

      # First message: 100 + 20 + 10 = 130 input, 50 output
      # Second message: 200 input, 75 output
      assert result.tokens.input == 330
      assert result.tokens.output == 125
    end

    test "counts tool_use blocks by tool name", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "tools.jsonl")

      lines = [
        jsonl_entry("assistant", %{
          "usage" => %{"input_tokens" => 10, "output_tokens" => 5},
          "content" => [
            %{"type" => "tool_use", "id" => "t1", "name" => "Read", "input" => %{}},
            %{"type" => "tool_use", "id" => "t2", "name" => "Bash", "input" => %{}}
          ]
        }),
        jsonl_entry("assistant", %{
          "usage" => %{"input_tokens" => 10, "output_tokens" => 5},
          "content" => [
            %{"type" => "tool_use", "id" => "t3", "name" => "Read", "input" => %{}},
            %{"type" => "tool_use", "id" => "t4", "name" => "Edit", "input" => %{}},
            %{"type" => "tool_use", "id" => "t5", "name" => "Read", "input" => %{}}
          ]
        })
      ]

      File.write!(path, Enum.join(lines, "\n"))
      result = SessionParser.parse_jsonl(path)

      assert result.tools == %{"Read" => 3, "Bash" => 1, "Edit" => 1}
    end

    test "counts user turns from user messages", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "turns.jsonl")

      lines = [
        jsonl_user_entry("Hello, help me with this"),
        jsonl_entry("assistant", %{
          "usage" => %{"input_tokens" => 10, "output_tokens" => 5},
          "content" => [%{"type" => "text", "text" => "Sure!"}]
        }),
        jsonl_user_entry("Now fix the bug"),
        jsonl_entry("assistant", %{
          "usage" => %{"input_tokens" => 10, "output_tokens" => 5},
          "content" => [%{"type" => "text", "text" => "Done!"}]
        }),
        jsonl_user_entry("Thanks"),
        # Tool result user message (should NOT count as a turn)
        jsonl_entry("user", %{
          "content" => [%{"type" => "tool_result", "tool_use_id" => "t1", "content" => "ok"}]
        })
      ]

      File.write!(path, Enum.join(lines, "\n"))
      result = SessionParser.parse_jsonl(path)

      assert result.turns == 3
    end

    test "calculates session duration from timestamps", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "duration.jsonl")

      lines = [
        jsonl_entry_with_ts("user", %{"content" => "Hello"}, "2026-02-17T10:00:00.000Z"),
        jsonl_entry_with_ts("assistant", %{
          "usage" => %{"input_tokens" => 10, "output_tokens" => 5},
          "content" => [%{"type" => "text", "text" => "Hi"}]
        }, "2026-02-17T10:05:00.000Z"),
        jsonl_entry_with_ts("user", %{"content" => "Bye"}, "2026-02-17T10:10:30.000Z")
      ]

      File.write!(path, Enum.join(lines, "\n"))
      result = SessionParser.parse_jsonl(path)

      # 10:00:00 to 10:10:30 = 630 seconds
      assert result.duration_seconds == 630
    end

    test "handles malformed JSONL lines gracefully", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "malformed.jsonl")

      content = """
      {"not valid json
      #{jsonl_entry("assistant", %{"usage" => %{"input_tokens" => 100, "output_tokens" => 50}, "content" => [%{"type" => "text", "text" => "valid"}]})}
      {also invalid}
      """

      File.write!(path, content)
      result = SessionParser.parse_jsonl(path)

      # Should extract from the one valid line
      assert result.tokens.input == 100
      assert result.tokens.output == 50
    end

    test "handles entries without message field", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "no_message.jsonl")

      lines = [
        # file-history-snapshot entry (no message field)
        Jason.encode!(%{
          "type" => "file-history-snapshot",
          "messageId" => "abc",
          "timestamp" => "2026-02-17T10:00:00.000Z"
        }),
        # progress entry (no message field)
        Jason.encode!(%{
          "type" => "progress",
          "data" => %{"type" => "hook_progress"},
          "timestamp" => "2026-02-17T10:01:00.000Z"
        }),
        # Valid assistant message
        jsonl_entry_with_ts("assistant", %{
          "usage" => %{"input_tokens" => 50, "output_tokens" => 25},
          "content" => [%{"type" => "text", "text" => "Result"}]
        }, "2026-02-17T10:02:00.000Z")
      ]

      File.write!(path, Enum.join(lines, "\n"))
      result = SessionParser.parse_jsonl(path)

      assert result.tokens.input == 50
      assert result.tokens.output == 25
      # Duration from first timestamp to last
      assert result.duration_seconds == 120
    end

    test "handles assistant messages with no usage field", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "no_usage.jsonl")

      lines = [
        jsonl_entry("assistant", %{
          "content" => [%{"type" => "text", "text" => "No usage here"}]
        })
      ]

      File.write!(path, Enum.join(lines, "\n"))
      result = SessionParser.parse_jsonl(path)

      assert result.tokens.input == 0
      assert result.tokens.output == 0
    end

    test "full integration with realistic JSONL data", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "full.jsonl")

      lines = [
        jsonl_entry_with_ts("user", %{"content" => "Fix the login bug"}, "2026-02-17T09:00:00.000Z"),
        jsonl_entry_with_ts("assistant", %{
          "usage" => %{
            "input_tokens" => 5000,
            "output_tokens" => 200,
            "cache_creation_input_tokens" => 30000,
            "cache_read_input_tokens" => 0
          },
          "content" => [
            %{"type" => "text", "text" => "Let me look at the code."},
            %{"type" => "tool_use", "id" => "t1", "name" => "Read", "input" => %{"path" => "/app/login.ts"}}
          ]
        }, "2026-02-17T09:00:05.000Z"),
        # Tool result from user
        jsonl_entry_with_ts("user", %{
          "content" => [%{"type" => "tool_result", "tool_use_id" => "t1", "content" => "file contents..."}]
        }, "2026-02-17T09:00:06.000Z"),
        jsonl_entry_with_ts("assistant", %{
          "usage" => %{
            "input_tokens" => 1000,
            "output_tokens" => 150,
            "cache_read_input_tokens" => 30000
          },
          "content" => [
            %{"type" => "text", "text" => "I found the bug."},
            %{"type" => "tool_use", "id" => "t2", "name" => "Edit", "input" => %{}}
          ]
        }, "2026-02-17T09:00:10.000Z"),
        jsonl_entry_with_ts("user", %{
          "content" => [%{"type" => "tool_result", "tool_use_id" => "t2", "content" => "ok"}]
        }, "2026-02-17T09:00:11.000Z"),
        jsonl_entry_with_ts("assistant", %{
          "usage" => %{
            "input_tokens" => 500,
            "output_tokens" => 100,
            "cache_read_input_tokens" => 30000
          },
          "content" => [
            %{"type" => "text", "text" => "Fixed! Let me run the tests."},
            %{"type" => "tool_use", "id" => "t3", "name" => "Bash", "input" => %{"command" => "npm test"}},
            %{"type" => "tool_use", "id" => "t4", "name" => "Read", "input" => %{"path" => "/app/test.ts"}}
          ]
        }, "2026-02-17T09:00:20.000Z"),
        jsonl_entry_with_ts("user", %{"content" => "Great, thanks!"}, "2026-02-17T09:01:00.000Z")
      ]

      File.write!(path, Enum.join(lines, "\n"))
      result = SessionParser.parse_jsonl(path)

      # Tokens: (5000+30000+200) + (1000+30000+150) + (500+30000+100) = 96950 total
      # input: 5000+30000 + 1000+30000 + 500+30000 = 96500
      assert result.tokens.input == 96500
      # output: 200 + 150 + 100 = 450
      assert result.tokens.output == 450

      # Tools: Read x2, Edit x1, Bash x1
      assert result.tools == %{"Read" => 2, "Edit" => 1, "Bash" => 1}

      # Turns: "Fix the login bug" + "Great, thanks!" = 2
      # (tool_result messages don't count as turns)
      assert result.turns == 2

      # Duration: 09:00:00 to 09:01:00 = 60 seconds
      assert result.duration_seconds == 60
    end

    test "handles file with only non-message entries", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "no_messages.jsonl")

      lines = [
        Jason.encode!(%{"type" => "file-history-snapshot", "timestamp" => "2026-02-17T10:00:00.000Z"}),
        Jason.encode!(%{"type" => "progress", "data" => %{}, "timestamp" => "2026-02-17T10:01:00.000Z"})
      ]

      File.write!(path, Enum.join(lines, "\n"))
      result = SessionParser.parse_jsonl(path)

      assert result.tokens == %{input: 0, output: 0}
      assert result.tools == %{}
      assert result.turns == 0
      assert result.duration_seconds == 60
    end

    test "extracts skill names from Skill tool_use blocks", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "skills.jsonl")

      lines = [
        jsonl_entry_with_ts("assistant", %{
          "usage" => %{"input_tokens" => 10, "output_tokens" => 5},
          "content" => [
            %{"type" => "tool_use", "id" => "t1", "name" => "Skill",
              "input" => %{"skill" => "ralph", "args" => "--verbose"}}
          ]
        }, "2026-02-17T10:00:00.000Z"),
        jsonl_entry_with_ts("assistant", %{
          "usage" => %{"input_tokens" => 10, "output_tokens" => 5},
          "content" => [
            %{"type" => "tool_use", "id" => "t2", "name" => "Skill",
              "input" => %{"skill" => "tdd:spawn"}}
          ]
        }, "2026-02-17T10:01:00.000Z"),
        jsonl_entry_with_ts("assistant", %{
          "usage" => %{"input_tokens" => 10, "output_tokens" => 5},
          "content" => [
            %{"type" => "tool_use", "id" => "t3", "name" => "Skill",
              "input" => %{"skill" => "ralph"}}
          ]
        }, "2026-02-17T10:02:00.000Z"),
        jsonl_entry_with_ts("assistant", %{
          "usage" => %{"input_tokens" => 10, "output_tokens" => 5},
          "content" => [
            %{"type" => "tool_use", "id" => "t4", "name" => "Read",
              "input" => %{"file_path" => "/tmp/test.txt"}}
          ]
        }, "2026-02-17T10:03:00.000Z")
      ]

      File.write!(path, Enum.join(lines, "\n"))
      result = SessionParser.parse_jsonl(path)

      # Skills map tracks individual skill names
      assert result.skills == %{"ralph" => 2, "tdd:spawn" => 1}

      # Tools map has both generic Skill and specific skill:name entries
      assert result.tools["Skill"] == 3
      assert result.tools["skill:ralph"] == 2
      assert result.tools["skill:tdd:spawn"] == 1
      assert result.tools["Read"] == 1
    end
  end

  # Helper functions to build JSONL entries

  defp jsonl_entry(role, message_fields) do
    entry = %{
      "type" => role,
      "timestamp" => "2026-02-17T10:00:00.000Z",
      "message" => Map.merge(%{"role" => role}, message_fields)
    }

    Jason.encode!(entry)
  end

  defp jsonl_user_entry(text) do
    entry = %{
      "type" => "user",
      "timestamp" => "2026-02-17T10:00:00.000Z",
      "message" => %{
        "role" => "user",
        "content" => text
      }
    }

    Jason.encode!(entry)
  end

  defp jsonl_entry_with_ts(role, message_fields, timestamp) do
    entry = %{
      "type" => role,
      "timestamp" => timestamp,
      "message" => Map.merge(%{"role" => role}, message_fields)
    }

    Jason.encode!(entry)
  end
end
