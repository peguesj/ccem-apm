defmodule ApmV5.UpmPersistentRule do
  @moduledoc """
  Checks and inserts the UPM→Plane integration rule into ~/.claude/CLAUDE.md.
  Ensures the APM route table is present in the user's global CLAUDE.md.
  """
  require Logger

  @claude_md_path "~/.claude/CLAUDE.md"
  @rule_marker "## UPM→Plane Integration (APM)"

  @rule_content """

  ## UPM→Plane Integration (APM)

  When APM context is active (server running on port 3032), all UPM operations MUST emit
  notifications to the following APM endpoints:

  | Endpoint | Purpose |
  |----------|---------|
  | `POST /api/upm/register` | Register UPM session |
  | `POST /api/upm/agent` | Bind agent to story |
  | `POST /api/upm/event` | Report lifecycle event |
  | `GET /api/upm/status` | Current execution state |
  | `POST /api/notify` | Toast notification |
  | `POST /api/register` | Register agent with APM |
  | `POST /api/heartbeat` | Agent heartbeat |

  Pattern (fire-and-forget):
  ```bash
  (curl -s -X POST http://localhost:3032/api/notify \\
    -H 'Content-Type: application/json' \\
    -d '<payload>' >/dev/null 2>&1) &
  ```
  """

  @spec check_rule() :: {:present, String.t()} | {:absent, String.t()}
  def check_rule do
    path = Path.expand(@claude_md_path)
    case File.read(path) do
      {:ok, content} ->
        if String.contains?(content, @rule_marker) do
          {:present, path}
        else
          {:absent, "Rule not found in #{path}"}
        end
      {:error, :enoent} ->
        {:absent, "#{path} does not exist"}
      {:error, reason} ->
        {:absent, "Cannot read #{path}: #{inspect(reason)}"}
    end
  end

  @spec insert_rule() :: {:ok, String.t()} | {:error, String.t()}
  def insert_rule do
    path = Path.expand(@claude_md_path)
    case File.read(path) do
      {:ok, content} ->
        if String.contains?(content, @rule_marker) do
          {:ok, "Rule already present in #{path}"}
        else
          new_content = content <> @rule_content
          case File.write(path, new_content) do
            :ok -> {:ok, "Rule inserted into #{path}"}
            {:error, reason} -> {:error, "Cannot write #{path}: #{inspect(reason)}"}
          end
        end
      {:error, :enoent} ->
        case File.write(path, @rule_content) do
          :ok -> {:ok, "Created #{path} with rule"}
          {:error, reason} -> {:error, inspect(reason)}
        end
      {:error, reason} ->
        {:error, "Cannot read #{path}: #{inspect(reason)}"}
    end
  end
end
