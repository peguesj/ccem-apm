defmodule Apm.Plugins.Harness.HookTelemetryBuffer do
  @moduledoc """
  ETS-backed ring buffer for Claude Code hook execution events.

  Subscribes to the `"apm:hooks"` PubSub topic and stores each
  `{:hook_fired, name, payload}` message as a sequenced event map.
  The ring is capped at `@max_size` entries; when full the oldest
  entry (lowest sequence key) is deleted before inserting.

  ## ETS schema

      {seq :: integer(), event_map :: map()}

  where `seq` is `:erlang.monotonic_time()` at insertion time,
  giving a naturally-ordered unique key without a counter GenServer.
  """

  use GenServer

  require Logger

  @table :harness_hook_buffer
  @max_size 500

  # ── Public API ────────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Return the last `limit` events sorted by sequence descending (newest first)."
  @spec recent(non_neg_integer()) :: [map()]
  def recent(limit \\ 50) when is_integer(limit) and limit >= 0 do
    :ets.tab2list(@table)
    |> Enum.sort_by(fn {seq, _} -> seq end, :desc)
    |> Enum.take(limit)
    |> Enum.map(fn {_seq, event} -> event end)
  end

  @doc "Return aggregate counts across all buffered events."
  @spec stats() :: %{
          total: non_neg_integer(),
          by_event: %{optional(String.t()) => non_neg_integer()}
        }
  def stats do
    entries = :ets.tab2list(@table)

    by_event =
      Enum.reduce(entries, %{}, fn {_seq, %{event: name}}, acc ->
        Map.update(acc, name, 1, &(&1 + 1))
      end)

    %{total: length(entries), by_event: by_event}
  end

  @doc "Remove all entries from the buffer."
  @spec clear() :: :ok
  def clear do
    :ets.delete_all_objects(@table)
    :ok
  end

  # ── GenServer Callbacks ───────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    :ets.new(@table, [:ordered_set, :named_table, :public, read_concurrency: true])
    Phoenix.PubSub.subscribe(Apm.PubSub, "apm:hooks")
    Logger.info("[HookTelemetryBuffer] ETS ring buffer #{@table} ready, subscribed to apm:hooks")
    {:ok, %{}}
  end

  @impl true
  def handle_info({:hook_fired, name, payload}, state) do
    seq = :erlang.monotonic_time()

    event = %{
      seq: seq,
      event: name,
      payload: payload,
      ts: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    prune_if_full()
    :ets.insert(@table, {seq, event})

    {:noreply, state}
  end

  def handle_info({:hook_registered, _hook}, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  # ── Private ───────────────────────────────────────────────────────────────────

  @spec prune_if_full() :: :ok
  defp prune_if_full do
    if :ets.info(@table, :size) >= @max_size do
      # :ordered_set — first/1 gives the lowest (oldest) key
      case :ets.first(@table) do
        :"$end_of_table" ->
          :ok

        oldest_seq ->
          :ets.delete(@table, oldest_seq)
          :ok
      end
    else
      :ok
    end
  end
end
