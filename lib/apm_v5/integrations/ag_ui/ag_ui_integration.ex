defmodule ApmV5.Integrations.AgUi.AgUiIntegration do
  @moduledoc """
  AG-UI protocol integration.

  Bridges APM's internal event model to the AG-UI open protocol via the
  ag_ui_ex Hex SDK. Supports event emission, subscription, replay, and
  hook bridge health queries.
  """

  @behaviour ApmV5.Integrations.IntegrationBehaviour

  alias ApmV5.AgUi.EventBus

  # ── IntegrationBehaviour ─────────────────────────────────────────────────────

  @impl true
  @spec integration_name() :: String.t()
  def integration_name, do: "ag_ui"

  @impl true
  @spec integration_description() :: String.t()
  def integration_description,
    do: "AG-UI protocol bridge — translates APM lifecycle events to 33-type AG-UI event model via ag_ui_ex Hex SDK."

  @impl true
  @spec integration_version() :: String.t()
  def integration_version, do: "5.3.0"

  @impl true
  @spec protocol() :: atom()
  def protocol, do: :ag_ui

  @impl true
  @spec connect(map()) :: {:ok, term()} | {:error, term()}
  def connect(_config), do: {:ok, :supervised}

  @impl true
  @spec disconnect() :: :ok
  def disconnect, do: :ok

  @impl true
  @spec status() :: atom()
  def status do
    if Process.whereis(ApmV5.AgUi.EventBus), do: :connected, else: :disconnected
  end

  @impl true
  @spec list_endpoints() :: [map()]
  def list_endpoints do
    [
      %{
        action: "emit_event",
        description: "Emit an AG-UI protocol event",
        params: %{event_type: "string", data: "map (optional)"}
      },
      %{
        action: "stats",
        description: "Get EventBus statistics (event counts, subscriber info)",
        params: %{}
      },
      %{
        action: "replay_since",
        description: "Replay events since a sequence number",
        params: %{since_seq: "integer", topic_filter: "string (optional)"}
      }
    ]
  end

  @impl true
  @spec handle_event(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def handle_event("emit_event", %{"event_type" => event_type} = params, _opts) do
    data = Map.get(params, "data", %{})

    case EventBus.publish(event_type, data) do
      {:ok, event} -> {:ok, %{status: "emitted", event: event}}
      {:error, :invalid_event_type} -> {:error, {:invalid_event_type, event_type}}
    end
  end

  def handle_event("emit_event", _params, _opts) do
    {:error, {:missing_param, "event_type is required"}}
  end

  def handle_event("stats", _params, _opts) do
    stats = EventBus.stats()
    {:ok, %{stats: stats}}
  end

  def handle_event("replay_since", %{"since_seq" => since_seq} = params, _opts) do
    topic_filter = Map.get(params, "topic_filter")
    since = if is_binary(since_seq), do: String.to_integer(since_seq), else: since_seq

    case EventBus.replay_since(since, topic_filter) do
      {:ok, events} -> {:ok, %{events: events, count: length(events)}}
      :gap -> {:ok, %{status: "gap", message: "Event gap detected — some events unavailable"}}
    end
  end

  def handle_event("replay_since", _params, _opts) do
    {:error, {:missing_param, "since_seq is required"}}
  end

  def handle_event(action, _params, _opts) do
    {:error, {:unknown_action, action}}
  end

  @impl true
  @spec supervisor_children() :: [Supervisor.child_spec()]
  def supervisor_children, do: []
end
