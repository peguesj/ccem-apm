defmodule ApmV5.HookHealthMonitor do
  @moduledoc """
  GenServer that scans project `.remember/` directories every 5 minutes
  and broadcasts health changes via PubSub.

  ## Project discovery

  Scans `~/Developer/*/` (or the override from `Application.get_env(:apm_v5, :hook_health_root)`)
  for directories containing any of: `.git`, `.claude`, `package.json`, `mix.exs`,
  `Cargo.toml`, `pyproject.toml`, `go.mod`.

  ## Health criteria — a project is `:unhealthy` if ANY of:

  1. `.remember/`, `.remember/logs/hook-errors.log`, or `.remember/tmp/` is missing
  2. `.remember/` not owned by current user
  3. `hook-errors.log` non-empty AND mtime within 24h, OR contains known error patterns
  4. `hook-errors.log` mtime older than 7 days AND size > 0

  ## API

      current_health() :: %{healthy: integer, unhealthy: integer, projects: [map()]}
      scan_now()       :: :ok
      subscribe()      :: :ok
  """

  use GenServer
  require Logger

  @scan_interval 300_000
  @pubsub_topic "hooks:health"

  @error_patterns [
    "no such file or directory",
    "permission denied",
    "command not found"
  ]
  @exit_pattern ~r/exited [1-9]\d*/i

  @marker_files ~w(.git .claude package.json mix.exs Cargo.toml pyproject.toml go.mod)

  # ── Public API ────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc "Returns the last scan result."
  @spec current_health() :: %{healthy: integer(), unhealthy: integer(), projects: [map()]}
  def current_health do
    GenServer.call(__MODULE__, :current_health)
  end

  @doc "Triggers an immediate async re-scan."
  @spec scan_now() :: :ok
  def scan_now do
    GenServer.cast(__MODULE__, :scan_now)
  end

  @doc "Subscribes the calling process to `hooks:health` PubSub topic."
  @spec subscribe() :: :ok
  def subscribe do
    Phoenix.PubSub.subscribe(ApmV5.PubSub, @pubsub_topic)
  end

  # ── GenServer callbacks ───────────────────────────────────────────────────

  @impl true
  def init([]) do
    schedule_scan()
    state = %{
      health: %{healthy: 0, unhealthy: 0, projects: []},
      prev_statuses: %{}
    }

    # Perform initial scan async so we don't block supervision tree start
    send(self(), :do_scan)
    {:ok, state}
  end

  @impl true
  def handle_call(:current_health, _from, state) do
    {:reply, state.health, state}
  end

  @impl true
  def handle_cast(:scan_now, state) do
    send(self(), :do_scan)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:scan_done, projects}, state) do
    healthy = Enum.count(projects, &(&1.status == :healthy))
    unhealthy = Enum.count(projects, &(&1.status == :unhealthy))

    new_health = %{healthy: healthy, unhealthy: unhealthy, projects: projects}

    new_statuses = Map.new(projects, &{&1.project, &1.status})
    delta = compute_delta(state.prev_statuses, new_statuses, projects)

    if delta != [] do
      broadcast_change(new_health, delta)
    end

    {:noreply, %{state | health: new_health, prev_statuses: new_statuses}}
  end

  @impl true
  def handle_info(:scheduled_scan, state) do
    schedule_scan()
    send(self(), :do_scan)
    {:noreply, state}
  end

  @impl true
  def handle_info(:do_scan, state) do
    server = self()

    Task.start(fn ->
      projects = scan_projects()
      GenServer.cast(server, {:scan_done, projects})
    end)

    {:noreply, state}
  end

  # ── Scanning logic ────────────────────────────────────────────────────────

  @spec scan_projects() :: [map()]
  defp scan_projects do
    dev_root = Application.get_env(:apm_v5, :hook_health_root, Path.expand("~/Developer"))

    dev_root
    |> Path.join("*/")
    |> Path.wildcard()
    |> Enum.filter(&project_dir?/1)
    |> Enum.map(&scan_project/1)
  end

  @spec project_dir?(String.t()) :: boolean()
  defp project_dir?(path) do
    File.dir?(path) and
      Enum.any?(@marker_files, fn f -> File.exists?(Path.join(path, f)) end)
  end

  @spec scan_project(String.t()) :: map()
  defp scan_project(path) do
    project_name = Path.basename(path)
    remember_dir = Path.join(path, ".remember")
    logs_dir = Path.join(remember_dir, "logs")
    tmp_dir = Path.join(remember_dir, "tmp")
    log_path = Path.join(logs_dir, "hook-errors.log")

    issues = []

    # 1. Check existence
    issues =
      if not File.dir?(remember_dir),
        do: [:missing_remember | issues],
        else: issues

    issues =
      if :missing_remember not in issues and not File.exists?(log_path),
        do: [:missing_logs | issues],
        else: issues

    issues =
      if :missing_remember not in issues and not File.dir?(tmp_dir),
        do: [:missing_tmp | issues],
        else: issues

    # 2. Ownership check (only if .remember exists)
    issues =
      if :missing_remember not in issues do
        current_user = System.get_env("USER", "")

        case System.cmd("stat", ["-f", "%Su", remember_dir], stderr_to_stdout: true) do
          {owner, 0} ->
            owner = String.trim(owner)

            if current_user != "" and owner != current_user,
              do: [:wrong_owner | issues],
              else: issues

          _ ->
            issues
        end
      else
        issues
      end

    # 3 & 4. Log content checks (only if log exists)
    {issues, last_error_line, last_error_at, log_size} =
      if :missing_remember not in issues and :missing_logs not in issues and
           File.exists?(log_path) do
        check_log_content(log_path, issues)
      else
        {issues, nil, nil, 0}
      end

    status = if issues == [], do: :healthy, else: :unhealthy

    %{
      project: project_name,
      path: path,
      status: status,
      issues: issues,
      last_error_line: last_error_line,
      last_error_at: last_error_at,
      log_size: log_size,
      scanned_at: DateTime.utc_now()
    }
  end

  @spec check_log_content(String.t(), [atom()]) ::
          {[atom()], nil | binary(), nil | DateTime.t(), non_neg_integer()}
  defp check_log_content(log_path, issues) do
    case File.stat(log_path) do
      {:ok, %File.Stat{size: size, mtime: mtime_erl}} ->
        mtime = erl_to_datetime(mtime_erl)
        now = DateTime.utc_now()
        age_seconds = DateTime.diff(now, mtime, :second)

        content =
          if size > 0 do
            case File.read(log_path) do
              {:ok, c} -> c
              _ -> ""
            end
          else
            ""
          end

        last_error_line =
          if size > 0 do
            content
            |> String.split("\n")
            |> Enum.reject(&(&1 == ""))
            |> List.last()
          else
            nil
          end

        # Criterion 3: non-empty AND (mtime within 24h OR error patterns)
        issues =
          if size > 0 do
            within_24h = age_seconds <= 86_400
            has_pattern = has_error_pattern?(content)

            if within_24h or has_pattern,
              do: [:recent_error_content | issues],
              else: issues
          else
            issues
          end

        # Criterion 4: mtime older than 7 days AND size > 0
        issues =
          if size > 0 and age_seconds > 7 * 86_400,
            do: [:stale_log | issues],
            else: issues

        last_error_at = if size > 0, do: mtime, else: nil

        {issues, last_error_line, last_error_at, size}

      {:error, _} ->
        {issues, nil, nil, 0}
    end
  end

  @spec has_error_pattern?(String.t()) :: boolean()
  defp has_error_pattern?(content) do
    lower = String.downcase(content)

    Enum.any?(@error_patterns, &String.contains?(lower, &1)) or
      Regex.match?(@exit_pattern, content)
  end

  @spec erl_to_datetime(:calendar.datetime()) :: DateTime.t()
  defp erl_to_datetime({{y, mo, d}, {h, mi, s}}) do
    {:ok, dt} = DateTime.new(Date.new!(y, mo, d), Time.new!(h, mi, s), "Etc/UTC")
    dt
  end

  # ── PubSub helpers ────────────────────────────────────────────────────────

  @spec compute_delta(map(), map(), [map()]) :: [map()]
  defp compute_delta(prev_statuses, new_statuses, projects) do
    new_statuses
    |> Enum.flat_map(fn {project, new_status} ->
      case Map.get(prev_statuses, project) do
        ^new_status ->
          []

        old_status ->
          proj = Enum.find(projects, &(&1.project == project))
          [%{project: project, from: old_status, to: new_status, issues: proj && proj.issues || []}]
      end
    end)
  end

  @spec broadcast_change(map(), [map()]) :: :ok
  defp broadcast_change(health, delta) do
    msg = {:hooks_health_changed, Map.put(health, :delta, delta)}

    try do
      Phoenix.PubSub.broadcast(ApmV5.PubSub, @pubsub_topic, msg)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    :ok
  end

  @spec schedule_scan() :: reference()
  defp schedule_scan do
    Process.send_after(self(), :scheduled_scan, @scan_interval)
  end
end
