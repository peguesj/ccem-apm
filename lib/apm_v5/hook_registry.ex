defmodule ApmV5.HookRegistry do
  @moduledoc "Registry of hookable points across CCEM APM GenServers and LiveViews."
  use GenServer
  require Logger

  @table :hook_registry

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec register_hook(map()) :: :ok
  def register_hook(hook) when is_map(hook) do
    name = Map.fetch!(hook, :name)
    :ets.insert(@table, {name, hook})
    Phoenix.PubSub.broadcast(ApmV5.PubSub, "apm:hooks", {:hook_registered, hook})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @spec list_hooks() :: [map()]
  def list_hooks do
    :ets.tab2list(@table) |> Enum.map(fn {_name, hook} -> hook end)
  rescue
    ArgumentError -> []
  end

  @spec get_hooks_for(atom()) :: [map()]
  def get_hooks_for(category) do
    list_hooks() |> Enum.filter(&(&1[:category] == category))
  end

  @spec fire_hook(String.t(), map()) :: :ok
  def fire_hook(name, payload \\ %{}) do
    Phoenix.PubSub.broadcast(ApmV5.PubSub, "apm:hooks", {:hook_fired, name, payload})
    :ok
  rescue
    _ -> :ok
  end

  @spec unregister_hook(String.t()) :: :ok
  def unregister_hook(name) do
    :ets.delete(@table, name)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    register_defaults()
    Logger.info("[HookRegistry] Initialized with default hookable points")
    {:ok, %{}}
  end

  defp register_defaults do
    defaults = [
      %{name: "pre_tool_use", category: :pre_tool, module: :external, description: "Before tool execution"},
      %{name: "post_tool_use", category: :post_tool, module: :external, description: "After tool execution"},
      %{name: "session_start", category: :session, module: :external, description: "Session initialized"},
      %{name: "session_end", category: :session, module: :external, description: "Session terminated"},
      %{name: "agent_registered", category: :formation, module: ApmV5.AgentRegistry, description: "New agent registered"},
      %{name: "formation_deployed", category: :formation, module: ApmV5.FormationStore, description: "Formation deployed"},
      %{name: "notification_added", category: :notification, module: ApmV5.NotificationBroadcaster, description: "Notification created"},
      %{name: "auth_decision", category: :authorization, module: ApmV5.Auth.PendingDecisions, description: "Authorization decided"},
      %{name: "settings_changed", category: :custom, module: ApmV5.SettingsStore, description: "Settings updated"},
      %{name: "error_detected", category: :custom, module: ApmV5.ErrorDaemon, description: "Error captured by daemon"}
    ]
    Enum.each(defaults, fn hook -> :ets.insert(@table, {hook.name, hook}) end)
  end
end
