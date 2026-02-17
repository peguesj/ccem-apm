defmodule ApmV4.ConfigLoader do
  @moduledoc """
  GenServer that reads ~/Developer/ccem/apm/apm_config.json on startup
  and on /api/config/reload. Exposes project config to all other modules.
  """

  use GenServer

  @default_config_path Path.expand("~/Developer/ccem/apm/apm_config.json")

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the full config map."
  @spec get_config() :: map()
  def get_config do
    GenServer.call(__MODULE__, :get_config)
  end

  @doc "Returns a project by name, or nil if not found."
  @spec get_project(String.t()) :: map() | nil
  def get_project(name) do
    GenServer.call(__MODULE__, {:get_project, name})
  end

  @doc "Returns the active project config, or nil if none set."
  @spec get_active_project() :: map() | nil
  def get_active_project do
    GenServer.call(__MODULE__, :get_active_project)
  end

  @doc "Re-reads config from disk. Broadcasts change via PubSub."
  @spec reload() :: :ok
  def reload do
    GenServer.call(__MODULE__, :reload)
  end

  @doc "Returns the config file path."
  def config_path do
    Application.get_env(:apm_v4, :config_path, @default_config_path)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :config_path, config_path())
    config = load_config(path)
    # Defer session sync until after AgentRegistry is started (via send_after)
    Process.send_after(self(), :sync_sessions, 500)
    {:ok, %{config: config, config_path: path}}
  end

  @impl true
  def handle_info(:sync_sessions, state) do
    sync_sessions_to_registry(state.config)
    {:noreply, state}
  end

  @impl true
  def handle_call(:get_config, _from, state) do
    {:reply, state.config, state}
  end

  def handle_call({:get_project, name}, _from, state) do
    project =
      state.config
      |> Map.get("projects", [])
      |> Enum.find(fn p -> p["name"] == name end)

    {:reply, project, state}
  end

  def handle_call(:get_active_project, _from, state) do
    active_name = Map.get(state.config, "active_project")

    project =
      if active_name do
        state.config
        |> Map.get("projects", [])
        |> Enum.find(fn p -> p["name"] == active_name end)
      end

    {:reply, project, state}
  end

  def handle_call(:reload, _from, state) do
    config = load_config(state.config_path)

    # Sync sessions from config into AgentRegistry so dashboard shows live counts
    sync_sessions_to_registry(config)

    Phoenix.PubSub.broadcast(ApmV4.PubSub, "apm:config", {:config_reloaded, config})

    {:reply, :ok, %{state | config: config}}
  end

  # --- Private ---

  defp load_config(path) do
    case File.read(path) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, config} -> config
          {:error, _} -> default_config()
        end

      {:error, _} ->
        default_config()
    end
  end

  defp default_config do
    %{
      "version" => "4.0.0",
      "port" => 3031,
      "active_project" => nil,
      "projects" => []
    }
  end

  # Sync all sessions from config into AgentRegistry so the dashboard
  # shows accurate session counts without requiring manual backfill.
  defp sync_sessions_to_registry(config) do
    projects = Map.get(config, "projects", [])

    Enum.each(projects, fn project ->
      project_name = project["name"]
      sessions = Map.get(project, "sessions", [])

      Enum.each(sessions, fn session ->
        session_id = session["session_id"]
        short_id = String.slice(session_id, 0, 8)
        status = if session["status"] == "active", do: "active", else: "idle"

        try do
          ApmV4.AgentRegistry.register_agent(
            session_id,
            %{
              name: "#{project_name}:#{short_id}",
              tier: 0,
              status: status,
              deps: [],
              metadata: %{
                "type" => "session",
                "project" => project_name,
                "session_jsonl" => session["session_jsonl"] || "",
                "start_time" => session["start_time"] || ""
              }
            },
            project_name
          )
        catch
          :exit, _ -> :skip
        end
      end)
    end)
  end
end
