defmodule Apm.ShowcaseDataStore do
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
  @ccem_project_names ["ccem", "CCEM APM", "apm-v4", "apm"]

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

  @doc "Returns diagram metadata for a project (mmd/puml/svg files discovered on disk)."
  @spec get_diagrams(String.t() | nil) :: [map()]
  def get_diagrams(project_name) do
    data = get_showcase_data(project_name)
    Map.get(data, "diagrams", [])
  end

  @doc "Returns queryable tab definitions for a project."
  @spec get_tabs(String.t() | nil) :: [map()]
  def get_tabs(project_name) do
    data = get_showcase_data(project_name)
    Map.get(data, "tabs", [])
  end

  @doc "Returns tab data for a specific tab, with optional query filtering."
  @spec get_tab_data(String.t() | nil, String.t(), map()) :: map()
  def get_tab_data(project_name, tab_id, query \\ %{}) do
    data = get_showcase_data(project_name)
    tabs = Map.get(data, "tabs", [])

    case Enum.find(tabs, fn t -> t["id"] == tab_id end) do
      nil ->
        %{"error" => "tab_not_found", "tab_id" => tab_id}

      tab ->
        raw_data = tab["data"] || %{}
        filter_tab_data(raw_data, query)
    end
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

    # Defer disk I/O so init returns immediately (APM-001 fix)
    send(self(), :load_initial)

    {:ok, %{table: table}}
  end

  @impl true
  def handle_info(:load_initial, state) do
    # Pre-load default CCEM showcase data
    data = load_showcase_data(@default_showcase_path)
    :ets.insert(state.table, {"ccem", data})

    # Pre-load project-specific showcase data from showcase/data/projects/
    scan_showcase_project_dirs()
    |> Enum.each(fn %{"name" => name, "showcase_data_path" => path} ->
      project_data = load_showcase_data(path)
      :ets.insert(state.table, {name, project_data})
    end)

    {:noreply, state}
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
      Apm.PubSub,
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
    case Apm.ConfigLoader.get_project(project_name) do
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
      "diagrams" => load_diagrams(path),
      "tabs" => load_tabs(path),
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

  # --- Diagram Discovery ---

  @diagram_extensions ~w(.mmd .puml .svg)

  defp load_diagrams(path) do
    # Look in sibling diagrams/ dir (../diagrams relative to data/)
    diagrams_dir = Path.join(Path.dirname(path), "diagrams")

    # Also check project-specific diagrams inside the data dir
    project_diagrams_dir = Path.join(path, "diagrams")

    dirs =
      [diagrams_dir, project_diagrams_dir]
      |> Enum.filter(&File.dir?/1)
      |> Enum.uniq()

    Enum.flat_map(dirs, fn dir ->
      case File.ls(dir) do
        {:ok, entries} ->
          entries
          |> Enum.filter(fn f -> Path.extname(f) in @diagram_extensions end)
          |> Enum.map(fn filename ->
            full_path = Path.join(dir, filename)
            ext = Path.extname(filename)
            basename = Path.rootname(filename)

            %{
              "id" => basename,
              "filename" => filename,
              "path" => full_path,
              "type" => diagram_type(ext),
              "format" => String.trim_leading(ext, "."),
              "content" => File.read!(full_path),
              "size_bytes" => File.stat!(full_path).size
            }
          end)

        {:error, _} ->
          []
      end
    end)
  end

  defp diagram_type(".mmd"), do: "mermaid"
  defp diagram_type(".puml"), do: "plantuml"
  defp diagram_type(".svg"), do: "svg"
  defp diagram_type(_), do: "unknown"

  # --- Queryable Tabs ---

  defp load_tabs(path) do
    # Check for explicit tabs.json config
    tabs_config = load_json(Path.join(path, "tabs.json"), nil)

    if tabs_config do
      # Explicit tab definitions — enrich each with data from its source file
      Enum.map(tabs_config, fn tab ->
        source = tab["source"]
        data = if source, do: load_json(Path.join(path, source), %{}), else: %{}
        Map.put(tab, "data", data)
      end)
    else
      # Auto-discover tabs from JSON files that aren't core showcase files
      core_files = ~w(features.json narrative-content.json diagram-design-system.json
                      redaction-rules.json speaker-notes.json slides.json tabs.json
                      manifest.json status.json README.md)

      case File.ls(path) do
        {:ok, entries} ->
          entries
          |> Enum.filter(fn f -> String.ends_with?(f, ".json") end)
          |> Enum.reject(fn f -> f in core_files end)
          |> Enum.map(fn filename ->
            basename = Path.rootname(filename)
            data = load_json(Path.join(path, filename), %{})

            %{
              "id" => basename,
              "label" =>
                basename
                |> String.replace("-", " ")
                |> String.replace("_", " ")
                |> capitalize_words(),
              "source" => filename,
              "type" => infer_tab_type(data),
              "queryable" => true,
              "data" => data
            }
          end)

        {:error, _} ->
          []
      end
    end
  end

  defp infer_tab_type(data) when is_list(data), do: "list"
  defp infer_tab_type(data) when is_map(data), do: "object"
  defp infer_tab_type(_), do: "raw"

  defp capitalize_words(str) do
    str
    |> String.split(" ")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  # --- Tab Query Filtering ---

  defp filter_tab_data(data, query) when map_size(query) == 0, do: data

  defp filter_tab_data(data, query) when is_map(data) do
    search = Map.get(query, "search", "")

    if search != "" do
      search_lower = String.downcase(search)

      data
      |> Enum.filter(fn {key, value} ->
        String.contains?(String.downcase(to_string(key)), search_lower) or
          String.contains?(String.downcase(to_string(inspect(value))), search_lower)
      end)
      |> Map.new()
    else
      data
    end
  end

  defp filter_tab_data(data, query) when is_list(data) do
    search = Map.get(query, "search", "")

    if search != "" do
      search_lower = String.downcase(search)

      Enum.filter(data, fn item ->
        String.contains?(String.downcase(inspect(item)), search_lower)
      end)
    else
      data
    end
  end

  defp filter_tab_data(data, _query), do: data
end
