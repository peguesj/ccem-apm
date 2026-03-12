defmodule ApmV5.ProjectScanner do
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

  @doc "Returns Claude Code native configuration for a given project path."
  @spec scan_claude_native(String.t()) :: map()
  def scan_claude_native(path) do
    settings_path = Path.join(path, ".claude/settings.json")

    settings =
      case File.read(settings_path) do
        {:ok, raw} ->
          case Jason.decode(raw) do
            {:ok, parsed} -> parsed
            _ -> %{}
          end

        _ ->
          %{}
      end

    claude_md_path = Path.join(path, ".claude/CLAUDE.md")

    {md_sections, has_upm, has_formation_md} =
      case File.read(claude_md_path) do
        {:ok, content} ->
          sections =
            content
            |> String.split("\n")
            |> Enum.filter(&String.starts_with?(&1, "## "))
            |> Enum.map(&String.trim_leading(&1, "## "))

          {sections, String.contains?(content, "upm") or String.contains?(content, "/upm"),
           String.contains?(content, "formation") or String.contains?(content, "Formation")}

        _ ->
          {[], false, false}
      end

    has_worktrees = File.dir?(Path.join(path, ".worktrees"))

    %{
      claude_hooks: extract_hooks(settings),
      mcps_installed: extract_mcps(settings),
      active_ports: list_active_ports(),
      claude_md_sections: md_sections,
      has_upm: has_upm,
      has_formation: has_formation_md or has_worktrees
    }
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

  defp extract_hooks(settings) do
    case Map.get(settings, "hooks") do
      hooks when is_map(hooks) -> Map.keys(hooks)
      _ -> []
    end
  end

  defp extract_mcps(settings) do
    case Map.get(settings, "mcpServers") do
      mcps when is_map(mcps) -> Map.keys(mcps)
      _ -> []
    end
  end

  defp list_active_ports do
    case System.cmd("lsof", ["-iTCP", "-n", "-P", "-sTCP:LISTEN"], stderr_to_stdout: false) do
      {output, 0} ->
        output
        |> String.split("\n")
        |> Enum.drop(1)
        |> Enum.flat_map(fn line ->
          parts = String.split(line, ~r/\s+/)

          case Enum.at(parts, 4) do
            nil ->
              []

            addr ->
              case Regex.run(~r/:(\d+)$/, addr) do
                [_, port] -> [%{port: String.to_integer(port), process: Enum.at(parts, 0, "")}]
                _ -> []
              end
          end
        end)
        |> Enum.uniq_by(& &1.port)
        |> Enum.sort_by(& &1.port)

      _ ->
        []
    end
  end
end
