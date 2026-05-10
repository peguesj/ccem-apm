defmodule ApmV5.Plugins.Harness.HarnessMonitor do
  @moduledoc """
  GenServer that polls `~/.claude/state/session.json` every 15 seconds
  and broadcasts harness state changes on the `"harness:state"` PubSub topic.

  State is only broadcast when it differs from the previous snapshot, so
  subscribers only receive real updates.

  Also subscribes to `"apm:worktrees"` to maintain a live worktree count
  in the state map without requiring a synchronous call to WorktreeStore.
  """

  use GenServer

  require Logger

  @session_path "~/.claude/state/session.json"
  @pubsub_topic "harness:state"
  @poll_interval_ms 15_000

  @type harness_state :: %{
          session: map() | nil,
          harness_mem: %{healthy: boolean(), last_error: String.t() | nil},
          plans: map(),
          git: map(),
          worktree_count: non_neg_integer(),
          last_checked: String.t()
        }

  # ── Public API ────────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Return the current harness state snapshot."
  @spec current_state() :: harness_state()
  def current_state do
    GenServer.call(__MODULE__, :current_state)
  end

  @doc "Return a health summary for the harness."
  @spec health_check() :: %{healthy: boolean(), details: map()}
  def health_check do
    GenServer.call(__MODULE__, :health_check)
  end

  # ── GenServer Callbacks ───────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(ApmV5.PubSub, "apm:worktrees")
    :timer.send_interval(@poll_interval_ms, self(), :poll)

    initial_state = build_state(nil, 0)
    send(self(), :poll)

    Logger.info("[HarnessMonitor] Started, polling #{@session_path} every #{@poll_interval_ms}ms")
    {:ok, %{harness: initial_state, worktree_count: 0}}
  end

  @impl true
  def handle_call(:current_state, _from, %{harness: harness} = state) do
    {:reply, harness, state}
  end

  def handle_call(:health_check, _from, %{harness: harness} = state) do
    healthy = harness.harness_mem.healthy
    result = %{healthy: healthy, details: harness}
    {:reply, result, state}
  end

  @impl true
  def handle_info(:poll, %{worktree_count: wt_count} = state) do
    session_result = read_session_json()
    new_harness = build_state(session_result, wt_count)

    if new_harness != state.harness do
      Phoenix.PubSub.broadcast(ApmV5.PubSub, @pubsub_topic, {:harness_state_updated, new_harness})
    end

    {:noreply, %{state | harness: new_harness}}
  end

  # WorktreeStore broadcasts worktree lists on this topic
  def handle_info({:worktrees_updated, worktrees}, state) when is_list(worktrees) do
    {:noreply, %{state | worktree_count: length(worktrees)}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Private ───────────────────────────────────────────────────────────────────

  @spec read_session_json() :: {:ok, map()} | {:error, term()}
  defp read_session_json do
    path = Path.expand(@session_path)

    with {:ok, contents} <- File.read(path),
         {:ok, decoded} <- Jason.decode(contents) do
      {:ok, decoded}
    else
      {:error, :enoent} ->
        {:error, :file_not_found}

      {:error, reason} ->
        Logger.debug("[HarnessMonitor] session.json read error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @spec compute_state(map()) :: %{harness_mem: map(), plans: map(), git: map()}
  defp compute_state(session_json) do
    harness_mem_raw = Map.get(session_json, "harness_mem") || Map.get(session_json, "harnessMem") || %{}

    healthy = Map.get(harness_mem_raw, "healthy") != false
    last_error = Map.get(harness_mem_raw, "last_error") || Map.get(harness_mem_raw, "lastError")

    %{
      harness_mem: %{healthy: healthy, last_error: last_error},
      plans: Map.get(session_json, "plans") || %{},
      git: Map.get(session_json, "git") || %{}
    }
  end

  @spec build_state({:ok, map()} | {:error, term()} | nil, non_neg_integer()) :: harness_state()
  defp build_state(session_result, worktree_count) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    case session_result do
      {:ok, session_json} ->
        %{harness_mem: hm, plans: plans, git: git} = compute_state(session_json)

        %{
          session: session_json,
          harness_mem: hm,
          plans: plans,
          git: git,
          worktree_count: worktree_count,
          last_checked: now
        }

      _ ->
        %{
          session: nil,
          harness_mem: %{healthy: false, last_error: "session.json not readable"},
          plans: %{},
          git: %{},
          worktree_count: worktree_count,
          last_checked: now
        }
    end
  end
end
