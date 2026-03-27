defmodule ApmV5.Integrations.IntegrationBehaviour do
  @moduledoc """
  Behaviour that all APM integrations must implement.

  An integration bridges APM to an external protocol or system (AG-UI, AgentLock, Linear, GitHub).
  Unlike plugins (self-contained APM features), integrations are bidirectional adapters —
  they translate between APM's internal event model and an external protocol.

  ## Required vs Optional Callbacks

  Required callbacks establish the integration's identity, connectivity lifecycle,
  and event-handling contract. Optional callbacks support richer lifecycle hooks
  and inspector UI sections.

  ## Minimal Example

      defmodule MyIntegration do
        @behaviour ApmV5.Integrations.IntegrationBehaviour

        @impl true
        def integration_name, do: "my_integration"

        @impl true
        def integration_description, do: "Bridges APM to MyProtocol"

        @impl true
        def integration_version, do: "1.0.0"

        @impl true
        def protocol, do: :rest

        @impl true
        def connect(_config), do: {:ok, %{connected_at: DateTime.utc_now()}}

        @impl true
        def disconnect, do: :ok

        @impl true
        def status, do: :connected

        @impl true
        def list_endpoints, do: [%{action: "ping", description: "Ping the integration"}]

        @impl true
        def handle_event("ping", _payload, _opts), do: {:ok, %{pong: true}}
        def handle_event(event, _payload, _opts), do: {:error, {:unknown_event, event}}

        @impl true
        def supervisor_children, do: []
      end
  """

  @doc "Unique machine-friendly name for this integration (e.g. \"ag_ui\", \"agentlock\")."
  @callback integration_name() :: String.t()

  @doc "Human-readable description of what this integration does."
  @callback integration_description() :: String.t()

  @doc "SemVer string for this integration (e.g. \"1.0.0\")."
  @callback integration_version() :: String.t()

  @doc """
  The external protocol this integration bridges to.
  One of: `:ag_ui | :oauth2 | :webhook | :rest | :custom`
  """
  @callback protocol() :: :ag_ui | :oauth2 | :webhook | :rest | :custom

  @doc """
  Initiates a connection to the external system with the given config map.
  Returns `{:ok, state}` on success or `{:error, reason}` on failure.
  """
  @callback connect(config :: map()) :: {:ok, term()} | {:error, term()}

  @doc "Tears down the connection to the external system. Returns `:ok`."
  @callback disconnect() :: :ok

  @doc """
  Returns the current connectivity status of this integration.
  One of: `:connected | :disconnected | :degraded | :initializing`
  """
  @callback status() :: :connected | :disconnected | :degraded | :initializing

  @doc """
  Returns a list of endpoint descriptors that this integration exposes.
  Each map SHOULD include at minimum:
    - `:action` (String.t) — the event/action name
    - `:description` (String.t) — human-readable purpose
  """
  @callback list_endpoints() :: [map()]

  @doc """
  Handles an inbound event from the external protocol.
  `event_type` is a string matching one of the actions from `list_endpoints/0`.
  Returns `{:ok, result_map}` on success or `{:error, reason}` on failure.
  """
  @callback handle_event(event_type :: String.t(), payload :: map(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}

  @doc """
  Returns a list of child specs for GenServers or supervisors that this
  integration owns.  The IntegrationRegistry will start these under its
  supervision context when the integration is loaded.
  Return `[]` if the integration has no supervised processes.
  """
  @callback supervisor_children() :: [Supervisor.child_spec()]

  @doc """
  Optional. Returns an HEEx assigns-map suitable for embedding an integration-specific
  inspector section inside the PluginDashboardLive Integrations tab.
  The map must at minimum include a `:html` key containing the rendered fragment.
  """
  @callback inspector_section(assigns :: map()) :: map()

  @doc """
  Optional. Called after `connect/1` succeeds. Useful for post-connect setup,
  subscribing to external channels, or initialising state.
  """
  @callback on_connect_callback(config :: map()) :: :ok

  @doc """
  Optional. Called after `disconnect/0`. Useful for cleanup, unsubscribing,
  or flushing buffered events.
  """
  @callback on_disconnect_callback() :: :ok

  @optional_callbacks [
    inspector_section: 1,
    on_connect_callback: 1,
    on_disconnect_callback: 0
  ]
end
