defmodule ApmWeb.Showcase.PayloadStore do
  @moduledoc """
  ETS-backed store for the most recent payload ingested by each
  `{engine_id, project_name}` pair.

  Chosen over Postgres/SQLite for v1 because:

    * Payloads (e.g. feature-flow layered graph JSON) are large and
      regenerated on every consumer-side `/feature-flow index`.
    * Survival across APM restarts is not required — the consumer
      reposts on next index.
    * Lookups are O(1) by key and called on every fetch/render.

  If a future engine needs durability, swap `:ets.new/2` for a
  per-engine Postgres table without changing this module's public API.
  """

  use GenServer

  @table :showcase_engine_payloads

  # --- Public API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Store the most recent payload for `{engine_id, project_name}`.

  The payload is wrapped with metadata (`:inserted_at`) before being
  written. Returns `:ok`.
  """
  @spec put(String.t(), String.t(), map()) :: :ok
  def put(engine_id, project_name, payload)
      when is_binary(engine_id) and is_binary(project_name) and is_map(payload) do
    record = %{
      engine_id: engine_id,
      project_name: project_name,
      payload: payload,
      inserted_at: System.system_time(:second)
    }

    :ets.insert(table(), {{engine_id, project_name}, record})
    :ok
  end

  @doc """
  Fetch the most recent payload for `{engine_id, project_name}`.

  Returns `{:ok, record}` or `{:error, :not_found}`.
  """
  @spec get(String.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(engine_id, project_name)
      when is_binary(engine_id) and is_binary(project_name) do
    case :ets.lookup(table(), {engine_id, project_name}) do
      [{_key, record}] -> {:ok, record}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Delete the payload for `{engine_id, project_name}`. Returns `:ok` whether
  or not a payload existed.
  """
  @spec delete(String.t(), String.t()) :: :ok
  def delete(engine_id, project_name)
      when is_binary(engine_id) and is_binary(project_name) do
    :ets.delete(table(), {engine_id, project_name})
    :ok
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    # The table is created here so the supervised process owns it. It is
    # `:public` so controllers and engines can read/write directly without
    # serializing through this GenServer.
    table =
      case :ets.whereis(@table) do
        :undefined ->
          :ets.new(@table, [
            :set,
            :public,
            :named_table,
            read_concurrency: true,
            write_concurrency: true
          ])

        ref when is_reference(ref) ->
          ref
      end

    {:ok, %{table: table}}
  end

  # --- Internals ---

  defp table, do: @table
end
