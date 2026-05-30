defmodule Apm.Auth.CommandContextExtractor do
  @moduledoc """
  Extracts actionable command context from tool parameters to enhance authorization approvals.

  Rather than showing users "Bash: :high risk" without details, this module enriches
  the approval request with human-readable action types and command summaries:

  - Input: {tool_name, params}
  - Output: {action_type, action_detail, enhanced_risk_level}

  ## Examples

      iex> CommandContextExtractor.analyze("Bash", %{"command" => "rm -rf /tmp/*"})
      {:ok, %{
        action_type: :destructive,
        action_detail: "delete recursive (/tmp/*)",
        risk_rationale: "Destructive file operation",
        approval_reasoning: "This approval allows: executing shell commands that DELETE FILES OR DIRECTORIES recursively. Use with extreme caution."
      }}

      iex> CommandContextExtractor.analyze("Bash", %{"command" => "find /app -name '*.log' -type f"})
      {:ok, %{
        action_type: :read,
        action_detail: "find files (pattern: *.log in /app)",
        risk_rationale: "Read-only file operation",
        approval_reasoning: "This approval allows: searching for files matching a pattern. No files are modified."
      }}

      iex> CommandContextExtractor.analyze("Bash", %{"command" => "cat /etc/passwd"})
      {:ok, %{
        action_type: :read,
        action_detail: "read file (/etc/passwd)",
        risk_rationale: "Read-only file operation",
        approval_reasoning: "This approval allows: reading file contents. No files are modified."
      }}

      iex> CommandContextExtractor.analyze("Write", %{"file_path" => "/app/main.ex", "content" => "..."})
      {:ok, %{
        action_type: :write,
        action_detail: "write to file (/app/main.ex)",
        risk_rationale: "Modify file operation",
        approval_reasoning: "This approval allows: writing to or modifying a file. The file will be changed."
      }}
  """

  @destructive_bash_patterns [
    # File deletion
    ~r/^\s*(rm|rmdir|shred)(\s|$)/i,
    ~r/^\s*find.*-delete/i,
    ~r/>\s*\/dev\/null\s*2>&1/,
    # Database operations
    ~r/^\s*(drop|delete|truncate)\s+(table|database)/i,
    # Git force operations
    ~r/git\s+(push|reset|rebase)\s+--force/i,
    # Process killing
    ~r/^\s*(pkill|killall|kill\s+-9)/i,
    # Disk operations
    ~r/^\s*(dd|mkfs|fsck)/i
  ]

  @read_bash_patterns [
    ~r/^\s*(cat|less|more|head|tail|grep|find|ls|find|locate|stat|file|which|whereis)/i,
    ~r/^\s*file\s+/i,
    ~r/^\s*strings\s+/i,
    ~r/^\s*readlink/i
  ]

  @write_bash_patterns [
    ~r/^\s*(cp|mv|touch|tee|sed|awk)/i,
    ~r/^\s*rsync(\s|$)/i,
    ~r/^\s*install(\s|$)/i
  ]

  @doc """
  Analyze a tool call and extract command context.

  Returns `{:ok, context_map}` with action_type, action_detail, risk_rationale, and approval_reasoning.
  Returns `{:error, reason}` if analysis fails.
  """
  @spec analyze(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def analyze(tool_name, params) when is_map(params) do
    case tool_name do
      "Bash" -> analyze_bash(params)
      "Write" -> analyze_write(params)
      "Edit" -> analyze_edit(params)
      "MultiEdit" -> analyze_multiedit(params)
      "Read" -> {:ok, read_context()}
      "Grep" -> {:ok, grep_context(params)}
      "Glob" -> {:ok, glob_context(params)}
      _ -> {:ok, generic_context(tool_name, params)}
    end
  end

  def analyze(_, _), do: {:error, :invalid_params}

  # ── Bash Command Analysis ───────────────────────────────────────────────────

  defp analyze_bash(%{"command" => command}) when is_binary(command) do
    cond do
      destructive_bash?(command) ->
        {:ok, %{
          action_type: :destructive,
          action_detail: extract_bash_operation(command, "destructive"),
          risk_rationale: "Destructive shell operation — deletes, kills, or modifies system state",
          approval_reasoning: "This approval allows: executing shell commands that DELETE FILES, DIRECTORIES, PROCESSES, or modify the system. Use with extreme caution. This operation cannot be undone."
        }}

      read_bash?(command) ->
        {:ok, %{
          action_type: :read,
          action_detail: extract_bash_operation(command, "read"),
          risk_rationale: "Read-only shell operation — no modifications",
          approval_reasoning: "This approval allows: executing shell commands that READ file contents or query the system. No files or processes are modified."
        }}

      write_bash?(command) ->
        {:ok, %{
          action_type: :write,
          action_detail: extract_bash_operation(command, "write"),
          risk_rationale: "Write/modify shell operation",
          approval_reasoning: "This approval allows: executing shell commands that CREATE, COPY, MOVE, or MODIFY files. These changes may impact your project."
        }}

      true ->
        {:ok, %{
          action_type: :unknown,
          action_detail: extract_bash_operation(command, "unknown"),
          risk_rationale: "Shell operation (type unclear)",
          approval_reasoning: "This approval allows: executing a shell command. Review the command carefully before approving."
        }}
    end
  end

  defp analyze_bash(_), do: {:error, :missing_command}

  # ── File Write Analysis ─────────────────────────────────────────────────────

  defp analyze_write(%{"file_path" => file_path}) when is_binary(file_path) do
    {:ok, %{
      action_type: :write,
      action_detail: "write to file (#{truncate_path(file_path)})",
      risk_rationale: "Modify file — may affect project or system behavior",
      approval_reasoning: "This approval allows: writing to or creating the file at '#{truncate_path(file_path)}'. This will permanently modify that file."
    }}
  end

  defp analyze_write(_), do: {:error, :missing_file_path}

  # ── File Edit Analysis ──────────────────────────────────────────────────────

  defp analyze_edit(%{"file_path" => file_path}) when is_binary(file_path) do
    {:ok, %{
      action_type: :write,
      action_detail: "edit file (#{truncate_path(file_path)})",
      risk_rationale: "Modify existing file — may affect project or system behavior",
      approval_reasoning: "This approval allows: modifying the file at '#{truncate_path(file_path)}'. The file will be changed."
    }}
  end

  defp analyze_edit(_), do: {:error, :missing_file_path}

  # ── MultiEdit Analysis ──────────────────────────────────────────────────────

  defp analyze_multiedit(params) when is_map(params) do
    file_count = count_files_in_params(params)

    {:ok, %{
      action_type: :write,
      action_detail: "edit #{file_count} file(s)",
      risk_rationale: "Modify multiple files — broad impact on project",
      approval_reasoning: "This approval allows: modifying #{file_count} file(s) in bulk. Multiple files will be changed."
    }}
  end

  defp analyze_multiedit(_), do: {:error, :invalid_multiedit}

  # ── Helper Contexts ────────────────────────────────────────────────────────

  defp read_context do
    %{
      action_type: :read,
      action_detail: "read file(s)",
      risk_rationale: "Read-only operation",
      approval_reasoning: "This approval allows: reading file contents. No files are modified."
    }
  end

  defp grep_context(%{"pattern" => pattern}) when is_binary(pattern) do
    %{
      action_type: :read,
      action_detail: "grep for pattern (#{truncate_string(pattern, 40)})",
      risk_rationale: "Read-only operation",
      approval_reasoning: "This approval allows: searching files for a pattern. No files are modified."
    }
  end

  defp grep_context(_) do
    %{
      action_type: :read,
      action_detail: "grep search",
      risk_rationale: "Read-only operation",
      approval_reasoning: "This approval allows: searching files for a pattern. No files are modified."
    }
  end

  defp glob_context(%{"pattern" => pattern}) when is_binary(pattern) do
    %{
      action_type: :read,
      action_detail: "glob files (#{truncate_string(pattern, 40)})",
      risk_rationale: "Read-only operation",
      approval_reasoning: "This approval allows: finding files matching a pattern. No files are modified."
    }
  end

  defp glob_context(_) do
    %{
      action_type: :read,
      action_detail: "glob search",
      risk_rationale: "Read-only operation",
      approval_reasoning: "This approval allows: finding files matching a pattern. No files are modified."
    }
  end

  defp generic_context(tool_name, _params) do
    %{
      action_type: :unknown,
      action_detail: "#{tool_name} operation",
      risk_rationale: "Operation type unclear",
      approval_reasoning: "This approval allows: invoking the #{tool_name} tool. Review the tool's documentation before approving."
    }
  end

  # ── Bash Pattern Matching ───────────────────────────────────────────────────

  defp destructive_bash?(command) do
    Enum.any?(@destructive_bash_patterns, &Regex.match?(&1, command))
  end

  defp read_bash?(command) do
    Enum.any?(@read_bash_patterns, &Regex.match?(&1, command))
  end

  defp write_bash?(command) do
    Enum.any?(@write_bash_patterns, &Regex.match?(&1, command))
  end

  # ── Command Operation Extraction ────────────────────────────────────────────

  defp extract_bash_operation(command, type) do
    command = String.trim(command)

    case type do
      "destructive" ->
        cond do
          Regex.match?(~r/^\s*(rm|rmdir)/, command) ->
            extract_rm_op(command)

          Regex.match?(~r/^\s*(shred)/, command) ->
            "securely delete file(s)"

          Regex.match?(~r/^\s*find.*-delete/i, command) ->
            "find and delete files"

          Regex.match?(~r/drop\s+(table|database)/i, command) ->
            extract_sql_delete(command)

          Regex.match?(~r/git\s+push.*--force/i, command) ->
            "force push to git repository"

          Regex.match?(~r/git\s+reset.*--hard/i, command) ->
            "hard reset git repository"

          Regex.match?(~r/^\s*(pkill|killall|kill\s+-9)/i, command) ->
            "kill process(es)"

          Regex.match?(~r/>\s*\/dev\/null/, command) ->
            "redirect to /dev/null"

          true ->
            truncate_command(command, 60)
        end

      "read" ->
        cond do
          Regex.match?(~r/^\s*cat\s+(.+)/i, command) ->
            case Regex.run(~r/^\s*cat\s+(.+)$/i, command) do
              [_, path] -> "read file (#{truncate_string(String.trim(path), 30)})"
              _ -> "read file(s)"
            end

          Regex.match?(~r/^\s*find\s+(.+)/i, command) ->
            "find files (see command details)"

          Regex.match?(~r/^\s*grep/, command) ->
            "grep search"

          Regex.match?(~r/^\s*ls(\s|$)/i, command) ->
            "list directory"

          true ->
            truncate_command(command, 60)
        end

      "write" ->
        cond do
          Regex.match?(~r/^\s*cp\s+/, command) ->
            "copy file(s)"

          Regex.match?(~r/^\s*mv\s+/, command) ->
            "move/rename file(s)"

          Regex.match?(~r/^\s*sed\s+/, command) ->
            "stream edit file(s)"

          Regex.match?(~r/^\s*tee\s+/, command) ->
            "write to file via pipe"

          true ->
            truncate_command(command, 60)
        end

      _ ->
        truncate_command(command, 60)
    end
  end

  defp extract_rm_op(command) do
    cond do
      Regex.match?(~r/rm\s+-rf/i, command) ->
        case Regex.run(~r/rm\s+-rf\s+(\S+)/i, command) do
          [_, target] -> "delete recursive (#{truncate_string(target, 30)})"
          _ -> "delete recursive"
        end

      Regex.match?(~r/rm\s+/, command) ->
        case Regex.run(~r/rm\s+(.+)$/i, command) do
          [_, targets] -> "delete file(s) (#{truncate_string(targets, 30)})"
          _ -> "delete file(s)"
        end

      true ->
        "delete file(s)"
    end
  end

  defp extract_sql_delete(command) do
    cond do
      Regex.match?(~r/drop\s+table/i, command) ->
        case Regex.run(~r/drop\s+table\s+(\w+)/i, command) do
          [_, table] -> "drop table (#{table})"
          _ -> "drop table"
        end

      Regex.match?(~r/drop\s+database/i, command) ->
        case Regex.run(~r/drop\s+database\s+(\w+)/i, command) do
          [_, db] -> "drop database (#{db})"
          _ -> "drop database"
        end

      true ->
        "drop database/table"
    end
  end

  # ── String Utilities ────────────────────────────────────────────────────────

  defp truncate_path(path) do
    truncate_string(path, 35)
  end

  defp truncate_string(str, len) when byte_size(str) > len do
    String.slice(str, 0, len - 2) <> "…"
  end

  defp truncate_string(str, _len), do: str

  defp truncate_command(cmd, len) do
    cmd
    |> String.replace("\n", " ")
    |> truncate_string(len)
  end

  defp count_files_in_params(params) do
    Enum.count(params, fn {k, _v} ->
      String.contains?(k, ["file_path", "path", "file"])
    end)
  end
end
