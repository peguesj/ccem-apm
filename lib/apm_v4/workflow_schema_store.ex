defmodule ApmV4.WorkflowSchemaStore do
  @moduledoc """
  ETS-backed GenServer for tracking active workflow executions.

  A workflow represents a running skill (upm, ralph, ship, deploy:agents-v2)
  across its lifecycle phases: plan → build → verify → ship.

  WorkflowRegistry provides static workflow *definitions* (steps, edges, icons).
  WorkflowSchemaStore provides *runtime state* for active workflow executions.
  """

  use GenServer
  require Logger

  @table :workflow_schemas

  @valid_skills ~w(ship upm ralph deploy:agents-v2)
  @valid_phases ~w(plan build verify ship)

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Register a new active workflow execution.
  Required fields: workflow_id, skill.
  Optional: phase (default "plan"), formation_id, branch, stories.
  Returns {:ok, workflow} | {:error, reason}.
  """
  @spec register_workflow(map()) :: {:ok, map()} | {:error, String.t()}
  def register_workflow(attrs) when is_map(attrs) do
    GenServer.call(__MODULE__, {:register_workflow, attrs})
  end

  @doc "Get a workflow by ID. Returns {:ok, workflow} | {:error, :not_found}."
  @spec get_workflow(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_workflow(workflow_id) do
    case :ets.lookup(@table, workflow_id) do
      [{^workflow_id, wf}] -> {:ok, wf}
      [] -> {:error, :not_found}
    end
  end

  @doc "List all workflows, most recently started first."
  @spec list_workflows() :: [map()]
  def list_workflows do
    :ets.tab2list(@table)
    |> Enum.map(fn {_id, wf} -> wf end)
    |> Enum.sort_by(& &1.started_at, {:desc, DateTime})
  end

  @doc """
  Transition the workflow to a new phase.
  Returns {:ok, workflow} | {:error, :not_found} | {:error, :invalid_phase}.
  """
  @spec update_phase(String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def update_phase(workflow_id, new_phase) do
    if new_phase in @valid_phases do
      GenServer.call(__MODULE__, {:update_phase, workflow_id, new_phase})
    else
      {:error, :invalid_phase}
    end
  end

  @doc """
  Partial update for mutable fields: branch, pr_url, commit_sha, stories, formation_id.
  Returns {:ok, workflow} | {:error, :not_found}.
  """
  @spec update_workflow(String.t(), map()) :: {:ok, map()} | {:error, atom()}
  def update_workflow(workflow_id, attrs) when is_map(attrs) do
    GenServer.call(__MODULE__, {:update_workflow, workflow_id, attrs})
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    Logger.info("[WorkflowSchemaStore] initialised — ETS table :workflow_schemas ready")
    {:ok, %{}}
  end

  @impl true
  def handle_call({:register_workflow, attrs}, _from, s) do
    case validate_required(attrs) do
      :ok ->
        now = DateTime.utc_now()

        wf = %{
          workflow_id: get_key(attrs, :workflow_id, "workflow_id"),
          skill: get_key(attrs, :skill, "skill"),
          phase: get_key(attrs, :phase, "phase") || "plan",
          stories: get_key(attrs, :stories, "stories") || [],
          formation_id: get_key(attrs, :formation_id, "formation_id"),
          branch: get_key(attrs, :branch, "branch"),
          pr_url: get_key(attrs, :pr_url, "pr_url"),
          commit_sha: get_key(attrs, :commit_sha, "commit_sha"),
          started_at: now,
          updated_at: now,
          phase_history: []
        }

        :ets.insert(@table, {wf.workflow_id, wf})
        Logger.info("[WorkflowSchemaStore] registered workflow #{wf.workflow_id} (skill: #{wf.skill})")

        # Broadcast to LiveView subscribers
        Phoenix.PubSub.broadcast(ApmV4.PubSub, "apm:workflows", {:workflow_registered, wf})

        {:reply, {:ok, wf}, s}

      {:error, reason} ->
        {:reply, {:error, reason}, s}
    end
  end

  @impl true
  def handle_call({:update_phase, workflow_id, new_phase}, _from, s) do
    case :ets.lookup(@table, workflow_id) do
      [{^workflow_id, wf}] ->
        now = DateTime.utc_now()
        history_entry = %{phase: wf.phase, left_at: now}

        updated =
          wf
          |> Map.put(:phase, new_phase)
          |> Map.put(:updated_at, now)
          |> Map.update(:phase_history, [history_entry], &(&1 ++ [history_entry]))

        :ets.insert(@table, {workflow_id, updated})
        Phoenix.PubSub.broadcast(ApmV4.PubSub, "apm:workflows", {:workflow_phase_changed, updated})
        {:reply, {:ok, updated}, s}

      [] ->
        {:reply, {:error, :not_found}, s}
    end
  end

  @impl true
  def handle_call({:update_workflow, workflow_id, attrs}, _from, s) do
    case :ets.lookup(@table, workflow_id) do
      [{^workflow_id, wf}] ->
        allowed = [:branch, :pr_url, :commit_sha, :stories, :formation_id]

        patch =
          Enum.reduce(allowed, %{}, fn key, acc ->
            str = Atom.to_string(key)
            cond do
              Map.has_key?(attrs, key) -> Map.put(acc, key, attrs[key])
              Map.has_key?(attrs, str) -> Map.put(acc, key, attrs[str])
              true -> acc
            end
          end)

        updated =
          wf
          |> Map.merge(patch)
          |> Map.put(:updated_at, DateTime.utc_now())

        :ets.insert(@table, {workflow_id, updated})
        Phoenix.PubSub.broadcast(ApmV4.PubSub, "apm:workflows", {:workflow_updated, updated})
        {:reply, {:ok, updated}, s}

      [] ->
        {:reply, {:error, :not_found}, s}
    end
  end

  # --- Private helpers ---

  defp validate_required(attrs) do
    id = get_key(attrs, :workflow_id, "workflow_id")
    skill = get_key(attrs, :skill, "skill")

    cond do
      is_nil(id) or id == "" ->
        {:error, "workflow_id is required"}

      is_nil(skill) or skill == "" ->
        {:error, "skill is required"}

      skill not in @valid_skills ->
        {:error, "skill must be one of: #{Enum.join(@valid_skills, ", ")}"}

      true ->
        :ok
    end
  end

  defp get_key(map, atom_key, string_key) do
    Map.get(map, atom_key) || Map.get(map, string_key)
  end
end
