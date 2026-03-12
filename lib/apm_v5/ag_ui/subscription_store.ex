defmodule ApmV5.AgUi.SubscriptionStore do
  @moduledoc """
  Persists EventBus subscription patterns to JSON file for restoration after restart.

  ## US-045 Acceptance Criteria (DoD):
  - Stores registered subscription patterns in ETS :ag_ui_subscriptions
  - Persistent subscriptions saved to JSON file
  - On EventBus init, persistent subscriptions restored
  - Entries include: pattern, subscriber_module, registered_at
  - list_subscriptions/0 returns all active subscriptions
  - mix compile --warnings-as-errors passes
  """

  @table :ag_ui_subscriptions
  @persistence_path "~/.claude/ccem/apm/subscriptions.json"

  @doc "Initialize the subscription store ETS table."
  @spec init() :: :ok
  def init do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    end

    :ok
  end

  @doc "Registers a persistent subscription pattern."
  @spec register(String.t(), atom() | String.t()) :: :ok
  def register(pattern, subscriber_module) do
    entry = %{
      pattern: pattern,
      subscriber_module: to_string(subscriber_module),
      registered_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    :ets.insert(@table, {pattern, entry})
    persist_to_file()
    :ok
  end

  @doc "Removes a persistent subscription."
  @spec unregister(String.t()) :: :ok
  def unregister(pattern) do
    :ets.delete(@table, pattern)
    persist_to_file()
    :ok
  end

  @doc "Returns all registered subscriptions."
  @spec list_subscriptions() :: [map()]
  def list_subscriptions do
    if :ets.whereis(@table) != :undefined do
      :ets.tab2list(@table)
      |> Enum.map(fn {_key, entry} -> entry end)
    else
      []
    end
  end

  @doc "Restores persistent subscriptions from disk."
  @spec restore() :: [map()]
  def restore do
    path = expand_path()

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, entries} when is_list(entries) ->
            Enum.each(entries, fn entry ->
              pattern = entry["pattern"]
              :ets.insert(@table, {pattern, %{
                pattern: pattern,
                subscriber_module: entry["subscriber_module"],
                registered_at: entry["registered_at"]
              }})
            end)

            entries

          _ ->
            []
        end

      {:error, _} ->
        []
    end
  end

  # -- Private ----------------------------------------------------------------

  defp persist_to_file do
    path = expand_path()
    dir = Path.dirname(path)
    File.mkdir_p!(dir)

    entries =
      list_subscriptions()
      |> Enum.map(fn entry ->
        %{
          "pattern" => entry.pattern,
          "subscriber_module" => entry.subscriber_module,
          "registered_at" => entry.registered_at
        }
      end)

    File.write!(path, Jason.encode!(entries, pretty: true))
  rescue
    error ->
      require Logger
      Logger.warning("SubscriptionStore: failed to persist: #{inspect(error)}")
  end

  defp expand_path do
    Path.expand(@persistence_path)
  end
end
