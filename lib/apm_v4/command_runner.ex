defmodule ApmV4.CommandRunner do
  @moduledoc """
  GenServer for executing shell commands in specific project directories
  with timeout, output streaming via PubSub, and safety checks.
  """

  use GenServer

  @table :apm_commands_running
  @default_timeout :timer.seconds(30)
  @max_timeout :timer.seconds(120)

  @dangerous_patterns [
    ~r/rm\s+-rf\s+[~\/]/,
    ~r/sudo\s/,
    ~r/mkfs/,
    ~r/dd\s+if=/,
    ~r/>\s*\/dev\//,
    ~r/chmod\s+777\s+\//,
    ~r/curl\s.*\|\s*(ba)?sh/,
    ~r/wget\s.*\|\s*(ba)?sh/,
    ~r/\bprintenv\b/,
    ~r/\benv\b\s*$/,
    ~r/nc\s+-[elp]/,
    ~r/\/dev\/tcp\//,
    ~r/bash\s+-i\s+/
  ]

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Execute a command in the given environment's directory.
  Returns {exit_code, output} or {:error, reason}.
  """
  def exec(env_name, command, opts \\ []) do
    GenServer.call(__MODULE__, {:exec, env_name, command, opts}, @max_timeout + 5_000)
  end

  @doc "Kill a running command by request_id."
  def kill(request_id) do
    GenServer.call(__MODULE__, {:kill, request_id})
  end

  @doc "List currently running commands."
  def list_running do
    :ets.tab2list(@table)
    |> Enum.map(fn {_id, info} -> info end)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:exec, env_name, command, opts}, _from, state) do
    timeout = min(opts[:timeout] || @default_timeout, @max_timeout)

    if dangerous?(command) do
      {:reply, {:error, :dangerous_command}, state}
    else
      case ApmV4.EnvironmentScanner.get_environment(env_name) do
        {:ok, env} ->
          request_id = generate_id()
          topic = "apm:command_output:#{request_id}"

          info = %{
            id: request_id,
            env: env_name,
            command: command,
            started_at: DateTime.utc_now(),
            pid: nil
          }

          :ets.insert(@table, {request_id, info})

          result = run_command(command, env.path, timeout, topic, request_id)

          :ets.delete(@table, request_id)
          {:reply, {:ok, Map.put(result, :request_id, request_id)}, state}

        {:error, :not_found} ->
          {:reply, {:error, :environment_not_found}, state}
      end
    end
  end

  def handle_call({:kill, request_id}, _from, state) do
    case :ets.lookup(@table, request_id) do
      [{^request_id, %{pid: pid}}] when is_pid(pid) ->
        Process.exit(pid, :kill)
        :ets.delete(@table, request_id)
        {:reply, :ok, state}

      _ ->
        {:reply, {:error, :not_found}, state}
    end
  end

  # --- Private ---

  defp dangerous?(command) do
    Enum.any?(@dangerous_patterns, fn pattern ->
      Regex.match?(pattern, command)
    end)
  end

  defp run_command(command, cwd, timeout, topic, request_id) do
    table = @table

    task =
      Task.async(fn ->
        port =
          Port.open({:spawn_executable, "/bin/sh"},
            [:binary, :exit_status, :stderr_to_stdout,
             args: ["-c", command], cd: to_charlist(cwd)]
          )

        # Store the task pid so kill/1 can find it
        case :ets.lookup(table, request_id) do
          [{^request_id, info}] ->
            :ets.insert(table, {request_id, %{info | pid: self()}})
          _ -> :ok
        end

        collect_output(port, "", topic)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      nil ->
        Phoenix.PubSub.broadcast(ApmV4.PubSub, topic, {:output, "[timeout after #{div(timeout, 1000)}s]\n"})
        %{exit_code: 124, output: "[command timed out]"}
    end
  end

  defp collect_output(port, acc, topic) do
    receive do
      {^port, {:data, data}} ->
        Phoenix.PubSub.broadcast(ApmV4.PubSub, topic, {:output, data})
        collect_output(port, acc <> data, topic)

      {^port, {:exit_status, code}} ->
        %{exit_code: code, output: acc}
    after
      @max_timeout ->
        %{exit_code: 124, output: acc <> "\n[collect timeout]"}
    end
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.hex_encode32(case: :lower, padding: false) |> String.slice(0, 12)
  end
end
