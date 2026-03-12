defmodule ApmV5.Intake.Dispatcher do
  @moduledoc "Dispatches intake events to all matching registered watchers."
  require Logger

  @doc "Dispatch event to all matching watcher modules."
  def dispatch(event, watchers) when is_list(watchers) do
    results =
      watchers
      |> Enum.filter(&ApmV5.Intake.Watcher.matches?(&1, event))
      |> Enum.map(fn watcher ->
        try do
          result = watcher.handle(event, %{})
          {watcher.name(), result}
        rescue
          e ->
            Logger.warning("[Intake.Dispatcher] Watcher #{watcher.name()} failed: #{inspect(e)}")
            {watcher.name(), {:error, e}}
        catch
          :exit, reason ->
            Logger.warning("[Intake.Dispatcher] Watcher #{watcher.name()} exited: #{inspect(reason)}")
            {watcher.name(), {:error, {:exit, reason}}}
        end
      end)

    Logger.debug("[Intake.Dispatcher] Event #{event.id} dispatched to #{length(results)} watchers")
    results
  end
end
