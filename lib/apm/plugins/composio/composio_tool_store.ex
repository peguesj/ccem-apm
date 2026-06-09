defmodule Apm.Plugins.Composio.ComposioToolStore do
  @moduledoc """
  GenServer + ETS store for Composio toolkit catalog.

  On start, immediately schedules a refresh from the Composio API. Refreshes
  every 5 minutes by default, or 60 seconds on failure. Callers that need a
  fresh list can call `force_refresh/0`.

  ## ETS schema

      {slug :: String.t(), toolkit_map :: map()}
  """

  use GenServer

  require Logger

  alias Apm.Plugins.Composio.ComposioClient

  @table :composio_tools
  @refresh_interval_ms 5 * 60 * 1_000
  @retry_interval_ms 60_000

  # ── Public API ─────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Return all cached toolkits."
  @spec list_toolkits() :: [map()]
  def list_toolkits do
    :ets.tab2list(@table) |> Enum.map(fn {_slug, tk} -> tk end)
  end

  @doc "Return a single toolkit by slug, or nil."
  @spec get_toolkit(String.t()) :: map() | nil
  def get_toolkit(slug) when is_binary(slug) do
    case :ets.lookup(@table, slug) do
      [{^slug, tk}] -> tk
      [] -> nil
    end
  end

  @doc "Trigger an immediate cache refresh (async)."
  @spec force_refresh() :: :ok
  def force_refresh do
    send(__MODULE__, :refresh)
    :ok
  end

  # ── GenServer Callbacks ────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    table = :ets.new(@table, [:named_table, :public, read_concurrency: true])
    interval = Keyword.get(opts, :refresh_interval_ms, @refresh_interval_ms)

    send(self(), :refresh)

    {:ok, %{table: table, last_refreshed: nil, refresh_interval_ms: interval}}
  end

  @impl true
  def handle_info(:refresh, state) do
    case ComposioClient.list_toolkits() do
      {:ok, %{"items" => items}} when is_list(items) ->
        :ets.delete_all_objects(state.table)

        Enum.each(items, fn tk ->
          slug = Map.get(tk, "slug") || Map.get(tk, "name") || inspect(tk)
          :ets.insert(state.table, {slug, tk})
        end)

        Logger.debug("[ComposioToolStore] Refreshed #{length(items)} toolkits")
        Process.send_after(self(), :refresh, state.refresh_interval_ms)
        {:noreply, %{state | last_refreshed: DateTime.utc_now()}}

      {:ok, result} ->
        # API returned OK but with unexpected shape — store raw if list
        items = extract_list(result)
        :ets.delete_all_objects(state.table)

        Enum.each(items, fn tk ->
          slug = Map.get(tk, "slug") || Map.get(tk, "name") || inspect(tk)
          :ets.insert(state.table, {slug, tk})
        end)

        Logger.debug("[ComposioToolStore] Refreshed #{length(items)} toolkits (raw)")
        Process.send_after(self(), :refresh, state.refresh_interval_ms)
        {:noreply, %{state | last_refreshed: DateTime.utc_now()}}

      {:error, reason} ->
        Logger.warning(
          "[ComposioToolStore] Refresh failed: #{inspect(reason)}, retry in #{@retry_interval_ms}ms"
        )

        Process.send_after(self(), :refresh, @retry_interval_ms)
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Private ─────────────────────────────────────────────────────────────────

  defp extract_list(result) when is_list(result), do: result
  defp extract_list(%{"data" => list}) when is_list(list), do: list
  defp extract_list(%{"toolkits" => list}) when is_list(list), do: list
  defp extract_list(_), do: []
end
