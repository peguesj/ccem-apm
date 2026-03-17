defmodule ApmV5.ShowcaseDataStore do
  @moduledoc """
  GenServer that loads per-project showcase data from disk.
  Provides feature lists, narratives, design system, and redaction rules
  for the Showcase LiveView. ETS-cached, per-project keyed.
  """

  use GenServer

  @default_showcase_path Path.expand("~/Developer/ccem/showcase/data")
  @ccem_project_names ["ccem", "CCEM APM", "apm-v4"]

  # --- Client API ---

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
  Returns true if the given project map has a usable showcase.
  Checks (in order):
    1. project has `showcase_data_path` pointing to an existing directory
    2. project has `project_root` and `project_root/showcase/data/` exists
    3. project name is in the CCEM project list — uses default CCEM path
    4. ~/Developer/{name}/showcase/data/ exists by convention
  """
  @spec has_showcase?(map()) :: boolean()
  def has_showcase?(%{"showcase_data_path" => path}) when is_binary(path) and path != "" do
    File.dir?(Path.expand(path))
  end

  def has_showcase?(%{"project_root" => root}) when is_binary(root) and root != "" do
    expanded = Path.expand(root)
    File.dir?(Path.join(expanded, "showcase/data"))
  end

  def has_showcase?(%{"name" => name}) when name in @ccem_project_names do
    File.dir?(@default_showcase_path)
  end

  def has_showcase?(%{"name" => name}) when is_binary(name) and name != "" do
    File.dir?(Path.expand("~/Developer/#{name}/showcase/data"))
  end

  def has_showcase?(_), do: false

  @doc """
  Filters a list of project maps to only those that have showcase data.
  Only includes projects with their OWN showcase data directory.
  """
  @spec filter_showcase_projects(list()) :: list()
  def filter_showcase_projects(projects) when is_list(projects) do
    Enum.filter(projects, &has_showcase?/1)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    table = :ets.new(:showcase_data, [:set, :protected, read_concurrency: true])
    # Pre-load default CCEM showcase data
    data = load_showcase_data(@default_showcase_path)
    :ets.insert(table, {"ccem", data})
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

  # --- Private ---

  defp resolve_showcase_path(project_name) when project_name in @ccem_project_names do
    @default_showcase_path
  end

  defp resolve_showcase_path(project_name) do
    # Check if the project config specifies a showcase_data_path
    case ApmV5.ConfigLoader.get_project(project_name) do
      %{"showcase_data_path" => path} when is_binary(path) and path != "" ->
        expanded = Path.expand(path)
        if File.dir?(expanded), do: expanded, else: nil

      %{"project_root" => root} when is_binary(root) and root != "" ->
        candidate = Path.join(Path.expand(root), "showcase/data")
        if File.dir?(candidate), do: candidate, else: nil

      _ ->
        # Convention-based: ~/Developer/{project_name}/showcase/data
        conventional = Path.expand("~/Developer/#{project_name}/showcase/data")
        if File.dir?(conventional), do: conventional, else: nil
    end
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
      "version" => "5.5.0",
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
