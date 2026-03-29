defmodule ApmV5.Tunnel.Client do
  @moduledoc """
  Outbound WebSocket client that dials the CCEM Relay on Azure.

  Reads TUNNEL_RELAY_URL and TUNNEL_SECRET at startup. If TUNNEL_RELAY_URL
  is not set the GenServer starts but stays idle (tunnel disabled).

  Flow:
    1. Open `:gun` WebSocket to wss://<relay>/ws?vsn=2.0.0
    2. Join Phoenix channel "tunnel:local" with secret
    3. Receive "http_request" push frames from relay
    4. Forward each request to the correct local server via :httpc (Task, non-blocking)
       - `target_project` field in the payload selects the destination port
       - "apm" (default) → localhost:3032
       - Any other project → resolved via ApmV5.PortManager
    5. Send "http_response" frame back through same WebSocket
    6. Heartbeat every 30s; auto-reconnect on drop
    7. On channel join: send project manifest to relay; refresh every 60s
  """
  use GenServer
  require Logger

  @heartbeat_ms 30_000
  @reconnect_ms 5_000
  @http_timeout_ms 12_000

  # Public API ------------------------------------------------------------------

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec connected?() :: boolean()
  def connected? do
    case GenServer.call(__MODULE__, :connected?, 5_000) do
      result -> result
    end
  rescue
    _ -> false
  end

  # GenServer callbacks ---------------------------------------------------------

  @impl true
  def init(_opts) do
    Application.ensure_all_started(:inets)
    Application.ensure_all_started(:ssl)

    relay_url = System.get_env("TUNNEL_RELAY_URL")

    if relay_url do
      Logger.info("[Tunnel.Client] Relay URL configured: #{relay_url} — connecting...")
      send(self(), {:connect, relay_url})
    else
      Logger.info("[Tunnel.Client] TUNNEL_RELAY_URL not set — tunnel disabled")
    end

    {:ok, %{relay_url: relay_url, conn: nil, stream_ref: nil, connected: false, ref_counter: 0}}
  end

  @impl true
  def handle_call(:connected?, _from, state), do: {:reply, state.connected, state}

  @impl true
  def handle_info({:connect, url}, state) do
    case open_ws(url) do
      {:ok, conn, stream_ref} ->
        Logger.debug("[Tunnel.Client] Gun connection open, awaiting WS upgrade")
        {:noreply, %{state | conn: conn, stream_ref: stream_ref}}

      {:error, reason} ->
        Logger.warning("[Tunnel.Client] Connection failed: #{inspect(reason)} — retry in #{@reconnect_ms}ms")
        Process.send_after(self(), {:connect, url}, @reconnect_ms)
        {:noreply, %{state | conn: nil, stream_ref: nil, connected: false}}
    end
  end

  # WebSocket upgrade OK — join the channel
  def handle_info({:gun_upgrade, conn, stream_ref, ["websocket"], _headers}, state)
      when conn == state.conn and stream_ref == state.stream_ref do
    Logger.info("[Tunnel.Client] WebSocket upgraded — joining tunnel:local")
    join = phoenix_frame("1", "1", "tunnel:local", "phx_join", %{"secret" => tunnel_secret()})
    :gun.ws_send(conn, stream_ref, {:text, join})
    Process.send_after(self(), :heartbeat, @heartbeat_ms)
    {:noreply, state}
  end

  # Inbound text frame from relay
  def handle_info({:gun_ws, conn, _ref, {:text, data}}, state) when conn == state.conn do
    {:noreply, handle_frame(Jason.decode(data), state)}
  end

  # WebSocket close frame
  def handle_info({:gun_ws, _conn, _ref, {:close, code, reason}}, state) do
    Logger.warning("[Tunnel.Client] WS closed #{code}: #{reason}")
    schedule_reconnect(state)
  end

  # Connection down
  def handle_info({:gun_down, conn, _proto, reason, _killed}, state) when conn == state.conn do
    Logger.warning("[Tunnel.Client] Connection down: #{inspect(reason)}")
    schedule_reconnect(state)
  end

  # {:closed, :normal} on a stream is expected during WS upgrade — not a fatal error
  def handle_info({:gun_error, _conn, _stream, {:closed, :normal}}, state), do: {:noreply, state}

  # Gun error — any other error on the connection is fatal, reconnect
  def handle_info({:gun_error, conn, _stream, reason}, state) when conn == state.conn do
    Logger.warning("[Tunnel.Client] Gun error: #{inspect(reason)}")
    if state.conn, do: :gun.close(state.conn)
    schedule_reconnect(state)
  end

  # Heartbeat
  def handle_info(:heartbeat, %{connected: true, conn: conn, stream_ref: sr} = state)
      when conn != nil do
    hb = phoenix_frame(nil, "hb", "phoenix", "heartbeat", %{})
    :gun.ws_send(conn, sr, {:text, hb})
    Process.send_after(self(), :heartbeat, @heartbeat_ms)
    {:noreply, state}
  end

  def handle_info(:heartbeat, state) do
    # Not connected yet, reschedule
    Process.send_after(self(), :heartbeat, @heartbeat_ms)
    {:noreply, state}
  end

  def handle_info(:refresh_project_manifest, %{connected: true, conn: conn, stream_ref: sr} = state)
      when conn != nil do
    Task.start(fn -> send_project_manifest(conn, sr) end)
    Process.send_after(self(), :refresh_project_manifest, 60_000)
    {:noreply, state}
  end

  def handle_info(:refresh_project_manifest, state) do
    Process.send_after(self(), :refresh_project_manifest, 60_000)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Frame dispatch --------------------------------------------------------------

  defp handle_frame({:ok, [_jr, _r, "tunnel:local", "phx_reply", %{"status" => "ok"}]}, state) do
    Logger.info("[Tunnel.Client] Joined tunnel:local — relay tunnel active")

    # Fire APM notification (fire-and-forget)
    Task.start(fn ->
      :httpc.request(
        :post,
        {~c"http://localhost:3032/api/notify",
         [{~c"content-type", ~c"application/json"}],
         ~c"application/json",
         Jason.encode!(%{
           title: "Tunnel Active",
           message: "CCEM relay connected — remote access enabled",
           type: "success",
           category: "system"
         })},
        [{:timeout, 3_000}],
        []
      )
    end)

    # Send project manifest to relay after channel join settles
    conn = state.conn
    stream_ref = state.stream_ref

    Task.start(fn ->
      Process.sleep(1_000)
      send_project_manifest(conn, stream_ref)
    end)

    # Schedule periodic project manifest refresh
    Process.send_after(self(), :refresh_project_manifest, 60_000)

    %{state | connected: true}
  end

  defp handle_frame({:ok, [_jr, _r, "tunnel:local", "http_request", payload]}, state) do
    conn = state.conn
    stream_ref = state.stream_ref
    Task.start(fn -> proxy_request(conn, stream_ref, payload) end)
    state
  end

  defp handle_frame({:ok, [_jr, _r, "phoenix", "phx_reply", _]}, state), do: state

  defp handle_frame({:ok, msg}, state) do
    Logger.debug("[Tunnel.Client] Unhandled frame: #{inspect(msg)}")
    state
  end

  defp handle_frame({:error, reason}, state) do
    Logger.warning("[Tunnel.Client] Frame decode error: #{inspect(reason)}")
    state
  end

  # HTTP proxy ------------------------------------------------------------------

  defp proxy_request(gun_conn, stream_ref, payload) do
    request_id = Map.get(payload, "request_id", "unknown")
    method = Map.get(payload, "method", "GET") |> String.downcase() |> String.to_atom()
    path = Map.get(payload, "path", "/")
    query = Map.get(payload, "query_string", "")
    headers = Map.get(payload, "headers", [])
    body = Map.get(payload, "body", "")
    target_project = Map.get(payload, "target_project", "apm")

    port = resolve_project_port(target_project)

    full_path = if query in [nil, ""], do: path, else: "#{path}?#{query}"
    url = String.to_charlist("http://localhost:#{port}#{full_path}")
    httpc_headers = Enum.map(headers, fn
      [k, v] -> {String.to_charlist(to_string(k)), String.to_charlist(to_string(v))}
      {k, v} -> {String.to_charlist(to_string(k)), String.to_charlist(to_string(v))}
    end)

    result =
      case method do
        :get ->
          :httpc.request(:get, {url, httpc_headers}, [{:timeout, @http_timeout_ms}], [])

        :delete ->
          :httpc.request(:delete, {url, httpc_headers}, [{:timeout, @http_timeout_ms}], [])

        m when m in [:post, :put, :patch] ->
          ct = find_content_type(headers)
          :httpc.request(m, {url, httpc_headers, String.to_charlist(ct), body},
            [{:timeout, @http_timeout_ms}], [])

        _ ->
          {:error, :unsupported_method}
      end

    response =
      case result do
        {:ok, {{_vsn, status, _reason}, resp_headers, resp_body}} ->
          %{
            "request_id" => request_id,
            "status" => status,
            "headers" => Enum.map(resp_headers, fn {k, v} -> [to_string(k), to_string(v)] end),
            "body" => to_string(resp_body)
          }

        {:error, reason} ->
          Logger.warning("[Tunnel.Client] Proxy error for #{request_id}: #{inspect(reason)}")
          %{
            "request_id" => request_id,
            "status" => 502,
            "headers" => [],
            "body" => Jason.encode!(%{error: "proxy_error", detail: inspect(reason)})
          }
      end

    frame = phoenix_frame("1", nil, "tunnel:local", "http_response", response)
    :gun.ws_send(gun_conn, stream_ref, {:text, frame})
  end

  # Helpers ---------------------------------------------------------------------

  defp open_ws(url) do
    uri = URI.parse(url)
    host = String.to_charlist(uri.host)
    port = uri.port || if(uri.scheme == "wss", do: 443, else: 80)
    transport = if uri.scheme in ["wss", "https"], do: :tls, else: :tcp
    # Phoenix WebSocket transport is at <socket_path>/websocket
    base_path = uri.path || "/ws"
    ws_path = if String.ends_with?(base_path, "/websocket"), do: base_path, else: base_path <> "/websocket"
    path = String.to_charlist(ws_path <> "?vsn=2.0.0")

    tls_opts =
      if transport == :tls do
        [{:verify, :verify_peer}, {:cacerts, :public_key.cacerts_get()},
         {:server_name_indication, host}]
      else
        []
      end

    gun_opts = %{
      protocols: [:http],
      transport: transport,
      tls_opts: tls_opts,
      connect_timeout: 10_000
    }

    case :gun.open(host, port, gun_opts) do
      {:ok, conn} ->
        case :gun.await_up(conn, 10_000) do
          {:ok, :http} ->
            stream_ref = :gun.ws_upgrade(conn, path, [{~c"user-agent", ~c"ccem-apm-tunnel/1.0"}])
            {:ok, conn, stream_ref}

          {:error, reason} ->
            :gun.close(conn)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp schedule_reconnect(state) do
    if state.conn do
      try do
        :gun.close(state.conn)
      catch
        :exit, _ -> :ok
      end
    end
    if state.relay_url do
      Process.send_after(self(), {:connect, state.relay_url}, @reconnect_ms)
    end
    {:noreply, %{state | conn: nil, stream_ref: nil, connected: false}}
  end

  defp phoenix_frame(join_ref, ref, topic, event, payload) do
    Jason.encode!([join_ref, ref, topic, event, payload])
  end

  defp find_content_type(headers) do
    Enum.find_value(headers, "application/octet-stream", fn
      {"content-type", v} -> v
      {"Content-Type", v} -> v
      _ -> false
    end)
  end

  defp tunnel_secret, do: System.get_env("TUNNEL_SECRET", "")

  # Multi-project port resolution -----------------------------------------------

  @doc false
  @spec resolve_project_port(String.t() | nil) :: pos_integer()
  defp resolve_project_port(project_name) when project_name in [nil, "apm"], do: 3032

  defp resolve_project_port(project_name) do
    configs = ApmV5.PortManager.get_project_configs()

    case Map.get(configs, project_name) do
      %{primary_port: port} when is_integer(port) ->
        port

      _ ->
        # Fall back to scanning active ports
        port_map = ApmV5.PortManager.get_port_map()

        result =
          Enum.find(port_map, fn {_port, info} ->
            Map.get(info, :project) == project_name or
              Map.get(info, "project") == project_name
          end)

        case result do
          {port, _info} -> port
          nil -> 3032
        end
    end
  end

  @spec send_project_manifest(term(), term()) :: :ok
  defp send_project_manifest(conn, stream_ref) do
    configs = ApmV5.PortManager.get_project_configs()
    active_port_map = ApmV5.PortManager.get_port_map()

    # Build project → port map from configs (only real integer ports)
    config_ports =
      configs
      |> Enum.filter(fn {_name, cfg} -> is_integer(Map.get(cfg, :primary_port)) end)
      |> Enum.map(fn {name, cfg} -> {name, Map.get(cfg, :primary_port)} end)
      |> Map.new()

    # Augment with active ports from lsof scan
    active_ports =
      active_port_map
      |> Enum.filter(fn {_port, info} -> Map.get(info, :active, false) end)
      |> Enum.flat_map(fn {port, info} ->
        project = Map.get(info, :project) || Map.get(info, "project")
        if project, do: [{project, port}], else: []
      end)
      |> Map.new()

    # Merge: config wins over scan; always include APM itself
    project_ports =
      Map.merge(active_ports, config_ports)
      |> Map.put("apm", 3032)

    frame =
      phoenix_frame("1", nil, "tunnel:local", "register_projects", %{
        "projects" => project_ports
      })

    :gun.ws_send(conn, stream_ref, {:text, frame})
    Logger.info("[Tunnel.Client] Sent project manifest: #{map_size(project_ports)} projects")
    :ok
  end
end
