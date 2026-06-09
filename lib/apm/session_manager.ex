defmodule Apm.SessionManager do
  @moduledoc """
  GenServer that polls Claude Code session JSON files and enriches them with
  live context: active agents, ports, plugins, CLAUDE.md preview, and counts
  for memory/skills/hooks in the project's .claude directory.

  Broadcasts `"apm:sessions"` PubSub topic on changes.
  """

  use GenServer
  require Logger

  alias Apm.{AgentRegistry, PortManager, PubSub}

  @sessions_dir "~/Developer/ccem/apm/sessions"
  @claude_projects_dir "~/.claude/projects"
  @poll_interval_ms 30_000
  @pubsub_topic "apm:sessions"

  # ── Public API ──────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec list_sessions() :: [map()]
  def list_sessions do
    case :ets.whereis(:session_manager_cache) do
      :undefined -> []
      _ -> :ets.lookup(:session_manager_cache, :sessions) |> Keyword.get(:sessions, [])
    end
  end

  @spec get_session(String.t()) :: map() | nil
  def get_session(session_id) do
    list_sessions() |> Enum.find(&(&1.session_id == session_id))
  end

  @spec get_session_with_context(String.t()) :: map() | nil
  def get_session_with_context(session_id) do
    case get_session(session_id) do
      nil -> nil
      session -> enrich_deep(session)
    end
  end

  @spec refresh() :: :ok
  def refresh, do: GenServer.cast(__MODULE__, :refresh)

  # ── GenServer callbacks ──────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    :ets.new(:session_manager_cache, [:named_table, :public, read_concurrency: true])
    :ets.insert(:session_manager_cache, {:sessions, []})
    # Defer first poll to avoid PortManager timeout during boot (APM-001)
    Process.send_after(self(), :poll, 5_000)
    {:ok, %{last_hash: nil}}
  end

  @impl true
  def handle_info(:poll, state) do
    sessions = load_and_enrich_all()
    hash = :erlang.phash2(sessions)

    if hash != state.last_hash do
      :ets.insert(:session_manager_cache, {:sessions, sessions})
      Phoenix.PubSub.broadcast(PubSub, @pubsub_topic, {:sessions_updated, sessions})
    end

    Process.send_after(self(), :poll, @poll_interval_ms)
    {:noreply, %{state | last_hash: hash}}
  end

  @impl true
  def handle_cast(:refresh, state) do
    send(self(), :poll)
    {:noreply, state}
  end

  # ── Private helpers ──────────────────────────────────────────────────────────

  defp load_and_enrich_all do
    apm_sessions = load_apm_sessions()
    jsonl_sessions = load_jsonl_sessions()

    (apm_sessions ++ jsonl_sessions)
    |> Enum.uniq_by(fn s -> to_string(s[:session_id] || s[:sessionId] || "") end)
    |> Enum.reject(fn s -> to_string(s[:session_id] || s[:sessionId] || "") == "" end)
    |> Enum.map(&enrich_basic/1)
    |> Enum.sort_by(&Map.get(&1, :start_time, ""), :desc)
  end

  defp load_apm_sessions do
    sessions_dir = Path.expand(@sessions_dir)

    case File.ls(sessions_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.map(&Path.join(sessions_dir, &1))
        |> Enum.flat_map(&parse_session_file/1)

      {:error, reason} ->
        Logger.warning("SessionManager: cannot read #{sessions_dir}: #{inspect(reason)}")
        []
    end
  end

  defp load_jsonl_sessions do
    projects_dir = Path.expand(@claude_projects_dir)

    case File.ls(projects_dir) do
      {:ok, project_dirs} ->
        project_dirs
        |> Enum.flat_map(fn dir_name ->
          dir_path = Path.join(projects_dir, dir_name)

          case File.ls(dir_path) do
            {:ok, files} ->
              files
              |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
              |> Enum.map(fn file ->
                session_id = String.replace_suffix(file, ".jsonl", "")
                path = Path.join(dir_path, file)
                parse_jsonl_session(path, session_id)
              end)
              |> Enum.reject(&is_nil/1)

            {:error, _} ->
              []
          end
        end)

      {:error, _} ->
        []
    end
  end

  defp parse_jsonl_session(path, session_id) do
    try do
      with {:ok, content} <- File.read(path),
           [first_line | _] <- String.split(content, "\n", trim: true),
           {:ok, data} <- Jason.decode(first_line) do
        cwd = Map.get(data, "cwd", "")
        timestamp = Map.get(data, "timestamp", "")
        branch = Map.get(data, "gitBranch")
        slug = Map.get(data, "slug", session_id)
        version = Map.get(data, "version")

        %{
          session_id: session_id,
          project_root: cwd,
          project_name: Path.basename(cwd),
          start_time: timestamp,
          git_branch: branch,
          slug: slug,
          version: version,
          source: :claude_native
        }
      else
        _ -> nil
      end
    rescue
      _ -> nil
    end
  end

  defp parse_session_file(path) do
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content, keys: :atoms) do
          {:ok, data} -> [data]
          {:error, _} -> []
        end

      {:error, _} ->
        []
    end
  end

  # Basic enrichment: agents + ports (cheap registry lookups)
  defp enrich_basic(session) do
    session_id = to_string(session[:session_id] || "")
    project_root = to_string(session[:project_root] || "")

    # Agents registered under this session (catch exits from GenServer timeouts)
    agents =
      try do
        AgentRegistry.list_agents()
        |> Enum.filter(fn a ->
          Map.get(a, :session_id, "") == session_id ||
            Map.get(a, :project, "") == Map.get(session, :project_name, "")
        end)
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end

    # Ports bound to this project root (catch exits from GenServer timeouts)
    ports =
      try do
        PortManager.get_port_map()
        |> Enum.filter(fn {_port, info} ->
          proj = Map.get(info, :project, "")
          String.contains?(proj, project_root) || String.contains?(project_root, proj)
        end)
        |> Enum.map(fn {port, info} -> Map.put(info, :port, port) end)
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end

    # Claude config directory counts (fast filesystem scan)
    claude_config = scan_claude_config(project_root)

    Map.merge(session, %{
      agents: agents,
      agent_count: length(agents),
      ports: ports,
      port_count: length(ports),
      claude_config: claude_config,
      plugins: [],
      plugin_count: 0,
      enriched_at: DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end

  # Deep enrichment: adds plugins + CLAUDE.md full content + CoWork context
  defp enrich_deep(session) do
    project_root = to_string(session[:project_root] || "")

    plugins =
      try do
        Apm.Plugins.PluginRegistry.list_plugins()
      rescue
        _ -> []
      end

    claude_md_content =
      [
        Path.join([project_root, ".claude", "CLAUDE.md"]),
        Path.join([project_root, "CLAUDE.md"])
      ]
      |> Enum.find_value("", fn path ->
        case File.read(path) do
          {:ok, content} -> content
          _ -> nil
        end
      end)

    Map.merge(session, %{
      plugins: plugins,
      plugin_count: length(plugins),
      claude_md_content: claude_md_content,
      cowork: cowork_context()
    })
  end

  # Returns CoWork team and task context from ~/.claude/teams/ and ~/.claude/tasks/.
  # Completely fail-safe — returns empty defaults on any error.
  @spec cowork_context() :: %{
          teams: [map()],
          tasks: %{total: non_neg_integer(), active: non_neg_integer()}
        }
  defp cowork_context do
    teams_dir = Path.expand("~/.claude/teams")
    tasks_dir = Path.expand("~/.claude/tasks")

    teams =
      try do
        case File.ls(teams_dir) do
          {:ok, files} ->
            files
            |> Enum.filter(&String.ends_with?(&1, ".json"))
            |> Enum.flat_map(fn file ->
              path = Path.join(teams_dir, file)

              case File.read(path) do
                {:ok, content} ->
                  case Jason.decode(content) do
                    {:ok, team} when is_map(team) ->
                      [Map.take(team, ["id", "name", "members", "created_at"])]

                    _ ->
                      []
                  end

                _ ->
                  []
              end
            end)

          _ ->
            []
        end
      rescue
        _ -> []
      end

    tasks =
      try do
        case File.ls(tasks_dir) do
          {:ok, files} ->
            all_tasks =
              files
              |> Enum.filter(&String.ends_with?(&1, ".json"))
              |> Enum.flat_map(fn file ->
                path = Path.join(tasks_dir, file)

                case File.read(path) do
                  {:ok, content} ->
                    case Jason.decode(content) do
                      {:ok, task} when is_map(task) -> [task]
                      _ -> []
                    end

                  _ ->
                    []
                end
              end)

            total = length(all_tasks)

            active =
              Enum.count(all_tasks, fn t -> Map.get(t, "status", "active") != "completed" end)

            %{total: total, active: active}

          _ ->
            %{total: 0, active: 0}
        end
      rescue
        _ -> %{total: 0, active: 0}
      end

    %{teams: teams, tasks: tasks}
  end

  defp scan_claude_config(project_root) when byte_size(project_root) == 0, do: %{}

  defp scan_claude_config(project_root) do
    claude_dir = Path.join(project_root, ".claude")

    %{
      memory_count: count_files(claude_dir, "memory", ".md"),
      agent_count: count_files(claude_dir, "agents", "*"),
      skill_count: count_files(claude_dir, "skills", "*"),
      hook_count: count_hooks(project_root),
      has_claude_md: File.exists?(Path.join(claude_dir, "CLAUDE.md")),
      claude_md_preview: read_preview(Path.join(claude_dir, "CLAUDE.md"), 500)
    }
  end

  defp count_files(base, subdir, _ext) do
    path = Path.join(base, subdir)

    case File.ls(path) do
      {:ok, files} -> length(files)
      _ -> 0
    end
  end

  defp count_hooks(_project_root) do
    hooks_dir = Path.expand("~/Developer/ccem/apm/hooks")

    case File.ls(hooks_dir) do
      {:ok, files} ->
        # Count .sh files (hooks apply to all projects via global settings)
        Enum.count(files, &String.ends_with?(&1, ".sh"))

      _ ->
        0
    end
  end

  defp read_preview(path, max_chars) do
    case File.read(path) do
      {:ok, content} ->
        content
        |> String.slice(0, max_chars)
        |> String.trim()

      _ ->
        ""
    end
  end
end
