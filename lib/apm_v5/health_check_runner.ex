defmodule ApmV5.HealthCheckRunner do
  @moduledoc """
  GenServer that runs periodic environment health checks.
  Checks: APM server reachability, Claude CLI presence, disk space, mix.lock integrity, settings.json.
  """
  use GenServer
  require Logger

  @refresh_interval_ms 30_000

  # --- Client API ---

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @spec get_checks() :: [map()]
  def get_checks do
    GenServer.call(__MODULE__, :get_checks)
  end

  @spec get_overall_health() :: :healthy | :degraded | :unhealthy
  def get_overall_health do
    GenServer.call(__MODULE__, :get_overall_health)
  end

  @spec run_now() :: :ok
  def run_now do
    GenServer.cast(__MODULE__, :run_now)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_) do
    state = %{checks: [], last_run: nil}
    schedule_refresh()
    {:ok, state, {:continue, :initial_run}}
  end

  @impl true
  def handle_continue(:initial_run, state) do
    {:noreply, do_run(state)}
  end

  @impl true
  def handle_call(:get_checks, _from, state) do
    {:reply, state.checks, state}
  end

  @impl true
  def handle_call(:get_overall_health, _from, state) do
    overall = compute_overall(state.checks)
    {:reply, overall, state}
  end

  @impl true
  def handle_cast(:run_now, state) do
    {:noreply, do_run(state)}
  end

  @impl true
  def handle_info(:refresh, state) do
    schedule_refresh()
    {:noreply, do_run(state)}
  end

  # --- Private helpers ---

  defp schedule_refresh do
    Process.send_after(self(), :refresh, @refresh_interval_ms)
  end

  defp do_run(state) do
    checks = [
      check_apm_server(),
      check_claude_cli(),
      check_disk_space(),
      check_mix_lock(),
      check_settings_json()
    ]
    %{state | checks: checks, last_run: DateTime.utc_now()}
  end

  defp check_apm_server do
    result = case :gen_tcp.connect(~c"localhost", 3031, [:binary, active: false], 1000) do
      {:ok, sock} ->
        :gen_tcp.close(sock)
        {:ok, "Listening on port 3031"}
      {:error, reason} ->
        {:error, "Port 3031 unreachable: #{inspect(reason)}"}
    end
    make_check("APM Server", "apm_server", result)
  end

  defp check_claude_cli do
    case System.find_executable("claude") do
      nil ->
        case System.find_executable("claude-code") do
          nil -> make_check("Claude CLI", "claude_cli", {:error, "claude binary not found in PATH"})
          path -> make_check("Claude CLI", "claude_cli", {:ok, "Found at #{path}"})
        end
      path -> make_check("Claude CLI", "claude_cli", {:ok, "Found at #{path}"})
    end
  end

  defp check_disk_space do
    home = System.get_env("HOME", "/Users")
    dev_path = Path.join(home, "Developer")

    result = case :os.type() do
      {:unix, :darwin} ->
        case System.cmd("df", ["-h", dev_path], stderr_to_stdout: true) do
          {output, 0} ->
            lines = String.split(output, "\n", trim: true)
            case Enum.at(lines, 1) do
              nil -> {:ok, "OK"}
              line ->
                parts = String.split(line)
                avail = Enum.at(parts, 3, "?")
                use_pct = Enum.at(parts, 4, "?")
                {:ok, "#{avail} available (#{use_pct} used)"}
            end
          _ -> {:ok, "OK"}
        end
      _ -> {:ok, "OK (check not implemented on this OS)"}
    end
    make_check("Disk Space", "disk_space", result)
  end

  defp check_mix_lock do
    lock_path = Path.expand("~/Developer/ccem/apm-v5/mix.lock")
    result = case File.stat(lock_path) do
      {:ok, stat} ->
        size = stat.size
        if size > 100, do: {:ok, "mix.lock present (#{size} bytes)"}, else: {:error, "mix.lock too small (#{size} bytes)"}
      {:error, _} ->
        {:error, "mix.lock not found at #{lock_path}"}
    end
    make_check("mix.lock", "mix_lock", result)
  end

  defp check_settings_json do
    settings_path = Path.expand("~/.claude/settings.json")
    result = case File.read(settings_path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, _} -> {:ok, "Valid JSON (#{byte_size(content)} bytes)"}
          {:error, _} -> {:error, "Invalid JSON in settings.json"}
        end
      {:error, :enoent} ->
        {:error, "~/.claude/settings.json not found"}
      {:error, reason} ->
        {:error, "Cannot read settings.json: #{inspect(reason)}"}
    end
    make_check("Claude Settings", "claude_settings", result)
  end

  defp make_check(name, key, {:ok, message}) do
    %{name: name, key: key, status: :ok, message: message, checked_at: DateTime.utc_now()}
  end
  defp make_check(name, key, {:error, message}) do
    %{name: name, key: key, status: :error, message: message, checked_at: DateTime.utc_now()}
  end

  defp compute_overall([]), do: :healthy
  defp compute_overall(checks) do
    error_count = Enum.count(checks, &(&1.status == :error))
    cond do
      error_count == 0 -> :healthy
      error_count < length(checks) -> :degraded
      true -> :unhealthy
    end
  end
end
