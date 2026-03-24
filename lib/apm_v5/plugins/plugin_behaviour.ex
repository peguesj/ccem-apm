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
  @optional_callbacks [inspector_section: 1]
  @callback inspector_section(assigns :: map()) :: map()
end
