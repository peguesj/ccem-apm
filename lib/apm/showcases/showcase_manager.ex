defmodule Apm.Showcases.ShowcaseManager do
  @moduledoc """
  GenServer for managing project showcases.

  Scans ~/Developer for projects with showcase configurations and tracks:
  - Standalone showcases (project/showcase/client/index.html)
  - CCEM central showcase projects (~/Developer/ccem/showcase/)
  - Showcase metadata and configuration

  Provides project listing, showcase status, and configuration management
  for use in showcase action orchestration with UPM, Plane PM, and auth gates.
  """
  use GenServer
  require Logger

  @ccem_showcase_dir Path.expand("~/Developer/ccem/showcase")
  @developer_dir Path.expand("~/Developer")
  # 5 minutes
  @refresh_interval_ms 300_000

  # --- Client API ---

  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc "List all discovered projects with showcase status"
  @spec list_projects :: [map()]
  def list_projects do
    GenServer.call(__MODULE__, :list_projects)
  end

  @doc "Get detailed showcase info for a project"
  @spec get_project_showcase(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_project_showcase(project_name) do
    GenServer.call(__MODULE__, {:get_showcase, project_name})
  end

  @doc "Create showcase configuration for a project"
  @spec create_showcase(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def create_showcase(project_name, config \\ %{}) do
    GenServer.call(__MODULE__, {:create_showcase, project_name, config})
  end

  @doc "Scan and refresh all showcase configurations"
  @spec refresh :: :ok
  def refresh do
    GenServer.cast(__MODULE__, :refresh)
  end

  @doc "Get showcase statistics"
  @spec stats :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_opts) do
    schedule_refresh()
    {:ok, %{projects: %{}, last_refresh: nil}, {:continue, :load_projects}}
  end

  @impl true
  def handle_continue(:load_projects, state) do
    projects = scan_projects()
    new_state = %{state | projects: projects, last_refresh: DateTime.utc_now()}
    {:noreply, new_state}
  end

  @impl true
  def handle_call(:list_projects, _from, state) do
    projects =
      state.projects
      |> Enum.map(fn {_name, info} ->
        Map.take(info, [:name, :path, :type, :showcase_type, :has_standalone, :url])
      end)
      |> Enum.sort_by(& &1.name)

    {:reply, projects, state}
  end

  @impl true
  def handle_call({:get_showcase, project_name}, _from, state) do
    case Map.get(state.projects, project_name) do
      nil -> {:reply, {:error, :not_found}, state}
      info -> {:reply, {:ok, info}, state}
    end
  end

  @impl true
  def handle_call({:create_showcase, project_name, config}, _from, state) do
    case Map.get(state.projects, project_name) do
      nil ->
        {:reply, {:error, :project_not_found}, state}

      project_info ->
        result = do_create_showcase(project_info, config)
        {:reply, result, state}
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      total_projects: map_size(state.projects),
      with_standalone: state.projects |> Enum.count(fn {_, p} -> p.has_standalone end),
      with_central: state.projects |> Enum.count(fn {_, p} -> p.showcase_type == "central" end),
      unconfigured: state.projects |> Enum.count(fn {_, p} -> p.showcase_type == "none" end),
      last_refresh: state.last_refresh
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_cast(:refresh, state) do
    projects = scan_projects()
    new_state = %{state | projects: projects, last_refresh: DateTime.utc_now()}
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:refresh_timeout, state) do
    schedule_refresh()
    projects = scan_projects()
    new_state = %{state | projects: projects, last_refresh: DateTime.utc_now()}
    {:noreply, new_state}
  end

  # --- Private functions ---

  defp schedule_refresh do
    Process.send_after(self(), :refresh_timeout, @refresh_interval_ms)
  end

  @spec scan_projects :: map()
  defp scan_projects do
    projects = %{}

    # Scan ~/Developer for projects
    projects = scan_developer_projects(projects)

    # Scan CCEM central showcase for registered projects
    projects = scan_ccem_showcase_projects(projects)

    projects
  end

  defp scan_developer_projects(projects) do
    case File.ls(@developer_dir) do
      {:ok, entries} ->
        Enum.reduce(entries, projects, fn entry, acc ->
          project_path = Path.join(@developer_dir, entry)

          case File.dir?(project_path) do
            false ->
              acc

            true ->
              project_name = entry
              project_info = analyze_project(project_name, project_path)

              Map.put(acc, project_name, project_info)
          end
        end)

      {:error, _} ->
        projects
    end
  end

  defp scan_ccem_showcase_projects(projects) do
    case File.ls(@ccem_showcase_dir) do
      {:ok, entries} ->
        Enum.reduce(entries, projects, fn entry, acc ->
          # Skip files and special directories
          if should_skip_ccem_entry?(entry) do
            acc
          else
            project_name = entry
            showcase_path = Path.join(@ccem_showcase_dir, entry)

            case File.dir?(showcase_path) do
              false ->
                acc

              true ->
                Map.update(acc, project_name, %{}, fn info ->
                  Map.merge(info, %{
                    showcase_type: "central",
                    central_path: showcase_path
                  })
                end)
            end
          end
        end)

      {:error, _} ->
        projects
    end
  end

  defp should_skip_ccem_entry?(entry) do
    Enum.any?(
      [
        "client",
        "data",
        "diagrams",
        ".git",
        "SKILL.md"
      ],
      &(entry == &1)
    ) ||
      String.starts_with?(entry, ".") ||
      String.ends_with?(entry, ".md") ||
      String.ends_with?(entry, ".json") ||
      String.ends_with?(entry, ".html") ||
      String.ends_with?(entry, ".sh")
  end

  defp analyze_project(name, path) do
    # Check for standalone showcase
    standalone_path = Path.join([path, "showcase", "client", "index.html"])
    has_standalone = File.exists?(standalone_path)

    # Determine showcase type
    showcase_type = if has_standalone, do: "standalone", else: "none"

    # Get project info if available
    claude_md = Path.join([path, ".claude", "CLAUDE.md"])
    has_claude_md = File.exists?(claude_md)

    # Build project info map
    %{
      name: name,
      path: path,
      type: get_project_type(path),
      showcase_type: showcase_type,
      has_standalone: has_standalone,
      has_claude_md: has_claude_md,
      url:
        if(has_standalone,
          do: "http://localhost:3001/client/index.html?project=#{name}",
          else: nil
        ),
      created_at: File.stat!(path) |> then(& &1.ctime)
    }
  end

  defp get_project_type(path) do
    cond do
      File.exists?(Path.join([path, "package.json"])) -> "node"
      File.exists?(Path.join([path, "mix.exs"])) -> "elixir"
      File.exists?(Path.join([path, "Cargo.toml"])) -> "rust"
      File.exists?(Path.join([path, "go.mod"])) -> "go"
      File.exists?(Path.join([path, "setup.py"])) -> "python"
      true -> "unknown"
    end
  end

  defp do_create_showcase(project_info, config) do
    project_name = project_info.name

    case project_info.showcase_type do
      "standalone" ->
        {:ok,
         %{
           message: "Project already has standalone showcase",
           project: project_name,
           url: project_info.url,
           type: "standalone"
         }}

      "central" ->
        {:ok,
         %{
           message: "Project already configured in CCEM central showcase",
           project: project_name,
           path: project_info.central_path,
           type: "central"
         }}

      "none" ->
        # Register in CCEM central showcase
        central_project_dir = Path.join(@ccem_showcase_dir, project_name)

        case create_central_showcase_entry(central_project_dir, project_info, config) do
          :ok ->
            {:ok,
             %{
               message: "Created central showcase entry",
               project: project_name,
               path: central_project_dir,
               type: "central",
               config: config
             }}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp create_central_showcase_entry(central_dir, project_info, _config) do
    case File.mkdir(central_dir) do
      :ok ->
        # Create basic showcase metadata file
        metadata = %{
          project_name: project_info.name,
          project_path: project_info.path,
          project_type: project_info.type,
          created_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          source: "apm_showcase_action"
        }

        metadata_path = Path.join(central_dir, "showcase.json")

        case File.write(metadata_path, Jason.encode!(metadata, pretty: true)) do
          :ok -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, :eexist} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end
end
