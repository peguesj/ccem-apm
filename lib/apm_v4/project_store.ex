defmodule ApmV4.ProjectStore do
  @moduledoc """
  ETS-backed storage for per-project data: tasks, commands, plane context,
  and input requests. Matches v3's PROJECTS_DATA structure.
  """

  use GenServer

  @tasks_table :apm_tasks
  @commands_table :apm_commands
  @plane_table :apm_plane
  @input_table :apm_input_requests

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Replace a project's task list."
  @spec sync_tasks(String.t(), list()) :: :ok
  def sync_tasks(project_name, tasks) do
    :ets.insert(@tasks_table, {project_name, tasks})
    Phoenix.PubSub.broadcast(ApmV4.PubSub, "apm:tasks", {:tasks_synced, project_name, tasks})
    :ok
  end

  @doc "Get tasks for a project."
  @spec get_tasks(String.t()) :: list()
  def get_tasks(project_name) do
    case :ets.lookup(@tasks_table, project_name) do
      [{^project_name, tasks}] -> tasks
      [] -> []
    end
  end

  @doc "Register commands for a project."
  @spec register_commands(String.t(), list()) :: :ok
  def register_commands(project_name, commands) do
    existing = get_commands(project_name)
    merged = merge_commands(existing, commands)
    :ets.insert(@commands_table, {project_name, merged})
    Phoenix.PubSub.broadcast(ApmV4.PubSub, "apm:commands", {:commands_updated, project_name})
    :ok
  end

  @doc "Get commands for a project."
  @spec get_commands(String.t()) :: list()
  def get_commands(project_name) do
    case :ets.lookup(@commands_table, project_name) do
      [{^project_name, commands}] -> commands
      [] -> []
    end
  end

  @doc "Update Plane PM context for a project."
  @spec update_plane(String.t(), map()) :: :ok
  def update_plane(project_name, plane_data) do
    :ets.insert(@plane_table, {project_name, plane_data})
    Phoenix.PubSub.broadcast(ApmV4.PubSub, "apm:plane", {:plane_updated, project_name})
    :ok
  end

  @doc "Get Plane PM context for a project."
  @spec get_plane(String.t()) :: map()
  def get_plane(project_name) do
    case :ets.lookup(@plane_table, project_name) do
      [{^project_name, plane}] -> plane
      [] -> %{}
    end
  end

  @doc "Add an input request to the global queue."
  @spec add_input_request(map()) :: integer()
  def add_input_request(request) do
    GenServer.call(__MODULE__, {:add_input_request, request})
  end

  @doc "Respond to an input request by ID."
  @spec respond_to_input(integer(), String.t()) :: :ok | {:error, :not_found}
  def respond_to_input(id, choice) do
    GenServer.call(__MODULE__, {:respond_to_input, id, choice})
  end

  @doc "Get all unresponded input requests."
  @spec get_pending_inputs() :: list()
  def get_pending_inputs do
    :ets.tab2list(@input_table)
    |> Enum.map(fn {_id, req} -> req end)
    |> Enum.filter(fn req -> !req.responded end)
    |> Enum.sort_by(& &1.id)
  end

  @doc "Clear all data (for testing)."
  @spec clear_all() :: :ok
  def clear_all do
    GenServer.call(__MODULE__, :clear_all)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    :ets.new(@tasks_table, [:named_table, :set, :public, read_concurrency: true])
    :ets.new(@commands_table, [:named_table, :set, :public, read_concurrency: true])
    :ets.new(@plane_table, [:named_table, :set, :public, read_concurrency: true])
    :ets.new(@input_table, [:named_table, :set, :public, read_concurrency: true])

    {:ok, %{input_counter: 0}}
  end

  @impl true
  def handle_call({:add_input_request, request}, _from, state) do
    counter = state.input_counter + 1
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    input = %{
      id: counter,
      prompt: Map.get(request, "prompt", Map.get(request, :prompt, "")),
      options: Map.get(request, "options", Map.get(request, :options, [])),
      context: Map.get(request, "context", Map.get(request, :context, %{})),
      responded: false,
      response: nil,
      timestamp: now
    }

    :ets.insert(@input_table, {counter, input})
    Phoenix.PubSub.broadcast(ApmV4.PubSub, "apm:input", {:input_requested, input})

    {:reply, counter, %{state | input_counter: counter}}
  end

  def handle_call({:respond_to_input, id, choice}, _from, state) do
    case :ets.lookup(@input_table, id) do
      [{^id, input}] ->
        updated = %{input | responded: true, response: choice}
        :ets.insert(@input_table, {id, updated})
        Phoenix.PubSub.broadcast(ApmV4.PubSub, "apm:input", {:input_responded, updated})
        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:clear_all, _from, state) do
    :ets.delete_all_objects(@tasks_table)
    :ets.delete_all_objects(@commands_table)
    :ets.delete_all_objects(@plane_table)
    :ets.delete_all_objects(@input_table)
    {:reply, :ok, %{state | input_counter: 0}}
  end

  # --- Private ---

  defp merge_commands(existing, new) when is_list(new) do
    new_names = MapSet.new(Enum.map(new, fn c -> c["name"] || c[:name] end))

    kept =
      Enum.reject(existing, fn c ->
        name = c["name"] || c[:name]
        MapSet.member?(new_names, name)
      end)

    kept ++ new
  end

  defp merge_commands(_existing, _new), do: []
end
