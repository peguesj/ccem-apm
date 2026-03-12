defmodule ApmV5.AgentDiscovery do
  @moduledoc """
  GenServer that scans tasks_dir/*.output files every 5 seconds
  and auto-registers discovered agents. Port of v3's discover_agents()
  at monitor.py line 77.
  """

  use GenServer

  alias ApmV5.AgentRegistry
  alias ApmV5.ConfigLoader

  @poll_interval :timer.seconds(5)

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Trigger a manual discovery scan. Returns list of discovered agents."
  @spec discover_now() :: [map()]
  def discover_now do
    GenServer.call(__MODULE__, :discover_now, 10_000)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    schedule_poll()

    {:ok,
     %{
       known_files: MapSet.new(),
       file_sizes: %{}
     }}
  end

  @impl true
  def handle_info(:poll, state) do
    state = scan_all_projects(state)
    schedule_poll()
    {:noreply, state}
  end

  @impl true
  def handle_call(:discover_now, _from, state) do
    state = scan_all_projects(state)

    agents = AgentRegistry.list_agents()
    discovered = Enum.filter(agents, fn a -> a.status == "discovered" end)

    {:reply, discovered, state}
  end

  # --- Private ---

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval)
  end

  defp scan_all_projects(state) do
    config = safe_get_config()
    projects = Map.get(config, "projects", [])

    Enum.reduce(projects, state, fn project, acc ->
      tasks_dir = project["tasks_dir"]

      if tasks_dir && File.dir?(tasks_dir) do
        scan_tasks_dir(tasks_dir, project["name"], acc)
      else
        acc
      end
    end)
  end

  defp scan_tasks_dir(tasks_dir, project_name, state) do
    case File.ls(tasks_dir) do
      {:ok, files} ->
        output_files = Enum.filter(files, &String.ends_with?(&1, ".output"))

        Enum.reduce(output_files, state, fn file, acc ->
          full_path = Path.join(tasks_dir, file)
          process_output_file(full_path, file, project_name, acc)
        end)

      {:error, _} ->
        state
    end
  end

  defp process_output_file(path, filename, project_name, state) do
    agent_id = filename |> String.trim_trailing(".output")

    case File.stat(path) do
      {:ok, %{size: size}} ->
        prev_size = Map.get(state.file_sizes, path, 0)
        is_new = !MapSet.member?(state.known_files, path)

        if is_new || size != prev_size do
          {name, status} = parse_output_file(path)

          agent_status = if status == "completed", do: "completed", else: "discovered"

          AgentRegistry.register_agent(
            agent_id,
            %{
              name: name || agent_id,
              status: agent_status,
              tier: 1,
              metadata: %{"source" => "discovery", "output_file" => path}
            },
            project_name
          )

          if is_new do
            AgentRegistry.add_notification(%{
              title: "Agent discovered",
              message: "#{name || agent_id} (#{project_name})",
              level: "info"
            })
          end

          if status == "completed" && prev_size > 0 && size != prev_size do
            AgentRegistry.add_notification(%{
              title: "Agent completed",
              message: "#{name || agent_id} finished",
              level: "success"
            })
          end

          Phoenix.PubSub.broadcast(
            ApmV5.PubSub,
            "apm:agents",
            {:agent_discovered, agent_id, project_name}
          )

          %{
            state
            | known_files: MapSet.put(state.known_files, path),
              file_sizes: Map.put(state.file_sizes, path, size)
          }
        else
          state
        end

      {:error, _} ->
        state
    end
  end

  defp parse_output_file(path) do
    # Read tail of file for agent name and completion status
    case File.read(path) do
      {:ok, contents} ->
        lines =
          contents
          |> String.split("\n", trim: true)
          |> Enum.take(-20)

        name = extract_agent_name(lines)
        completed = Enum.any?(lines, &String.contains?(&1, "stop_reason"))

        status = if completed, do: "completed", else: "running"
        {name, status}

      {:error, _} ->
        {nil, "unknown"}
    end
  end

  defp extract_agent_name(lines) do
    Enum.find_value(lines, fn line ->
      case Jason.decode(line) do
        {:ok, %{"message" => %{"content" => content}}} when is_binary(content) ->
          if String.length(content) > 5, do: String.slice(content, 0, 50)

        {:ok, %{"type" => "assistant", "message" => %{"model" => _model}}} ->
          nil

        _ ->
          nil
      end
    end)
  end

  defp safe_get_config do
    try do
      ConfigLoader.get_config()
    catch
      :exit, _ -> %{"projects" => []}
    end
  end
end
