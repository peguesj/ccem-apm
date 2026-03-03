defmodule ApmV4.Intake.Store do
  @moduledoc """
  GenServer + ETS-backed store for intake events.
  Normalizes incoming events, assigns IDs, persists to ETS, dispatches to Dispatcher.
  """
  use GenServer
  require Logger

  @table :intake_events
  @max_events 1000

  # ── Public API ──────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Submit an intake event. Returns {:ok, event} with normalized + ID-stamped event."
  def submit(event) when is_map(event) do
    try do
      GenServer.call(__MODULE__, {:submit, event}, 5_000)
    catch
      :exit, _ -> {:error, :intake_store_offline}
    end
  end

  @doc "List recent events, optionally filtered."
  def list(opts \\ []) do
    try do
      GenServer.call(__MODULE__, {:list, opts}, 5_000)
    catch
      :exit, _ -> []
    end
  end

  @doc "Get a single event by ID."
  def get(id) do
    try do
      GenServer.call(__MODULE__, {:get, id}, 3_000)
    catch
      :exit, _ -> {:error, :not_found}
    end
  end

  @doc "List all registered watcher modules."
  def watchers do
    try do
      GenServer.call(__MODULE__, :watchers, 3_000)
    catch
      :exit, _ -> []
    end
  end

  @doc "Register a watcher module (must implement ApmV4.Intake.Watcher behaviour)."
  def register_watcher(module) do
    GenServer.cast(__MODULE__, {:register_watcher, module})
  end

  # ── GenServer Callbacks ─────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :ordered_set, :public, read_concurrency: true])
    # Register default watchers
    watchers = [
      ApmV4.Intake.Watchers.NotificationWatcher,
      ApmV4.Intake.Watchers.LogWatcher,
      ApmV4.Intake.Watchers.UatWatcher
    ]
    {:ok, %{watchers: watchers, count: 0}}
  end

  @impl true
  def handle_call({:submit, raw_event}, _from, state) do
    event = normalize(raw_event)
    key = {DateTime.to_unix(event.received_at, :microsecond), event.id}
    :ets.insert(@table, {key, event})
    trim_table()
    ApmV4.Intake.Dispatcher.dispatch(event, state.watchers)
    Phoenix.PubSub.broadcast(ApmV4.PubSub, "intake:events", {:intake_event, event})
    {:reply, {:ok, event}, %{state | count: state.count + 1}}
  end

  def handle_call({:list, opts}, _from, state) do
    source = Keyword.get(opts, :source)
    event_type = Keyword.get(opts, :event_type)
    limit = Keyword.get(opts, :limit, 100)

    events =
      :ets.tab2list(@table)
      |> Enum.map(fn {_k, v} -> v end)
      |> Enum.sort_by(& &1.received_at, {:desc, DateTime})
      |> filter_by_source(source)
      |> filter_by_event_type(event_type)
      |> Enum.take(limit)

    {:reply, events, state}
  end

  def handle_call({:get, id}, _from, state) do
    result =
      :ets.tab2list(@table)
      |> Enum.find(fn {_k, v} -> v.id == id end)
      |> case do
        {_k, event} -> {:ok, event}
        nil -> {:error, :not_found}
      end
    {:reply, result, state}
  end

  def handle_call(:watchers, _from, state) do
    {:reply, state.watchers, state}
  end

  @impl true
  def handle_cast({:register_watcher, module}, state) do
    watchers = if module in state.watchers, do: state.watchers, else: [module | state.watchers]
    {:noreply, %{state | watchers: watchers}}
  end

  # ── Private ─────────────────────────────────────────────────────────────

  defp normalize(raw) do
    %{
      id: raw["id"] || raw[:id] || generate_id(),
      source: (raw["source"] || raw[:source] || "custom") |> to_string(),
      event_type: (raw["event_type"] || raw[:event_type] || "custom") |> to_string(),
      severity: (raw["severity"] || raw[:severity] || "info") |> to_string(),
      project: raw["project"] || raw[:project] || "unknown",
      environment: (raw["environment"] || raw[:environment] || "unknown") |> to_string(),
      payload: raw["payload"] || raw[:payload] || %{},
      metadata: raw["metadata"] || raw[:metadata] || %{},
      received_at: DateTime.utc_now(),
      processed: false,
      watcher_results: []
    }
  end

  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  defp filter_by_source(events, nil), do: events
  defp filter_by_source(events, source), do: Enum.filter(events, &(&1.source == source))

  defp filter_by_event_type(events, nil), do: events
  defp filter_by_event_type(events, event_type), do: Enum.filter(events, &(&1.event_type == event_type))

  defp trim_table do
    count = :ets.info(@table, :size)
    if count > @max_events do
      excess = count - @max_events
      :ets.tab2list(@table)
      |> Enum.sort_by(fn {k, _} -> k end)
      |> Enum.take(excess)
      |> Enum.each(fn {k, _} -> :ets.delete(@table, k) end)
    end
  end
end
