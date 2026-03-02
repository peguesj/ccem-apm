defmodule ApmV4.ProjectScanner do
  @moduledoc """
  GenServer that scans developer directories for Claude Code projects.
  Detects stack, ports, agent/formation counts, and APM config presence.
  """
  use GenServer

  @base_paths ["~/Developer", "~/Projects", "~/Code", "~/workspace"]

  @stack_indicators %{
    "node" => ["package.json"],
    "elixir" => ["mix.exs"],
    "python" => ["requirements.txt", "pyproject.toml", "setup.py"],
    "rust" => ["Cargo.toml"],
    "go" => ["go.mod"],
    "ruby" => ["Gemfile"],
    "swift" => ["Package.swift"],
    "java" => ["build.gradle", "pom.xml"],
    "dotnet" => ["*.csproj", "*.sln"]
  }

  # --- Client API ---

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def scan(base_path \\ nil) do
    GenServer.call(__MODULE__, {:scan, base_path}, 60_000)
  end

  def get_results do
    GenServer.call(__MODULE__, :get_results)
  end

  def get_status do
    GenServer.call(__MODULE__, :get_status)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_) do
    {:ok, %{results: [], status: :idle, scanned_at: nil, base_path: nil}}
  end

  @impl true
  def handle_call({:scan, base_path}, _from, state) do
    path = resolve_path(base_path || hd(@base_paths))
    new_state = %{state | status: :scanning, base_path: path}

    results = do_scan(path)
    final_state = %{new_state | results: results, status: :done, scanned_at: DateTime.utc_now() |> DateTime.to_iso8601()}

    {:reply, {:ok, results}, final_state}
  end

  def handle_call(:get_results, _from, state) do
    {:reply, state.results, state}
  end

  def handle_call(:get_status, _from, state) do
    {:reply, %{
      status: state.status,
      scanned_at: state.scanned_at,
      project_count: length(state.results),
      base_path: state.base_path
    }, state}
  end

  # --- Scanning logic ---

  defp do_scan(base_path) do
    unless File.exists?(base_path), do: (return [])

    base_path
    |> File.ls!()
    |> Enum.map(&Path.join(base_path, &1))
    |> Enum.filter(&File.dir?/1)
    |> Enum.reject(&String.starts_with?(Path.basename(&1), "."))
    |> Enum.map(&analyze_project/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.name)
  rescue
    _ -> []
  end

  defp return(val), do: val

  defp analyze_project(path) do
    name = Path.basename(path)
    files = list_files(path)

    stack = detect_stack(path, files)
    return_nil_if_empty = stack == [] and not has_claude_config(path)

    if return_nil_if_empty and not File.exists?(Path.join(path, "README.md")) do
      nil
    else
      %{
        name: name,
        path: path,
        stack: stack,
        ports: detect_ports(path),
        has_claude_config: has_claude_config(path),
        agent_count: count_agents(path),
        formation_count: count_formations(path),
        last_modified: last_modified(path)
      }
    end
  rescue
    _ -> nil
  end

  defp list_files(path) do
    case File.ls(path) do
      {:ok, files} -> files
      _ -> []
    end
  end

  defp detect_stack(path, files) do
    @stack_indicators
    |> Enum.filter(fn {_lang, indicators} ->
      Enum.any?(indicators, fn indicator ->
        if String.contains?(indicator, "*") do
          pattern = Path.join(path, indicator)
          case Path.wildcard(pattern) do
            [] -> false
            _ -> true
          end
        else
          indicator in files
        end
      end)
    end)
    |> Enum.map(fn {lang, _} -> lang end)
  end

  defp detect_ports(path) do
    env_files = [".env", ".env.local", ".env.development", ".env.example"]
    port_regex = ~r/(?:PORT|DEV_PORT|APP_PORT|SERVER_PORT)\s*=\s*(\d+)/

    env_files
    |> Enum.flat_map(fn f ->
      file_path = Path.join(path, f)
      case File.read(file_path) do
        {:ok, content} ->
          Regex.scan(port_regex, content)
          |> Enum.map(fn [_, port] -> String.to_integer(port) end)
        _ -> []
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp has_claude_config(path) do
    File.exists?(Path.join(path, ".claude")) or
      File.exists?(Path.join(path, ".claude/CLAUDE.md")) or
      File.exists?(Path.join(path, ".claude/apm_config.json"))
  end

  defp count_agents(path) do
    skills_dir = Path.join(path, ".claude/skills")
    agents_dir = Path.join(path, ".claude/agents")

    count_dir_entries(skills_dir) + count_dir_entries(agents_dir)
  end

  defp count_formations(path) do
    formations_glob = Path.join(path, ".claude/**/*formation*")
    Path.wildcard(formations_glob) |> length()
  end

  defp count_dir_entries(dir) do
    case File.ls(dir) do
      {:ok, entries} -> length(entries)
      _ -> 0
    end
  end

  defp last_modified(path) do
    case File.stat(path) do
      {:ok, %{mtime: mtime}} ->
        mtime
        |> NaiveDateTime.from_erl!()
        |> DateTime.from_naive!("Etc/UTC")
        |> DateTime.to_iso8601()
      _ -> nil
    end
  end

  defp resolve_path("~/" <> rest), do: Path.join(System.user_home!(), rest)
  defp resolve_path(path), do: path
end
