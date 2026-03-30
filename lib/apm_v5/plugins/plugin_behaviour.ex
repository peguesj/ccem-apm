defmodule ApmV5.Plugins.PluginBehaviour do
  @moduledoc """
  Behaviour that all APM plugins must implement.

  A plugin is a self-contained module that exposes named actions callable
  via the PluginRegistry. Plugins may also optionally provide an
  `inspector_section/1` callback for rendering a LiveView HTML section
  in the PluginDashboardLive.

  ## Minimal Example

      defmodule MyPlugin do
        @behaviour ApmV5.Plugins.PluginBehaviour

        @impl true
        def plugin_name, do: "my_plugin"

        @impl true
        def plugin_description, do: "Does something useful"

        @impl true
        def plugin_version, do: "1.0.0"

        @impl true
        def list_endpoints do
          [%{action: "hello", description: "Say hello", params: %{name: "string"}}]
        end

        @impl true
        def handle_action("hello", %{"name" => name}, _opts), do: {:ok, %{message: "Hello, \#{name}"}}
        def handle_action(action, _params, _opts), do: {:error, {:unknown_action, action}}
      end
  """

  @doc "Unique machine-friendly name for this plugin (e.g. \"plane\")."
  @callback plugin_name() :: String.t()

  @doc "Human-readable description of what this plugin does."
  @callback plugin_description() :: String.t()

  @doc "SemVer string for this plugin (e.g. \"1.0.0\")."
  @callback plugin_version() :: String.t()

  @doc """
  Returns a list of endpoint descriptors this plugin exposes.

  Each map SHOULD include at minimum:
    - `:action` (String.t) — the action name
    - `:description` (String.t) — human-readable purpose
    - `:params` (map) — parameter schema (key => type string)
  """
  @callback list_endpoints() :: [map()]

  @doc """
  Dispatches a named action with the given params and options.

  Returns `{:ok, result_map}` on success or `{:error, reason}` on failure.
  """
  @callback handle_action(action :: String.t(), params :: map(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}

  @doc """
  Optional. Returns an HEEx assigns-map suitable for embedding a plugin-specific
  inspector section inside PluginDashboardLive.  The map must at minimum include
  a `:html` key containing the rendered fragment.
  """
  @callback inspector_section(assigns :: map()) :: map()

  @doc """
  Optional. Returns a list of child specs for GenServers or supervisors that this
  plugin owns.  These will be started under the plugin's supervision context.
  Return `[]` if the plugin has no supervised processes.
  """
  @callback supervisor_children() :: [Supervisor.child_spec()]

  @doc """
  Optional. Returns a list of LiveView route descriptors that this plugin provides.
  Each entry is a `{path, module, opts}` tuple where:
    - `path` is the URL path string (e.g. `"/plugins/myfeature"`)
    - `module` is the LiveView module atom
    - `opts` is a keyword list of route options (e.g. `[as: :myfeature_live]`)
  Return `[]` if the plugin provides no LiveView routes.
  """
  @callback live_views() :: [{path :: String.t(), module :: module(), opts :: keyword()}]

  @doc """
  Optional. Called when this plugin is enabled at runtime.
  Should perform any startup work needed (e.g. starting external connections).
  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  @callback on_enable() :: :ok | {:error, term()}

  @doc """
  Optional. Called when this plugin is disabled at runtime.
  Should perform any teardown work needed (e.g. closing external connections).
  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  @callback on_disable() :: :ok | {:error, term()}

  @doc """
  Optional. Returns whether this plugin should be enabled by default when the
  registry starts.  Defaults to `true` when not implemented.
  """
  @callback default_enabled?() :: boolean()

  @doc """
  Optional. Returns nav subitems for this plugin in the sidebar.
  Each tuple is `{label, path, hero_icon_name_or_nil}`.

  Example:
      [{"Board", "/plugins/plane/board", "hero-squares-2x2"},
       {"Issues", "/plugins/plane/issues", "hero-list-bullet"}]
  """
  @callback nav_items() :: [{String.t(), String.t(), String.t() | nil}]

  @doc """
  Optional. Returns the settings page path for this plugin, or `nil` if none.
  """
  @callback settings_path() :: String.t() | nil

  @doc """
  Optional. Returns the LiveView module for this plugin's main page, or `nil`.
  """
  @callback plugin_live_module() :: module() | nil

  @doc """
  Optional. Returns a list of integration module names that this plugin provides
  or depends on.  Used by the symbiosis layer to cross-reference plugins with
  their counterpart `IntegrationBehaviour` modules.

  Example:
      def plugin_integrations, do: [ApmV5.Integrations.AgUi.AgUiIntegration]

  Return `[]` if this plugin has no associated integrations.
  """
  @callback plugin_integrations() :: [module()]

  @doc """
  Optional. Returns a list of widget definitions that this plugin contributes to
  the Dashboard widget palette.  Each map must conform to the `WidgetDefinition`
  schema documented in `ApmV5.WidgetRegistry`.

  These widgets are automatically registered in `ApmV5.WidgetRegistry` after
  the plugin is loaded.

  Example:
      def dashboard_widgets do
        [%{id: "my_board", name: "My Board", category: :plugin,
           source_module: __MODULE__, refresh_interval: 60_000,
           min_width: 4, min_height: 3, config_schema: %{}, plugin: "my_plugin",
           version: "1.0.0", description: "Shows my board"}]
      end

  Return `[]` if this plugin provides no dashboard widgets.
  """
  @callback dashboard_widgets() :: [map()]

  @optional_callbacks [
    inspector_section: 1,
    supervisor_children: 0,
    live_views: 0,
    on_enable: 0,
    on_disable: 0,
    default_enabled?: 0,
    nav_items: 0,
    settings_path: 0,
    plugin_live_module: 0,
    plugin_integrations: 0,
    dashboard_widgets: 0
  ]
end
