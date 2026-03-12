defmodule ApmV5.AgUi.GenerativeUI.Registry do
  @moduledoc """
  Stores agent-declared UI component specifications for dynamic dashboard panels.

  ## US-022 Acceptance Criteria (DoD):
  - GenServer with ETS table :ag_ui_gen_components
  - register_component/2, update_component/2, remove_component/1
  - Supported types: card, chart, table, alert, progress, badge, custom_html
  - list_components/0 and list_by_agent/1
  - Component specs validated against schema
  - mix compile --warnings-as-errors passes
  """

  use GenServer

  require Logger

  alias ApmV5.AgUi.EventBus

  @table :ag_ui_gen_components
  @valid_types ~w(card chart table alert progress badge custom_html)

  # -- Client API -------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Registers a dynamic UI component."
  @spec register_component(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def register_component(agent_id, spec) when is_map(spec) do
    GenServer.call(__MODULE__, {:register, agent_id, spec})
  end

  @doc "Updates an existing component."
  @spec update_component(String.t(), map()) :: :ok | {:error, :not_found}
  def update_component(component_id, updates) do
    GenServer.call(__MODULE__, {:update, component_id, updates})
  end

  @doc "Removes a component by ID."
  @spec remove_component(String.t()) :: :ok
  def remove_component(component_id) do
    GenServer.call(__MODULE__, {:remove, component_id})
  end

  @doc "Lists all registered components."
  @spec list_components() :: [map()]
  def list_components do
    :ets.tab2list(@table)
    |> Enum.map(fn {_id, comp} -> comp end)
    |> Enum.sort_by(& &1.registered_at)
  end

  @doc "Lists components by agent."
  @spec list_by_agent(String.t()) :: [map()]
  def list_by_agent(agent_id) do
    :ets.tab2list(@table)
    |> Enum.filter(fn {_id, comp} -> comp.agent_id == agent_id end)
    |> Enum.map(fn {_id, comp} -> comp end)
  end

  @doc "Gets a specific component by ID."
  @spec get(String.t()) :: map() | nil
  def get(component_id) do
    case :ets.lookup(@table, component_id) do
      [{^component_id, comp}] -> comp
      [] -> nil
    end
  end

  # -- GenServer Callbacks ----------------------------------------------------

  @impl true
  def init(_opts) do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    end

    {:ok, %{}}
  end

  @impl true
  def handle_call({:register, agent_id, spec}, _from, state) do
    case validate_spec(spec) do
      :ok ->
        id = generate_id()

        component = %{
          id: id,
          agent_id: agent_id,
          type: spec["type"] || spec[:type],
          props: spec["props"] || spec[:props] || %{},
          layout_hint: spec["layout_hint"] || spec[:layout_hint],
          title: spec["title"] || spec[:title],
          registered_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          updated_at: nil
        }

        :ets.insert(@table, {id, component})

        EventBus.publish("CUSTOM", %{
          name: "generative_ui_update",
          value: %{action: "register", component_id: id, agent_id: agent_id}
        })

        {:reply, {:ok, id}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:update, component_id, updates}, _from, state) do
    case :ets.lookup(@table, component_id) do
      [{^component_id, existing}] ->
        updated =
          existing
          |> Map.merge(atomize_keys(updates))
          |> Map.put(:updated_at, DateTime.utc_now() |> DateTime.to_iso8601())

        :ets.insert(@table, {component_id, updated})

        EventBus.publish("CUSTOM", %{
          name: "generative_ui_update",
          value: %{action: "update", component_id: component_id}
        })

        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:remove, component_id}, _from, state) do
    :ets.delete(@table, component_id)

    EventBus.publish("CUSTOM", %{
      name: "generative_ui_update",
      value: %{action: "remove", component_id: component_id}
    })

    {:reply, :ok, state}
  end

  # -- Private ----------------------------------------------------------------

  defp validate_spec(spec) do
    type = spec["type"] || spec[:type]

    cond do
      is_nil(type) -> {:error, "type is required"}
      type not in @valid_types -> {:error, "invalid type: #{type}. Must be one of #{inspect(@valid_types)}"}
      not is_map(spec["props"] || spec[:props] || %{}) -> {:error, "props must be a map"}
      true -> :ok
    end
  end

  defp generate_id do
    "gui-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp atomize_keys(map) when is_map(map) do
    Enum.into(map, %{}, fn
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
      {k, v} -> {k, v}
    end)
  rescue
    _ -> map
  end
end
