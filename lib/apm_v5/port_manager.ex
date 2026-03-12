defmodule ApmV5.PortManager do
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

  @doc "Returns full project configurations with all detected ports, config files, and metadata."
  def get_project_configs, do: GenServer.call(@server, :get_project_configs)

  @doc "Suggest a remediation plan for a specific port clash."
  def suggest_remediation(port), do: GenServer.call(@server, {:suggest_remediation, port})

  @doc "Reassign a project to a new port in its namespace, updating the config file."
  def reassign_port(project_name, new_port), do: GenServer.call(@server, {:reassign_port, project_name, new_port})

  @doc "Set a project's primary port and ownership in apm_config.json."
  def set_primary_port(project_name, port, ownership \\ "shared") do
    GenServer.call(@server, {:set_primary_port, project_name, port, ownership})
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    Logger.info("PortManager starting...")
    {:ok, %{port_map: %{}, active_ports: %{}, project_configs: %{}, last_scan: nil}, {:continue, :initial_scan}}
  end

  @impl true
  def handle_continue(:initial_scan, state) do
    project_configs = build_project_configs()
    port_map = port_map_from_configs(project_configs)
    active = do_scan_active_ports()
    Logger.info("PortManager: #{map_size(port_map)} configured, #{map_size(active)} active")
    {:noreply, %{state | port_map: port_map, active_ports: active, project_configs: project_configs, last_scan: DateTime.utc_now()}}
  end

  @impl true
  def handle_call(:get_port_map, _from, state), do: {:reply, state.port_map, state}

  @impl true
  def handle_call(:get_project_configs, _from, state) do
    # Enrich with active port status and primary_port/ownership from apm_config
    enriched =
      Enum.map(state.project_configs, fn {name, config} ->
        ports_with_status =
          Enum.map(config.ports, fn port_info ->
            active_info = Map.get(state.active_ports, port_info.port)
            Map.put(port_info, :active, active_info != nil)
            |> Map.put(:pid, if(active_info, do: active_info.pid))
            |> Map.put(:command, if(active_info, do: active_info.command))
            |> Map.put(:cwd, if(active_info, do: active_info[:cwd]))
            |> Map.put(:full_command, if(active_info, do: active_info[:full_command]))
            |> Map.put(:server_type, if(active_info, do: active_info[:server_type]))
          end)

        # Merge primary_port and port_ownership from apm_config.json
        apm_project = ApmV5.ConfigLoader.get_project(name)
        primary_port = if apm_project, do: apm_project["primary_port"]
        port_ownership = if apm_project, do: apm_project["port_ownership"], else: "shared"

        enriched_config =
          config
          |> Map.put(:ports, ports_with_status)
          |> Map.put(:primary_port, primary_port)
          |> Map.put(:port_ownership, port_ownership)

        {name, enriched_config}
      end)
      |> Enum.into(%{})
    {:reply, enriched, state}
  end

  @impl true
  def handle_call({:suggest_remediation, port}, _from, state) do
    # Find which projects claim this port
    claimants =
      state.project_configs
      |> Enum.filter(fn {_name, config} ->
        Enum.any?(config.ports, &(&1.port == port))
      end)
      |> Enum.map(fn {name, config} ->
        port_info = Enum.find(config.ports, &(&1.port == port))
        %{project: name, source: port_info.source, file: port_info.file, namespace: categorize(port)}
      end)

    ns = categorize(port)
    range = Map.get(@namespace_ranges, ns, 3000..3999)
    used = MapSet.new(Map.keys(state.port_map))

    # Find 3 available alternatives in the same namespace
    alternatives =
      range
      |> Enum.reject(&MapSet.member?(used, &1))
      |> Enum.reject(&Map.has_key?(state.active_ports, &1))
      |> Enum.take(3)

    suggestion = %{
      port: port,
      claimants: claimants,
      alternatives: alternatives,
      recommendation: build_recommendation(claimants, alternatives)
    }
    {:reply, suggestion, state}
  end

  @impl true
  def handle_call({:reassign_port, project_name, new_port}, _from, state) do
    case Map.get(state.project_configs, project_name) do
      nil ->
        {:reply, {:error, :project_not_found}, state}
      _config ->
        # For now, just update in-memory state. Config file editing would be phase 2.
        project_configs = build_project_configs()
        port_map = port_map_from_configs(project_configs)
        {:reply, {:ok, new_port}, %{state | project_configs: project_configs, port_map: port_map}}
    end
  end

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
  def handle_call({:set_primary_port, project_name, port, ownership}, _from, state) do
    case ApmV5.ConfigLoader.update_project(%{
      "name" => project_name,
      "primary_port" => port,
      "port_ownership" => ownership
    }) do
      {:ok, _config} ->
        # Rebuild state to pick up changes
        project_configs = build_project_configs()
        port_map = port_map_from_configs(project_configs)
        {:reply, :ok, %{state | project_configs: project_configs, port_map: port_map}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
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

  defp build_project_configs do
    session_files()
    |> Enum.map(&extract_project_config/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.into(%{})
  end

  defp port_map_from_configs(project_configs) do
    project_configs
    |> Enum.flat_map(fn {name, config} ->
      Enum.map(config.ports, fn port_info ->
        {port_info.port, %{project: name, root: config.root, namespace: port_info.namespace, active: false}}
      end)
    end)
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

  defp extract_project_config(path) do
    with {:ok, content} <- File.read(path),
         {:ok, data} <- Jason.decode(content) do
      root = data["project_root"] || data["working_directory"]
      name = data["project_name"] || Path.basename(root || "unknown")
      if root do
        ports = detect_ports_detailed(root)
        config_files = detect_config_files(root)
        stack = detect_stack(root)

        {name, %{
          root: root,
          name: name,
          session_file: path,
          ports: ports,
          config_files: config_files,
          stack: stack,
          session_data: Map.take(data, ["session_id", "started_at", "project_name"])
        }}
      end
    else
      _ -> nil
    end
  end

  defp detect_ports_detailed(root) do
    env_ports = detect_env_detailed(root)
    pkg_ports = detect_pkg_json_detailed(root)
    next_ports = detect_next_config_detailed(root)
    elixir_ports = detect_dev_exs_detailed(root)
    env_ports ++ pkg_ports ++ next_ports ++ elixir_ports
  end

  defp detect_env_detailed(root) do
    path = Path.join(root, ".env")
    with {:ok, c} <- File.read(path),
         [_, p] <- Regex.run(~r/^PORT=(\d+)/m, c),
         {port, _} <- Integer.parse(p) do
      [%{port: port, source: :env, file: ".env", namespace: categorize(port)}]
    else
      _ -> []
    end
  end

  defp detect_pkg_json_detailed(root) do
    path = Path.join(root, "package.json")
    with {:ok, c} <- File.read(path) do
      Regex.scan(~r/(?:--port|-p)\s+(\d+)/, c)
      |> Enum.map(fn [_, p] ->
        port = String.to_integer(p)
        %{port: port, source: :package_json, file: "package.json", namespace: categorize(port)}
      end)
    else
      _ -> []
    end
  end

  defp detect_next_config_detailed(root) do
    ["next.config.js", "next.config.mjs", "next.config.ts"]
    |> Enum.flat_map(fn f ->
      with {:ok, c} <- File.read(Path.join(root, f)),
           [_, p] <- Regex.run(~r/port:\s*(\d+)/, c) do
        port = String.to_integer(p)
        [%{port: port, source: :next_config, file: f, namespace: categorize(port)}]
      else
        _ -> []
      end
    end)
  end

  defp detect_dev_exs_detailed(root) do
    with {:ok, c} <- File.read(Path.join(root, "config/dev.exs")),
         [_, p] <- Regex.run(~r/port:\s*(\d+)/, c) do
      port = String.to_integer(p)
      [%{port: port, source: :dev_exs, file: "config/dev.exs", namespace: categorize(port)}]
    else
      _ -> []
    end
  end

  defp detect_config_files(root) do
    candidates = [
      ".env", ".env.local", ".env.development",
      "package.json", "mix.exs",
      "next.config.js", "next.config.mjs", "next.config.ts",
      "config/dev.exs", "config/config.exs", "config/runtime.exs",
      "docker-compose.yml", "docker-compose.yaml",
      "Procfile", "fly.toml", "vercel.json"
    ]

    Enum.filter(candidates, fn f -> File.exists?(Path.join(root, f)) end)
  end

  defp detect_stack(root) do
    cond do
      File.exists?(Path.join(root, "mix.exs")) -> :elixir
      File.exists?(Path.join(root, "next.config.js")) or File.exists?(Path.join(root, "next.config.mjs")) or File.exists?(Path.join(root, "next.config.ts")) -> :nextjs
      File.exists?(Path.join(root, "package.json")) -> :node
      File.exists?(Path.join(root, "Cargo.toml")) -> :rust
      File.exists?(Path.join(root, "go.mod")) -> :go
      File.exists?(Path.join(root, "requirements.txt")) or File.exists?(Path.join(root, "pyproject.toml")) -> :python
      true -> :unknown
    end
  end

  defp build_recommendation(claimants, alternatives) do
    # Check if any claimant has exclusive ownership
    exclusive_owner =
      Enum.find(claimants, fn c ->
        project = ApmV5.ConfigLoader.get_project(c.project)
        project && project["port_ownership"] == "exclusive"
      end)

    case {length(claimants), alternatives, exclusive_owner} do
      {1, _, _} -> "Single claimant - no conflict"
      {_, [], _} -> "No available ports in namespace - consider expanding range"
      {_, [alt | _], %{project: owner}} ->
        # Owner stays, everyone else moves
        moveables = Enum.reject(claimants, &(&1.project == owner))
        names = Enum.map_join(moveables, ", ", & &1.project)
        "#{owner} has exclusive ownership. Move #{names} to port #{alt}+"
      {2, [alt | _], nil} ->
        moveable = List.last(claimants)
        "Move #{moveable.project} to port #{alt} (update #{moveable.file})"
      {n, [alt | _], nil} ->
        "#{n} projects claim this port. Suggest moving all but the primary to #{alt}+"
    end
  end


  defp categorize(port) when port in 3000..3999, do: :web
  defp categorize(port) when port in 4000..4999, do: :api
  defp categorize(port) when port in 5000..6999, do: :service
  defp categorize(port) when port in 7000..9999, do: :tool
  defp categorize(_), do: :other

  defp do_scan_active_ports do
    lsof = System.find_executable("lsof") || "/usr/sbin/lsof"

    case System.cmd(lsof, ["-iTCP", "-sTCP:LISTEN", "-P", "-n"], stderr_to_stdout: true) do
      {output, 0} ->
        raw_ports =
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

        # Enrich each active port with process details: cwd, full command, project match
        Enum.map(raw_ports, fn {port, info} ->
          enriched = enrich_process_info(info.pid, info.command)
          {port, Map.merge(info, enriched)}
        end)
        |> Enum.into(%{})
      _ -> %{}
    end
  end

  defp enrich_process_info(pid, command) do
    cwd = get_process_cwd(pid)
    full_cmd = get_full_command(pid)
    server_type = identify_server_type(command, full_cmd)

    %{
      cwd: cwd,
      full_command: full_cmd,
      server_type: server_type
    }
  end

  defp get_process_cwd(pid) do
    lsof = System.find_executable("lsof") || "/usr/sbin/lsof"
    # Use lsof -p PID -Fn -d cwd to get the current working directory
    case System.cmd(lsof, ["-p", to_string(pid), "-Fn", "-d", "cwd"], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.find_value(fn line ->
          if String.starts_with?(line, "n") and not String.starts_with?(line, "n ") do
            String.slice(line, 1..-1//1)
          end
        end)
      _ -> nil
    end
  end

  defp get_full_command(pid) do
    case System.cmd("ps", ["-p", to_string(pid), "-o", "command="], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      _ -> nil
    end
  end

  defp identify_server_type(command, full_cmd) do
    cmd_lower = String.downcase(command || "")
    full_lower = String.downcase(full_cmd || "")

    cond do
      cmd_lower == "beam.smp" or String.contains?(full_lower, "phx.server") -> :phoenix
      cmd_lower == "beam.smp" or String.contains?(full_lower, "mix") -> :elixir
      String.contains?(full_lower, "next-server") or String.contains?(full_lower, "next dev") -> :nextjs
      String.contains?(full_lower, "vite") -> :vite
      String.contains?(full_lower, "webpack") -> :webpack
      String.contains?(full_lower, "npm") or String.contains?(full_lower, "npx") -> :node_script
      String.contains?(full_lower, "uvicorn") or String.contains?(full_lower, "gunicorn") -> :python_web
      String.contains?(full_lower, "flask") or String.contains?(full_lower, "django") -> :python_web
      String.contains?(full_lower, "ruby") or String.contains?(full_lower, "rails") -> :rails
      cmd_lower == "node" -> :node
      cmd_lower == "python3" or cmd_lower == "python" -> :python
      cmd_lower == "docker" or String.contains?(full_lower, "docker") -> :docker
      cmd_lower == "postgres" or cmd_lower == "postmaster" -> :postgres
      cmd_lower == "redis-server" -> :redis
      true -> :unknown
    end
  end

  defp do_detect_clashes(port_map) do
    port_map
    |> Enum.group_by(fn {port, _} -> port end, fn {_, info} -> info.project end)
    |> Enum.filter(fn {_, projects} -> length(projects) > 1 end)
    |> Enum.map(fn {port, projects} ->
      # Check if any project has exclusive ownership of this port
      owner = find_exclusive_owner(port)

      case owner do
        nil ->
          %{port: port, projects: projects, owner: nil, should_move: []}

        owner_name ->
          should_move = Enum.reject(projects, &(&1 == owner_name))
          %{port: port, projects: projects, owner: owner_name, should_move: should_move}
      end
    end)
  end

  defp find_exclusive_owner(port) do
    config = ApmV5.ConfigLoader.get_config()
    projects = Map.get(config, "projects", [])

    Enum.find_value(projects, fn p ->
      if p["primary_port"] == port and p["port_ownership"] == "exclusive" do
        p["name"]
      end
    end)
  end
end
