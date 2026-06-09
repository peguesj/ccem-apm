defmodule Apm.Plugins.OpenDesign.OpenDesignMonitor do
  @moduledoc """
  GenServer that polls the open-design daemon every 30 seconds and broadcasts
  state changes on the `"open_design:state"` PubSub topic.

  Monitors daemon reachability, agent detection, skill count, and project count.
  Only broadcasts when state differs from the previous snapshot.

  Open Design daemon runs at http://localhost:17456 by default.
  """

  use GenServer

  require Logger

  alias Apm.Plugins.OpenDesign.OpenDesignClient

  @pubsub_topic "open_design:state"
  @poll_interval_ms 30_000
  @default_port 17456

  @type daemon_state :: %{
          reachable: boolean(),
          version: String.t() | nil,
          agents: list(),
          skill_count: non_neg_integer(),
          design_system_count: non_neg_integer(),
          project_count: non_neg_integer(),
          last_checked: String.t(),
          port: non_neg_integer()
        }

  # ── Public API ────────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec current_state() :: daemon_state()
  def current_state do
    GenServer.call(__MODULE__, :current_state)
  end

  @spec health_check() :: %{healthy: boolean(), details: daemon_state()}
  def health_check do
    GenServer.call(__MODULE__, :health_check)
  end

  # ── GenServer Callbacks ───────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    port = Keyword.get(opts, :port, @default_port)
    :timer.send_interval(@poll_interval_ms, self(), :poll)

    initial = build_state(port)
    send(self(), :poll)

    Logger.info(
      "[OpenDesignMonitor] Started, polling localhost:#{port} every #{@poll_interval_ms}ms"
    )

    {:ok, %{daemon: initial, port: port}}
  end

  @impl true
  def handle_call(:current_state, _from, %{daemon: d} = state) do
    {:reply, d, state}
  end

  def handle_call(:health_check, _from, %{daemon: d} = state) do
    {:reply, %{healthy: d.reachable, details: d}, state}
  end

  @impl true
  def handle_info(:poll, %{port: port, daemon: prev} = state) do
    new_daemon = build_state(port)

    if new_daemon != prev do
      Phoenix.PubSub.broadcast(
        Apm.PubSub,
        @pubsub_topic,
        {:open_design_state_updated, new_daemon}
      )
    end

    {:noreply, %{state | daemon: new_daemon}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Private ───────────────────────────────────────────────────────────────────

  @spec build_state(non_neg_integer()) :: daemon_state()
  defp build_state(port) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    case OpenDesignClient.health(port) do
      {:ok, health_body} ->
        version =
          case OpenDesignClient.version(port) do
            {:ok, %{"version" => v}} -> v
            {:ok, v} when is_binary(v) -> v
            _ -> Map.get(health_body, "version")
          end

        agents = fetch_list(fn -> OpenDesignClient.list_agents(port) end)
        skills = fetch_list(fn -> OpenDesignClient.list_skills(port) end)
        design_systems = fetch_list(fn -> OpenDesignClient.list_design_systems(port) end)
        projects = fetch_list(fn -> OpenDesignClient.list_projects(port) end)

        %{
          reachable: true,
          version: version,
          agents: agents,
          skill_count: length(skills),
          design_system_count: length(design_systems),
          project_count: length(projects),
          last_checked: now,
          port: port
        }

      {:error, _} ->
        %{
          reachable: false,
          version: nil,
          agents: [],
          skill_count: 0,
          design_system_count: 0,
          project_count: 0,
          last_checked: now,
          port: port
        }
    end
  end

  @spec fetch_list((-> {:ok, list()} | {:error, term()})) :: list()
  defp fetch_list(fun) do
    case fun.() do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end
end
