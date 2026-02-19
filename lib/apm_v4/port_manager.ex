defmodule ApmV4.PortManager do
  @moduledoc """
  GenServer that manages port allocation across projects.
  Scans session files for project configurations, detects port usage from
  config files, finds active ports via lsof, and resolves clashes.
  """
  use GenServer
  require Logger

  @server __MODULE__
  @sessions_dir Path.expand("~/Developer/ccem/apm/sessions")

  @namespace_ranges %{
    web: 3000..3999,
    api: 4000..4999,
    service: 5000..6999,
    tool: 7000..9999
  }

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @server)
  end

  def get_port_map, do: GenServer.call(@server, :get_port_map)
  def scan_active_ports, do: GenServer.call(@server, :scan_active_ports, 15_000)
  def detect_clashes, do: GenServer.call(@server, :detect_clashes)

  def assign_port(namespace) when namespace in [:web, :api, :service, :tool] do
    GenServer.call(@server, {:assign_port, namespace})
  end

  def assign_port(project_name) when is_binary(project_name) do
    GenServer.call(@server, {:assign_port_for_project, project_name})
  end

  def get_port_ranges, do: @namespace_ranges

  # Server Callbacks

  @impl true
  def init(_opts) do
    Logger.info("PortManager starting...")
    {:ok, %{port_map: %{}, active_ports: %{}, last_scan: nil}, {:continue, :initial_scan}}
  end

  @impl true
  def handle_continue(:initial_scan, state) do
    port_map = build_port_map()
    active = do_scan_active_ports()
    Logger.info("PortManager: #{map_size(port_map)} configured, #{map_size(active)} active")
    {:noreply, %{state | port_map: port_map, active_ports: active, last_scan: DateTime.utc_now()}}
  end

  @impl true
  def handle_call(:get_port_map, _from, state), do: {:reply, state.port_map, state}

  @impl true
  def handle_call(:scan_active_ports, _from, state) do
    active = do_scan_active_ports()
    {:reply, active, %{state | active_ports: active, last_scan: DateTime.utc_now()}}
  end

  @impl true
  def handle_call(:detect_clashes, _from, state) do
    clashes = do_detect_clashes(state.port_map)
    {:reply, clashes, state}
  end

  @impl true
  def handle_call({:assign_port, namespace}, _from, state) do
    range = Map.fetch!(@namespace_ranges, namespace)
    used = MapSet.new(Map.keys(state.active_ports))

    result =
      Enum.find(range, fn port -> not MapSet.member?(used, port) end)
      |> case do
        nil -> {:error, :no_available_port}
        port -> {:ok, port}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:assign_port_for_project, _project_name}, _from, state) do
    # Default to web namespace
    range = Map.fetch!(@namespace_ranges, :web)
    used = MapSet.new(Map.keys(state.active_ports))

    result =
      Enum.find(range, fn port -> not MapSet.member?(used, port) end)
      |> case do
        nil -> {:error, :no_available_port}
        port -> {:ok, port}
      end

    {:reply, result, state}
  end

  # Private

  defp build_port_map do
    session_files()
    |> Enum.flat_map(&extract_ports_from_session/1)
    |> Enum.into(%{})
  end

  defp session_files do
    case File.ls(@sessions_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.map(&Path.join(@sessions_dir, &1))
      {:error, _} -> []
    end
  end

  defp extract_ports_from_session(path) do
    with {:ok, content} <- File.read(path),
         {:ok, data} <- Jason.decode(content) do
      root = data["project_root"] || data["working_directory"]
      name = data["project_name"] || Path.basename(root || "unknown")
      if root, do: detect_ports(root, name), else: []
    else
      _ -> []
    end
  end

  defp detect_ports(root, name) do
    [&detect_env/1, &detect_pkg_json/1, &detect_next_config/1, &detect_dev_exs/1]
    |> Enum.flat_map(fn d -> d.(root) end)
    |> Enum.map(fn port ->
      {port, %{project: name, root: root, namespace: categorize(port), active: false}}
    end)
  end

  defp detect_env(root) do
    with {:ok, c} <- File.read(Path.join(root, ".env")),
         [_, p] <- Regex.run(~r/^PORT=(\d+)/m, c),
         {port, _} <- Integer.parse(p), do: [port], else: (_ -> [])
  end

  defp detect_pkg_json(root) do
    with {:ok, c} <- File.read(Path.join(root, "package.json")) do
      Regex.scan(~r/(?:--port|-p)\s+(\d+)/, c)
      |> Enum.map(fn [_, p] -> String.to_integer(p) end)
    else
      _ -> []
    end
  end

  defp detect_next_config(root) do
    ["next.config.js", "next.config.mjs", "next.config.ts"]
    |> Enum.flat_map(fn f ->
      with {:ok, c} <- File.read(Path.join(root, f)),
           [_, p] <- Regex.run(~r/port:\s*(\d+)/, c),
           do: [String.to_integer(p)], else: (_ -> [])
    end)
  end

  defp detect_dev_exs(root) do
    with {:ok, c} <- File.read(Path.join(root, "config/dev.exs")),
         [_, p] <- Regex.run(~r/port:\s*(\d+)/, c),
         do: [String.to_integer(p)], else: (_ -> [])
  end

  defp categorize(port) when port in 3000..3999, do: :web
  defp categorize(port) when port in 4000..4999, do: :api
  defp categorize(port) when port in 5000..6999, do: :service
  defp categorize(port) when port in 7000..9999, do: :tool
  defp categorize(_), do: :other

  defp do_scan_active_ports do
    case System.cmd("lsof", ["-iTCP", "-sTCP:LISTEN", "-P", "-n"], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.drop(1)
        |> Enum.reduce(%{}, fn line, acc ->
          parts = String.split(line, ~r/\s+/)
          with [cmd, pid_s | _] <- parts,
               {pid, _} <- Integer.parse(pid_s),
               [_, port_s] <- Regex.run(~r/:(\d+)$/, line),
               {port, _} <- Integer.parse(port_s) do
            Map.put(acc, port, %{pid: pid, command: cmd, namespace: categorize(port)})
          else
            _ -> acc
          end
        end)
      _ -> %{}
    end
  end

  defp do_detect_clashes(port_map) do
    port_map
    |> Enum.group_by(fn {port, _} -> port end, fn {_, info} -> info.project end)
    |> Enum.filter(fn {_, projects} -> length(projects) > 1 end)
    |> Enum.map(fn {port, projects} -> %{port: port, projects: projects} end)
  end
end
