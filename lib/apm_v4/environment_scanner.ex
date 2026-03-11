defmodule ApmV4.EnvironmentScanner do
  @moduledoc """
  GenServer that discovers all Claude Code environments (projects with .claude/ directories)
  and exposes their configs, hooks, and session history.
  """

  use GenServer

  @table :apm_environments
  @scan_interval :timer.minutes(5)
  @default_scan_dirs [
    Path.expand("~/Developer"),
    Path.expand("~/tools/@yj")
  ]

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns all discovered CC environments."
  def list_environments do
    :ets.tab2list(@table)
    |> Enum.map(fn {_name, env} -> env end)
    |> Enum.sort_by(& &1.last_modified, {:desc, DateTime})
  end

  @doc "Returns detail for one environment by name."
  def get_environment(name) do
    case :ets.lookup(@table, name) do
      [{^name, env}] -> {:ok, env}
      [] -> {:error, :not_found}
    end
  end

  @doc "Triggers an immediate rescan."
  def rescan do
    GenServer.call(__MODULE__, :rescan, 30_000)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    scan_dirs = Keyword.get(opts, :scan_dirs, @default_scan_dirs)
    schedule_scan()
    {:ok, %{table: table, scan_dirs: scan_dirs}, {:continue, :initial_scan}}
  end

  @impl true
  def handle_continue(:initial_scan, state) do
    do_scan(state.scan_dirs)
    {:noreply, state}
  end

  @impl true
  def handle_call(:rescan, _from, state) do
    envs = do_scan(state.scan_dirs)
    {:reply, envs, state}
  end

  @impl true
  def handle_info(:scan, state) do
    do_scan(state.scan_dirs)
    schedule_scan()
    {:noreply, state}
  end

  # --- Private ---

  defp schedule_scan do
    Process.send_after(self(), :scan, @scan_interval)
  end

  defp do_scan(scan_dirs) do
    envs =
      scan_dirs
      |> Enum.flat_map(&find_claude_projects/1)
      |> Enum.uniq_by(& &1.name)

    Enum.each(envs, fn env ->
      :ets.insert(@table, {env.name, env})
    end)

    Phoenix.PubSub.broadcast(ApmV4.PubSub, "apm:environments", {:environments_updated, length(envs)})
    envs
  end

  defp find_claude_projects(base_dir) do
    case File.ls(base_dir) do
      {:ok, entries} ->
        entries
        |> Enum.map(&Path.join(base_dir, &1))
        |> Enum.filter(&File.dir?/1)
        |> Enum.filter(fn dir -> File.dir?(Path.join(dir, ".claude")) end)
        |> Enum.map(&build_environment/1)
        |> Enum.reject(&is_nil/1)

      {:error, _} ->
        []
    end
  end

  defp build_environment(project_path) do
    name = Path.basename(project_path)
    claude_dir = Path.join(project_path, ".claude")

    claude_md_path = Path.join(project_path, "CLAUDE.md")
    has_claude_md = File.exists?(claude_md_path)
    has_git = File.dir?(Path.join(project_path, ".git"))

    claude_md_content =
      if has_claude_md do
        case File.read(claude_md_path) do
          {:ok, content} -> String.slice(content, 0, 5000)
          _ -> nil
        end
      end

    hooks = read_hooks(claude_dir)
    settings = read_settings(claude_dir)
    stack = detect_stack(project_path)
    sessions = find_sessions(name)

    last_modified =
      case File.stat(project_path) do
        {:ok, %{mtime: mtime}} -> NaiveDateTime.from_erl!(mtime) |> DateTime.from_naive!("Etc/UTC")
        _ -> DateTime.utc_now()
      end

    %{
      name: name,
      path: project_path,
      stack: stack,
      has_claude_md: has_claude_md,
      claude_md_content: claude_md_content,
      has_git: has_git,
      hooks: hooks,
      settings: settings,
      sessions: sessions,
      session_count: length(sessions),
      last_session_date: List.first(sessions)["started_at"],
      last_modified: last_modified,
      detected_at: DateTime.utc_now()
    }
  rescue
    e in [File.Error, ArgumentError, MatchError] ->
      require Logger
      Logger.warning("Failed to build environment for #{project_path}: #{inspect(e)}")
      nil
  end

  defp detect_stack(path) do
    cond do
      File.exists?(Path.join(path, "mix.exs")) -> "elixir"
      File.exists?(Path.join(path, "package.json")) -> "node"
      File.exists?(Path.join(path, "Cargo.toml")) -> "rust"
      File.exists?(Path.join(path, "go.mod")) -> "go"
      File.exists?(Path.join(path, "requirements.txt")) -> "python"
      File.exists?(Path.join(path, "Gemfile")) -> "ruby"
      true -> "unknown"
    end
  end

  defp read_hooks(claude_dir) do
    hooks_dir = Path.join(claude_dir, "hooks")

    case File.ls(hooks_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".sh"))
        |> Enum.map(fn f -> %{name: f, path: Path.join(hooks_dir, f)} end)

      _ ->
        []
    end
  end

  defp read_settings(claude_dir) do
    settings_path = Path.join(claude_dir, "settings.json")

    case File.read(settings_path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, settings} -> settings
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  defp find_sessions(project_name) do
    sessions_dir = Path.expand("~/Developer/ccem/apm/sessions")

    case File.ls(sessions_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.map(fn f ->
          path = Path.join(sessions_dir, f)

          case File.read(path) do
            {:ok, content} ->
              case Jason.decode(content) do
                {:ok, session} -> session
                _ -> nil
              end

            _ ->
              nil
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.filter(fn s -> s["project_name"] == project_name end)
        |> Enum.sort_by(& &1["started_at"], :desc)
        |> Enum.take(10)

      _ ->
        []
    end
  end
end
