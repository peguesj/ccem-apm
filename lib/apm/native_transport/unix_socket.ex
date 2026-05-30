defmodule Apm.NativeTransport.UnixSocket do
  @moduledoc """
  Unix Domain Socket listener that accepts local client connections (CCEMHelper)
  and exchanges length-prefixed, ETF-encoded binary frames.

  ## Framing

  Each frame on the wire is:

      <<payload_size::32-big, payload::binary>>

  `payload` is `:erlang.term_to_binary(term, [:compressed])`. Peers decode with
  `:erlang.binary_to_term(payload, [:safe])`.

  ## Lifecycle

    * On `start_link/1` the socket file is removed (if stale) and re-created.
    * A pool of acceptor tasks serves clients concurrently.
    * Each connected client is tracked under `Apm.NativeTransport.ConnectionRegistry`
      so `ChannelBridge` (Wave 2) can push to specific subscribers.

  ## Telemetry

    * `[:apm, :native_transport, :connection, :accept]`
    * `[:apm, :native_transport, :connection, :close]`
    * `[:apm, :native_transport, :frame, :recv]` -- measurement `:bytes`
    * `[:apm, :native_transport, :frame, :send]` -- measurement `:bytes`
  """

  use GenServer
  require Logger

  @default_socket_path "/tmp/ccem-apm.sock"
  @acceptor_count 4

  ## Public API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Send a term to a connected client socket. Frames the payload and writes it.
  Returns `:ok` or `{:error, reason}`.
  """
  @spec send_frame(:gen_tcp.socket(), term()) :: :ok | {:error, term()}
  def send_frame(socket, term) do
    payload = :erlang.term_to_binary(term, [:compressed])
    frame = <<byte_size(payload)::32-big, payload::binary>>

    :telemetry.execute(
      [:apm, :native_transport, :frame, :send],
      %{bytes: byte_size(frame)},
      %{}
    )

    :gen_tcp.send(socket, frame)
  end

  @doc """
  Receive one framed term from a socket with the given timeout. Blocks until
  a full frame is read or the socket errors.
  """
  @spec recv_frame(:gen_tcp.socket(), timeout()) :: {:ok, term()} | {:error, term()}
  def recv_frame(socket, timeout \\ 5_000) do
    with {:ok, <<size::32-big>>} <- :gen_tcp.recv(socket, 4, timeout),
         {:ok, payload} <- :gen_tcp.recv(socket, size, timeout) do
      :telemetry.execute(
        [:apm, :native_transport, :frame, :recv],
        %{bytes: 4 + size},
        %{}
      )

      try do
        {:ok, :erlang.binary_to_term(payload, [:safe])}
      rescue
        e -> {:error, {:decode_failed, e}}
      end
    end
  end

  @doc "Return the current socket path."
  @spec socket_path() :: String.t()
  def socket_path do
    case Process.whereis(__MODULE__) do
      nil -> @default_socket_path
      pid -> GenServer.call(pid, :socket_path)
    end
  end

  ## GenServer callbacks

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, @default_socket_path)
    _ = File.rm(path)

    listen_opts = [
      :binary,
      {:packet, :raw},
      {:active, false},
      {:reuseaddr, true},
      {:ifaddr, {:local, path}}
    ]

    case :gen_tcp.listen(0, listen_opts) do
      {:ok, listen_socket} ->
        _ = File.chmod(path, 0o600)

        for i <- 1..@acceptor_count do
          id = i
          spawn_link(fn -> accept_loop(listen_socket, id) end)
        end

        Logger.info("NativeTransport.UnixSocket listening at #{path}")
        {:ok, %{listen_socket: listen_socket, path: path}}

      {:error, reason} ->
        Logger.error("NativeTransport.UnixSocket failed to listen at #{path}: #{inspect(reason)}")
        {:stop, {:listen_failed, reason}}
    end
  end

  @impl true
  def handle_call(:socket_path, _from, state), do: {:reply, state.path, state}

  @impl true
  def terminate(_reason, state) do
    _ = :gen_tcp.close(state.listen_socket)
    _ = File.rm(state.path)
    :ok
  end

  ## Acceptor

  defp accept_loop(listen_socket, id) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, client} ->
        :telemetry.execute(
          [:apm, :native_transport, :connection, :accept],
          %{count: 1},
          %{acceptor: id}
        )

        {:ok, _pid} =
          Task.Supervisor.start_child(
            Apm.ConcurrencyLayer.TaskSupervisor,
            fn -> client_loop(client) end
          )

        accept_loop(listen_socket, id)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        Logger.warning("UnixSocket accept error: #{inspect(reason)}")
        accept_loop(listen_socket, id)
    end
  end

  defp client_loop(socket) do
    case recv_frame(socket, :infinity) do
      {:ok, term} ->
        handle_client_frame(socket, term)
        client_loop(socket)

      {:error, :closed} ->
        :telemetry.execute(
          [:apm, :native_transport, :connection, :close],
          %{count: 1},
          %{reason: :closed}
        )

        :ok

      {:error, reason} ->
        :telemetry.execute(
          [:apm, :native_transport, :connection, :close],
          %{count: 1},
          %{reason: reason}
        )

        _ = :gen_tcp.close(socket)
        :ok
    end
  end

  # Default echo/ping handler. ChannelBridge (Wave 2) replaces this with
  # topic subscription routing.
  defp handle_client_frame(socket, {:ping, ref}) do
    send_frame(socket, {:pong, ref})
  end

  defp handle_client_frame(socket, {:hello, client_info}) do
    send_frame(socket, {:hello_ack, %{server: "apm", ts: System.system_time(:millisecond), client: client_info}})
  end

  defp handle_client_frame(_socket, _other), do: :ok
end
