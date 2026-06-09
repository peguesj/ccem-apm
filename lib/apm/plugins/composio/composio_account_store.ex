defmodule Apm.Plugins.Composio.ComposioAccountStore do
  @moduledoc """
  GenServer + ETS store for Composio connected accounts, keyed by user_id.

  Accounts are loaded lazily on first request and cached until `refresh_accounts/1`
  is called. The ETS table holds `{user_id, [account_map]}` tuples.
  """

  use GenServer

  require Logger

  alias Apm.Plugins.Composio.ComposioClient

  @table :composio_accounts

  # ── Public API ─────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Return cached accounts for user_id. Triggers async refresh if not cached."
  @spec list_accounts(String.t()) :: [map()]
  def list_accounts(user_id) when is_binary(user_id) do
    case :ets.lookup(@table, user_id) do
      [{^user_id, accounts}] ->
        accounts

      [] ->
        # Not cached — start async refresh, return empty for now
        refresh_accounts(user_id)
        []
    end
  end

  @doc "Asynchronously refresh accounts for user_id from the Composio API."
  @spec refresh_accounts(String.t()) :: :ok
  def refresh_accounts(user_id) when is_binary(user_id) do
    Task.start(fn ->
      case ComposioClient.list_connected_accounts(user_id) do
        {:ok, result} ->
          accounts = extract_accounts(result)
          put_accounts(user_id, accounts)

        {:error, reason} ->
          Logger.warning(
            "[ComposioAccountStore] refresh_accounts(#{user_id}) failed: #{inspect(reason)}"
          )
      end
    end)

    :ok
  end

  @doc "Directly insert accounts for user_id (used by the async task above)."
  @spec put_accounts(String.t(), [map()]) :: :ok
  def put_accounts(user_id, accounts) when is_binary(user_id) and is_list(accounts) do
    :ets.insert(@table, {user_id, accounts})
    :ok
  end

  # ── GenServer Callbacks ────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    _table = :ets.new(@table, [:named_table, :public, read_concurrency: true])
    {:ok, %{}}
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  defp extract_accounts(%{"items" => list}) when is_list(list), do: list
  defp extract_accounts(%{"data" => list}) when is_list(list), do: list
  defp extract_accounts(%{"accounts" => list}) when is_list(list), do: list
  defp extract_accounts(list) when is_list(list), do: list
  defp extract_accounts(_), do: []
end
