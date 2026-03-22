defmodule ApmV5.ShowcaseDataStore do
  # Author: Jeremiah Pegues <jeremiah@pegues.io>
  @moduledoc """
  GenServer that loads per-project showcase data from disk.
  Provides feature lists, narratives, design system, and redaction rules
  for the Showcase LiveView. ETS-cached, per-project keyed.

  Supports multi-project showcases:
  - Projects registered in apm_config.json with `root` or `showcase_data_path`
  - Projects with data in `showcase/data/projects/{name}/` subdirectories
  - Convention-based discovery at `~/Developer/{name}/showcase/data/`
  """

  use GenServer

  require Logger

  @default_showcase_path Path.expand("~/Developer/ccem/showcase/data")
  @ccem_project_names ["ccem", "CCEM APM", "apm-v4"]

  # --- Client API ---

  @doc "Start the ShowcaseDataStore GenServer."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns showcase data for a project. Returns empty state when no showcase data found."
  @spec get_showcase_data(String.t() | nil) :: map()
  def get_showcase_data(project_name) do
    GenServer.call(__MODULE__, {:get_data, project_name || "ccem"})
  end

  @doc "Reloads showcase data for a project from disk."
  @spec reload(String.t() | nil) :: :ok
  def reload(project_name \\ nil) do
    GenServer.call(__MODULE__, {:reload, project_name || "ccem"})
  end

  @doc "Returns the list of features for a project."
  @spec get_features(String.t() | nil) :: list()
  def get_features(project_name) do
    data = get_showcase_data(project_name)
    Map.get(data, "features", [])
  end

  @doc """
  Returns a list of all discovered showcase project names.
  Combines projects from:
  1. showcase/data/projects/ subdirectories
  2. APM config projects with showcase data
  3. The default CCEM showcase
  """
  @spec list_showcase_projects() :: [map()]
  def list_showcase_projects do
    GenServer.call(__MODULE__, :list_showcase_projects)
  end

  @doc """
  Returns true if the given project map has a usable showcase.
  Checks (in order):
    1. project has `showcase_data_path` pointing to an existing directory
    2. project has `root` or `project_root` and that dir/showcase/data/ exists
    3. project name is in the CCEM project list -- uses default CCEM path
    4. project name matches a subdirectory in showcase/data/projects/
    5. ~/Developer/{name}/showcase/data/ exists by convention
  """
  @spec has_showcase?(map()) :: boolean()
  def has_showcase?(%{"showcase_data_path" => path}) when is_binary(path) and path != "" do
    File.dir?(Path.expand(path))
  end

  def has_showcase?(%{"project_root" => root}) when is_binary(root) and root != "" do
    expanded = Path.expand(root)
    File.dir?(Path.join(expanded, "showcase/data"))
  end

  def has_showcase?(%{"root" => root}) when is_binary(root) and root != "" do
    expanded = Path.expand(root)
    File.dir?(Path.join(expanded, "showcase/data"))
  end

  def has_showcase?(%{"name" => name}) when name in @ccem_project_names do
    File.dir?(@default_showcase_path)
  end

  def has_showcase?(%{"name" => name}) when is_binary(name) and name != "" do
    # Check showcase/data/projects/{name}/ subdirectory first
    project_subdir = Path.join(@default_showcase_path, "projects/#{name}")

    if File.dir?(project_subdir) do
      true
    else
      File.dir?(Path.expand("~/Developer/#{name}/showcase/data"))
    end
  end

  def has_showcase?(_), do: false

  @doc """
  Filters a list of project maps to only those that have showcase data.
  Only includes projects with their OWN showcase data directory.
  If no projects have showcase data, returns all projects as graceful degradation
  to avoid empty UI states.
  """
  @spec filter_showcase_projects(list()) :: list()
  def filter_showcase_projects(projects) when is_list(projects) do
    # Merge in any discovered projects from showcase/data/projects/ that
    # aren't already in the project list
    known_names = MapSet.new(projects, fn p -> p["name"] end)

    discovered =
      scan_showcase_project_dirs()
      |> Enum.reject(fn %{"name" => name} -> MapSet.member?(known_names, name) end)

    all_candidates = projects ++ discovered

    case Enum.filter(all_candidates, &has_showcase?/1) do
      [] -> projects
      filtered -> filtered
    end
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    table = :ets.new(:showcase_data, [:set, :protected, read_concurrency: true])
    # Pre-load default CCEM showcase data
    data = load_showcase_data(@default_showcase_path)
    :ets.insert(table, {"ccem", data})

    # Pre-load project-specific showcase data from showcase/data/projects/
    scan_showcase_project_dirs()
    |> Enum.each(fn %{"name" => name, "showcase_data_path" => path} ->
      project_data = load_showcase_data(path)
      :ets.insert(table, {name, project_data})
    end)

    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:get_data, project_name}, _from, state) do
    data =
      case :ets.lookup(state.table, project_name) do
        [{^project_name, cached}] ->
          cached

        [] ->
          # Try to find project-specific showcase data
          showcase_path = resolve_showcase_path(project_name)
          loaded = load_showcase_data(showcase_path)
          :ets.insert(state.table, {project_name, loaded})
          loaded
      end

    {:reply, data, state}
  end

  def handle_call({:reload, project_name}, _from, state) do
    showcase_path =
      if project_name in @ccem_project_names,
        do: @default_showcase_path,
        else: resolve_showcase_path(project_name)

    data = load_showcase_data(showcase_path)
    :ets.insert(state.table, {project_name, data})

    Phoenix.PubSub.broadcast(
      ApmV5.PubSub,
      "apm:showcase",
      {:showcase_data_reloaded, project_name, data}
    )

    {:reply, :ok, state}
  end

  def handle_call(:list_showcase_projects, _from, state) do
    # Collect from ETS cache + discovered subdirs + config projects
    cached_names =
      :ets.tab2list(state.table)
      |> Enum.map(fn {name, data} ->
        features = Map.get(data, "features", [])
        %{"name" => name, "feature_count" => length(features), "has_data" => length(features) > 0}
      end)
      |> Enum.filter(fn %{"has_data" => has} -> has end)

    {:reply, cached_names, state}
  end

  # --- Private ---

  @doc false
  @spec scan_showcase_project_dirs() :: [map()]
  def scan_showcase_project_dirs do
    projects_dir = Path.join(@default_showcase_path, "projects")

    case File.ls(projects_dir) do
      {:ok, entries} ->
        entries
        |> Enum.map(fn entry -> {entry, Path.join(projects_dir, entry)} end)
        |> Enum.filter(fn {_name, path} -> File.dir?(path) end)
        |> Enum.filter(fn {_name, path} ->
          # Must have at least a features.json to be a valid showcase project
          File.exists?(Path.join(path, "features.json"))
        end)
        |> Enum.map(fn {name, path} ->
          %{
            "name" => name,
            "showcase_data_path" => path,
            "source" => "showcase_subdir"
          }
        end)

      {:error, _} ->
        []
    end
  end

  defp resolve_showcase_path(project_name) when project_name in @ccem_project_names do
    @default_showcase_path
  end

  defp resolve_showcase_path(project_name) do
    # 1. Check showcase/data/projects/{name}/ subdirectory
    project_subdir = Path.join(@default_showcase_path, "projects/#{project_name}")

    if File.dir?(project_subdir) and File.exists?(Path.join(project_subdir, "features.json")) do
      project_subdir
    else
      # 2. Check APM config for showcase_data_path or root
      resolve_from_config(project_name)
    end
  end

  defp resolve_from_config(project_name) do
    case ApmV5.ConfigLoader.get_project(project_name) do
      %{"showcase_data_path" => path} when is_binary(path) and path != "" ->
        expanded = Path.expand(path)
        if File.dir?(expanded), do: expanded, else: resolve_from_root(project_name, nil)

      %{"project_root" => root} when is_binary(root) and root != "" ->
        resolve_from_root(project_name, root)

      %{"root" => root} when is_binary(root) and root != "" ->
        resolve_from_root(project_name, root)

      _ ->
        resolve_from_convention(project_name)
    end
  end

  defp resolve_from_root(_project_name, nil), do: nil

  defp resolve_from_root(project_name, root) do
    candidate = Path.join(Path.expand(root), "showcase/data")
    if File.dir?(candidate), do: candidate, else: resolve_from_convention(project_name)
  end

  defp resolve_from_convention(project_name) do
    conventional = Path.expand("~/Developer/#{project_name}/showcase/data")
    if File.dir?(conventional), do: conventional, else: nil
  end

  defp load_showcase_data(nil) do
    %{
      "features" => [],
      "narratives" => %{},
      "design_system" => %{},
      "redaction_rules" => %{},
      "speaker_notes" => %{},
      "slides" => %{},
      "version" => nil,
      "path" => nil
    }
  end

  defp load_showcase_data(path) do
    %{
      "features" => load_json(Path.join(path, "features.json"), []),
      "narratives" => load_json(Path.join(path, "narrative-content.json"), %{}),
      "design_system" => load_json(Path.join(path, "diagram-design-system.json"), %{}),
      "redaction_rules" => load_json(Path.join(path, "redaction-rules.json"), %{}),
      "speaker_notes" => load_json(Path.join(path, "speaker-notes.json"), %{}),
      "slides" => load_json(Path.join(path, "slides.json"), %{}),
      "version" => "7.0.0",
      "path" => path
    }
  end

  defp load_json(file_path, default) do
    case File.read(file_path) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, data} -> data
          {:error, _} -> default
        end

      {:error, _} ->
        default
    end
  end

end
