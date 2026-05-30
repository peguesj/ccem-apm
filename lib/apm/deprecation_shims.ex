defmodule ApmV5 do
  @moduledoc """
  Deprecated top-level alias for `Apm`. Removed in v11.1.0.

  All code should be updated to reference `Apm` directly.
  """
end

defmodule ApmV5Web do
  @moduledoc """
  Deprecated alias for `ApmWeb`. Removed in v11.1.0.

  Replace all `use ApmV5Web, :controller` with `use ApmWeb, :controller`, etc.
  """
  @deprecated "Use ApmWeb instead — ApmV5Web removed in v11.1.0"

  defdelegate static_paths(), to: ApmWeb
  defdelegate router(), to: ApmWeb
  defdelegate channel(), to: ApmWeb
  defdelegate controller(), to: ApmWeb
  defdelegate live_view(), to: ApmWeb
  defdelegate html(), to: ApmWeb
  defdelegate verified_routes(), to: ApmWeb

  defmacro __using__(which) do
    quote do
      use ApmWeb, unquote(which)
    end
  end
end

defmodule ApmV5.Application do
  @moduledoc false
  @deprecated "Use Apm.Application — ApmV5.Application removed in v11.1.0"
  defdelegate start(type, args), to: Apm.Application
  defdelegate stop(state), to: Apm.Application
end

defmodule ApmV5.AgentRegistry do
  @moduledoc false
  @deprecated "Use Apm.AgentRegistry — ApmV5.AgentRegistry removed in v11.1.0"
  defdelegate register_agent(agent_id, metadata \\ %{}), to: Apm.AgentRegistry
  defdelegate register_agent(agent_id, metadata, project_name), to: Apm.AgentRegistry
  defdelegate get_agent(agent_id), to: Apm.AgentRegistry
  defdelegate list_agents(), to: Apm.AgentRegistry
  defdelegate list_agents(project_name), to: Apm.AgentRegistry
  defdelegate update_status(agent_id, status), to: Apm.AgentRegistry
  defdelegate register_session(session_data), to: Apm.AgentRegistry
  defdelegate get_session(session_id), to: Apm.AgentRegistry
  defdelegate list_sessions(), to: Apm.AgentRegistry
  defdelegate add_notification(notification), to: Apm.AgentRegistry
  defdelegate get_notifications(), to: Apm.AgentRegistry
  defdelegate wave_progress(formation_id), to: Apm.AgentRegistry
end

defmodule ApmV5.ConfigLoader do
  @moduledoc false
  @deprecated "Use Apm.ConfigLoader — ApmV5.ConfigLoader removed in v11.1.0"
  defdelegate get_config(), to: Apm.ConfigLoader
  defdelegate get_project(name), to: Apm.ConfigLoader
  defdelegate get_active_project(), to: Apm.ConfigLoader
  defdelegate reload(), to: Apm.ConfigLoader
  defdelegate update_project(params), to: Apm.ConfigLoader
end

defmodule ApmV5.AuditLog do
  @moduledoc false
  @deprecated "Use Apm.AuditLog — ApmV5.AuditLog removed in v11.1.0"
  defdelegate log(event_type, actor, resource, details \\ %{}), to: Apm.AuditLog
  defdelegate query(opts \\ []), to: Apm.AuditLog
  defdelegate tail(n \\ 20), to: Apm.AuditLog
  defdelegate stats(), to: Apm.AuditLog
  defdelegate clear_all(), to: Apm.AuditLog
end

defmodule ApmV5.Auth.AuthorizationGate do
  @moduledoc false
  @deprecated "Use Apm.Auth.AuthorizationGate — ApmV5.Auth.AuthorizationGate removed in v11.1.0"
  defdelegate authorize(agent_id, session_id, tool_name, role \\ "agent", params \\ %{}),
    to: Apm.Auth.AuthorizationGate

  defdelegate register_tool(tool_name, risk_level, opts \\ []), to: Apm.Auth.AuthorizationGate
  defdelegate record_execution(token_id, tool_name, result \\ %{}), to: Apm.Auth.AuthorizationGate
  defdelegate list_tools(), to: Apm.Auth.AuthorizationGate
  defdelegate summary(), to: Apm.Auth.AuthorizationGate
end

defmodule ApmV5.UpmStore do
  @moduledoc false
  @deprecated "Use Apm.UpmStore — ApmV5.UpmStore removed in v11.1.0"
  defdelegate register_formation(params), to: Apm.UpmStore
  defdelegate get_formation(id), to: Apm.UpmStore
  defdelegate list_formations(), to: Apm.UpmStore
  defdelegate list_all_formations(), to: Apm.UpmStore
  defdelegate record_event(params), to: Apm.UpmStore
  defdelegate get_events(session_id), to: Apm.UpmStore
  defdelegate register_agent(params), to: Apm.UpmStore
  defdelegate register_session(params), to: Apm.UpmStore
  defdelegate get_status(), to: Apm.UpmStore
end

defmodule ApmV5.FormationStore do
  @moduledoc false
  @deprecated "Use Apm.UpmStore (formations API) — ApmV5.FormationStore removed in v11.1.0"
  defdelegate list_formations(), to: Apm.UpmStore
  defdelegate list_all_formations(), to: Apm.UpmStore
end

defmodule ApmV5.Plugins.PluginRegistry do
  @moduledoc false
  @deprecated "Use Apm.Plugins.PluginRegistry — ApmV5.Plugins.PluginRegistry removed in v11.1.0"
  defdelegate list_plugins(), to: Apm.Plugins.PluginRegistry
  defdelegate get_plugin(name), to: Apm.Plugins.PluginRegistry
  defdelegate register_plugin(module), to: Apm.Plugins.PluginRegistry
  defdelegate call_plugin_action(plugin_name, action, params), to: Apm.Plugins.PluginRegistry
end

defmodule ApmV5.AgUi.EventBus do
  @moduledoc false
  @deprecated "Use Apm.AgUi.EventBus — ApmV5.AgUi.EventBus removed in v11.1.0"
  defdelegate publish(type, data \\ %{}), to: Apm.AgUi.EventBus
  defdelegate subscribe(pattern, opts \\ []), to: Apm.AgUi.EventBus
  defdelegate unsubscribe(), to: Apm.AgUi.EventBus
  defdelegate replay_since(since_seq, topic_filter \\ nil), to: Apm.AgUi.EventBus
  defdelegate stats(), to: Apm.AgUi.EventBus
end

defmodule ApmV5.AppVersion do
  @moduledoc false
  @deprecated "Use Apm.AppVersion — ApmV5.AppVersion removed in v11.1.0"
  defdelegate current(), to: Apm.AppVersion
end
