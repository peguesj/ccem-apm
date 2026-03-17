defmodule ApmV5.DashboardStore do
  @moduledoc """
  GenServer for persisting dashboard state (layouts, filter presets, custom views,
  layout history) to JSON files with ETS caching for reads.

  Storage directory: ~/.claude/ccem/apm/dashboard/
  All writes are atomic (write .tmp then rename) to prevent corruption.
  """

  use GenServer

  @storage_dir Path.expand("~/.claude/ccem/apm/dashboard")
  @max_history 20

  @files %{
    layouts: "layouts.json",
    filter_presets: "filter_presets.json",
    custom_views: "custom_views.json",
    layout_history: "layout_history.json"
  }

  # --- Public API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  # Layouts

  @spec save_layout(String.t(), list()) :: {:ok, map()}
  def save_layout(name, panels) do
    GenServer.call(__MODULE__, {:save_layout, name, panels})
  end

  @spec load_layout(String.t()) :: map() | nil
  def load_layout(id) do
    GenServer.call(__MODULE__, {:load_layout, id})
  end

  @spec list_layouts() :: [map()]
  def list_layouts do
    GenServer.call(__MODULE__, :list_layouts)
  end

  @spec delete_layout(String.t()) :: :ok
  def delete_layout(id) do
    GenServer.call(__MODULE__, {:delete_layout, id})
  end

  # Filter Presets

  @spec save_preset(String.t(), map()) :: {:ok, map()}
  def save_preset(name, filters) do
    GenServer.call(__MODULE__, {:save_preset, name, filters})
  end

  @spec load_preset(String.t()) :: map() | nil
  def load_preset(id) do
    GenServer.call(__MODULE__, {:load_preset, id})
  end

  @spec list_presets() :: [map()]
  def list_presets do
    GenServer.call(__MODULE__, :list_presets)
  end

  @spec delete_preset(String.t()) :: :ok
  def delete_preset(id) do
    GenServer.call(__MODULE__, {:delete_preset, id})
  end

  # Custom Views

  @spec save_view(String.t(), map()) :: {:ok, map()}
  def save_view(name, config) do
    GenServer.call(__MODULE__, {:save_view, name, config})
  end

  @spec load_view(String.t()) :: map() | nil
  def load_view(id) do
    GenServer.call(__MODULE__, {:load_view, id})
  end

  @spec list_views() :: [map()]
  def list_views do
    GenServer.call(__MODULE__, :list_views)
  end

  @spec delete_view(String.t()) :: :ok
  def delete_view(id) do
    GenServer.call(__MODULE__, {:delete_view, id})
  end

  # Layout History

  @spec push_history(String.t(), list()) :: :ok
  def push_history(layout_id, panels) do
    GenServer.call(__MODULE__, {:push_history, layout_id, panels})
  end

  @spec undo_layout(String.t()) :: {:ok, list()} | :empty
  def undo_layout(layout_id) do
    GenServer.call(__MODULE__, {:undo_layout, layout_id})
  end

  # Reload from disk

  @spec reload() :: :ok
  def reload do
    GenServer.call(__MODULE__, :reload)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    storage_dir = Keyword.get(opts, :storage_dir, @storage_dir)
    table = :ets.new(:dashboard_store, [:set, :private])
    state = %{storage_dir: storage_dir, table: table}
    {:ok, state, {:continue, :init_storage}}
  end

  @impl true
  def handle_continue(:init_storage, state) do
    File.mkdir_p!(state.storage_dir)
    load_all_from_disk(state)
    {:noreply, state}
  end

  @impl true
  def handle_call({:save_layout, name, panels}, _from, state) do
    layouts = ets_get(state.table, :layouts)
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    layout = %{
      "id" => generate_id(),
      "name" => name,
      "panels" => panels,
      "created_at" => now,
      "updated_at" => now
    }

    layouts = [layout | layouts]
    persist(state, :layouts, layouts)
    {:reply, {:ok, layout}, state}
  end

  def handle_call({:load_layout, id}, _from, state) do
    layouts = ets_get(state.table, :layouts)
    result = Enum.find(layouts, fn l -> l["id"] == id end)
    {:reply, result, state}
  end

  def handle_call(:list_layouts, _from, state) do
    {:reply, ets_get(state.table, :layouts), state}
  end

  def handle_call({:delete_layout, id}, _from, state) do
    layouts = ets_get(state.table, :layouts) |> Enum.reject(fn l -> l["id"] == id end)
    persist(state, :layouts, layouts)
    {:reply, :ok, state}
  end

  def handle_call({:save_preset, name, filters}, _from, state) do
    presets = ets_get(state.table, :filter_presets)
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    preset = %{
      "id" => generate_id(),
      "name" => name,
      "filters" => filters,
      "created_at" => now
    }

    presets = [preset | presets]
    persist(state, :filter_presets, presets)
    {:reply, {:ok, preset}, state}
  end

  def handle_call({:load_preset, id}, _from, state) do
    presets = ets_get(state.table, :filter_presets)
    result = Enum.find(presets, fn p -> p["id"] == id end)
    {:reply, result, state}
  end

  def handle_call(:list_presets, _from, state) do
    {:reply, ets_get(state.table, :filter_presets), state}
  end

  def handle_call({:delete_preset, id}, _from, state) do
    presets = ets_get(state.table, :filter_presets) |> Enum.reject(fn p -> p["id"] == id end)
    persist(state, :filter_presets, presets)
    {:reply, :ok, state}
  end

  def handle_call({:save_view, name, config}, _from, state) do
    views = ets_get(state.table, :custom_views)
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    view = %{
      "id" => generate_id(),
      "name" => name,
      "type" => Map.get(config, "type", "table"),
      "columns" => Map.get(config, "columns", []),
      "sort_by" => Map.get(config, "sort_by"),
      "sort_dir" => Map.get(config, "sort_dir", "asc"),
      "created_at" => now
    }

    views = [view | views]
    persist(state, :custom_views, views)
    {:reply, {:ok, view}, state}
  end

  def handle_call({:load_view, id}, _from, state) do
    views = ets_get(state.table, :custom_views)
    result = Enum.find(views, fn v -> v["id"] == id end)
    {:reply, result, state}
  end

  def handle_call(:list_views, _from, state) do
    {:reply, ets_get(state.table, :custom_views), state}
  end

  def handle_call({:delete_view, id}, _from, state) do
    views = ets_get(state.table, :custom_views) |> Enum.reject(fn v -> v["id"] == id end)
    persist(state, :custom_views, views)
    {:reply, :ok, state}
  end

  def handle_call({:push_history, layout_id, panels}, _from, state) do
    history = ets_get(state.table, :layout_history)
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    entries = Map.get(history, layout_id, [])

    entry = %{"panels" => panels, "timestamp" => now}
    entries = Enum.take([entry | entries], @max_history)

    history = Map.put(history, layout_id, entries)
    persist(state, :layout_history, history)
    {:reply, :ok, state}
  end

  def handle_call({:undo_layout, layout_id}, _from, state) do
    history = ets_get(state.table, :layout_history)
    entries = Map.get(history, layout_id, [])

    case entries do
      [latest | rest] ->
        history = Map.put(history, layout_id, rest)
        persist(state, :layout_history, history)
        {:reply, {:ok, latest["panels"]}, state}

      [] ->
        {:reply, :empty, state}
    end
  end

  def handle_call(:reload, _from, state) do
    load_all_from_disk(state)
    {:reply, :ok, state}
  end

  # --- Private Helpers ---

  defp load_all_from_disk(state) do
    for {key, _file} <- @files do
      data = read_file(state, key)
      :ets.insert(state.table, {key, data})
    end
  end

  defp read_file(state, key) do
    path = Path.join(state.storage_dir, @files[key])

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, data} -> data
          _ -> default_for(key)
        end

      _ ->
        default_for(key)
    end
  end

  defp default_for(:layout_history), do: %{}
  defp default_for(_), do: []

  defp persist(state, key, data) do
    :ets.insert(state.table, {key, data})
    write_file(state, key, data)
  end

  defp write_file(state, key, data) do
    path = Path.join(state.storage_dir, @files[key])
    tmp_path = path <> ".tmp"
    content = Jason.encode!(data, pretty: true)
    File.write!(tmp_path, content)
    File.rename!(tmp_path, path)
  end

  defp ets_get(table, key) do
    case :ets.lookup(table, key) do
      [{^key, value}] -> value
      [] -> default_for(key)
    end
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.hex_encode32(case: :lower, padding: false)
  end
end
