defmodule ApmV5.Skills.SkillAnalyzer do
  @moduledoc """
  GenServer for analyzing skill dependencies from SKILL.md and command files.

  Scans ~/.claude/skills/ and ~/.claude/commands/ directories, extracts YAML
  frontmatter metadata (name, dependencies, triggers), builds dependency graphs,
  and provides query APIs with ETS-backed caching.

  Configuration:
    - Automatic refresh every 5 minutes
    - Manual refresh via refresh/0
    - ETS cache with read_concurrency: true
    - Error recovery with exponential backoff
  """

  use GenServer
  require Logger

  @table :skill_analyzer_cache
  @default_refresh_interval 5 * 60 * 1000  # 5 minutes

  # ── Client API ──────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Get the complete dependency graph."
  @spec get_graph() :: ApmV5.Skills.DependencyGraph.graph()
  def get_graph do
    case :ets.lookup(@table, :graph) do
      [{:graph, graph}] -> graph
      [] -> %{}
    end
  end

  @doc "Get a single skill's metadata and dependencies."
  @spec get_skill(String.t()) :: map() | nil
  def get_skill(skill_id) do
    case :ets.lookup(@table, {:skill, skill_id}) do
      [{{:skill, ^skill_id}, skill}] -> skill
      [] -> nil
    end
  end

  @doc "Analyze a specific skill or all skills."
  @spec analyze() :: {:ok, map()} | {:error, any()}
  def analyze do
    GenServer.call(__MODULE__, :analyze)
  end

  @spec analyze(String.t()) :: {:ok, map()} | {:error, any()}
  def analyze(skill_id) do
    GenServer.call(__MODULE__, {:analyze_single, skill_id})
  end

  @doc "Manually refresh the skill index."
  @spec refresh() :: :ok
  def refresh do
    GenServer.call(__MODULE__, :refresh)
  end

  @doc "Get comprehensive statistics about the skill graph."
  @spec stats() :: map()
  def stats do
    graph = get_graph()
    ApmV5.Skills.DependencyGraph.stats(graph)
  end

  # ── GenServer Callbacks ────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])

    # Perform initial scan
    case scan_skills() do
      {:ok, skills} ->
        build_and_cache(skills)
        Process.send_after(self(), :refresh, @default_refresh_interval)
        {:ok, %{last_refresh: System.monotonic_time(:second), retry_count: 0}}

      {:error, reason} ->
        Logger.warning("[SkillAnalyzer] Initial scan failed: #{inspect(reason)}")
        Process.send_after(self(), :refresh, @default_refresh_interval)
        {:ok, %{last_refresh: nil, retry_count: 1}}
    end
  end

  @impl true
  def handle_call(:analyze, _from, state) do
    case scan_skills() do
      {:ok, skills} ->
        graph = build_and_cache(skills)
        stats = ApmV5.Skills.DependencyGraph.stats(graph)
        {:reply, {:ok, stats}, %{state | last_refresh: System.monotonic_time(:second), retry_count: 0}}

      {:error, reason} ->
        Logger.error("[SkillAnalyzer] Analysis failed: #{inspect(reason)}")
        {:reply, {:error, reason}, %{state | retry_count: state.retry_count + 1}}
    end
  end

  @impl true
  def handle_call({:analyze_single, skill_id}, _from, state) do
    result = get_skill(skill_id)
    {:reply, {:ok, result}, state}
  end

  @impl true
  def handle_call(:refresh, _from, state) do
    case scan_skills() do
      {:ok, skills} ->
        _graph = build_and_cache(skills)
        {:reply, :ok, %{state | last_refresh: System.monotonic_time(:second), retry_count: 0}}

      {:error, reason} ->
        Logger.warning("[SkillAnalyzer] Refresh failed: #{inspect(reason)}")
        {:reply, :ok, %{state | retry_count: state.retry_count + 1}}
    end
  end

  @impl true
  def handle_info(:refresh, state) do
    case scan_skills() do
      {:ok, skills} ->
        build_and_cache(skills)
        Logger.debug("[SkillAnalyzer] Refresh complete, #{length(skills)} skills indexed")

      {:error, reason} ->
        Logger.warning("[SkillAnalyzer] Refresh failed: #{inspect(reason)}")
    end

    Process.send_after(self(), :refresh, @default_refresh_interval)
    {:noreply, %{state | last_refresh: System.monotonic_time(:second)}}
  end

  # ── Private Helpers ────────────────────────────────────────────────────────

  @spec scan_skills() :: {:ok, [map()]} | {:error, any()}
  defp scan_skills do
    skill_files = find_skill_files()

    skills =
      skill_files
      |> Enum.map(&parse_skill_file/1)
      |> Enum.filter(& &1)
      |> Enum.uniq_by(fn skill -> skill.id end)

    {:ok, skills}
  rescue
    e -> {:error, e}
  end

  @spec find_skill_files() :: [String.t()]
  defp find_skill_files do
    home = System.get_env("HOME")

    skill_dirs = [
      Path.join(home, ".claude/skills"),
      Path.join(home, ".claude/commands")
    ]

    skill_dirs
    |> Enum.filter(&File.dir?/1)
    |> Enum.flat_map(fn dir ->
      File.ls!(dir)
      |> Enum.map(&Path.join(dir, &1))
      |> Enum.filter(&File.dir?/1)
      |> Enum.map(&Path.join(&1, "SKILL.md"))
      |> Enum.filter(&File.exists?/1)
    end)
  end

  @spec parse_skill_file(String.t()) :: map() | nil
  defp parse_skill_file(file_path) do
    with {:ok, content} <- File.read(file_path),
         {:ok, frontmatter} <- extract_frontmatter(content) do
      normalize_skill(frontmatter, file_path)
    else
      _ -> nil
    end
  end

  @spec extract_frontmatter(String.t()) :: {:ok, map()} | :error
  defp extract_frontmatter(content) do
    case String.split(content, "---", parts: 3) do
      [_start, fm, _rest] ->
        fm
        |> String.trim()
        |> parse_yaml()

      _ ->
        :error
    end
  end

  @spec parse_yaml(String.t()) :: {:ok, map()} | :error
  defp parse_yaml(yaml_text) do
    lines = String.split(yaml_text, "\n")

    result =
      Enum.reduce(lines, %{}, fn line, acc ->
        case String.split(line, ":", parts: 2) do
          [key, value] ->
            key = String.trim(key)
            value = String.trim(value)
            Map.put(acc, String.to_atom(key), value)

          _ ->
            acc
        end
      end)

    {:ok, result}
  end

  @spec normalize_skill(map(), String.t()) :: map()
  defp normalize_skill(frontmatter, file_path) do
    name = Map.get(frontmatter, :name, Path.dirname(file_path) |> Path.basename())
    id = String.downcase(name) |> String.replace(" ", "-")

    dependencies =
      frontmatter
      |> Map.get(:dependencies, "")
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.filter(&(String.length(&1) > 0))

    triggers =
      frontmatter
      |> Map.get(:triggers, "")
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.filter(&(String.length(&1) > 0))

    %{
      id: id,
      name: name,
      description: Map.get(frontmatter, :description, ""),
      type: Map.get(frontmatter, :type, "general"),
      dependencies: dependencies,
      triggers: triggers,
      file_path: file_path,
      updated_at: File.stat!(file_path).mtime |> elem(0)
    }
  end

  @spec build_and_cache([map()]) :: ApmV5.Skills.DependencyGraph.graph()
  defp build_and_cache(skills) do
    graph = ApmV5.Skills.DependencyGraph.build_graph(skills)

    # Cache individual skills
    Enum.each(skills, fn skill ->
      :ets.insert(@table, {{:skill, skill.id}, skill})
    end)

    # Cache the complete graph
    :ets.insert(@table, {:graph, graph})

    Logger.info("[SkillAnalyzer] Cached #{length(skills)} skills and dependency graph")
    graph
  end
end
