defmodule ApmV5.ConversationWatcher do
  @moduledoc """
  GenServer that monitors ~/.claude/projects/*.jsonl files for active Claude Code sessions.
  Sessions modified within 5 minutes are considered "active". Broadcasts PubSub updates.
  """
  use GenServer
  require Logger

  @refresh_interval_ms 10_000
  @active_threshold_minutes 5
  @pubsub_topic "apm:conversations"

  # --- Client API ---

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @spec get_conversations() :: [map()]
  def get_conversations do
    GenServer.call(__MODULE__, :get_conversations)
  end

  @spec get_active_count() :: non_neg_integer()
  def get_active_count do
    GenServer.call(__MODULE__, :get_active_count)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_) do
    state = %{conversations: [], last_scan: nil}
    schedule_refresh()
    {:ok, state, {:continue, :initial_scan}}
  end

  @impl true
  def handle_continue(:initial_scan, state) do
    {:noreply, do_scan(state)}
  end

  @impl true
  def handle_call(:get_conversations, _from, state) do
    {:reply, state.conversations, state}
  end

  @impl true
  def handle_call(:get_active_count, _from, state) do
    count = Enum.count(state.conversations, &(&1.active))
    {:reply, count, state}
  end

  @impl true
  def handle_info(:refresh, state) do
    schedule_refresh()
    new_state = do_scan(state)
    # Broadcast if active count changed
    old_active = Enum.count(state.conversations, & &1.active)
    new_active = Enum.count(new_state.conversations, & &1.active)
    if old_active != new_active do
      Phoenix.PubSub.broadcast(ApmV5.PubSub, @pubsub_topic, {:conversations_updated, new_state.conversations})
    end
    {:noreply, new_state}
  end

  # --- Private helpers ---

  defp schedule_refresh do
    Process.send_after(self(), :refresh, @refresh_interval_ms)
  end

  defp do_scan(state) do
    convs = scan_conversations()
    %{state | conversations: convs, last_scan: DateTime.utc_now()}
  end

  defp scan_conversations do
    projects_dir = Path.expand("~/.claude/projects")

    case File.ls(projects_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
        |> Enum.map(&build_conversation(Path.join(projects_dir, &1), &1))
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(& &1.last_modified, {:desc, NaiveDateTime})

      {:error, _} ->
        []
    end
  end

  defp build_conversation(path, filename) do
    case File.stat(path) do
      {:ok, %{size: size, mtime: mtime}} when size > 0 ->
        naive_mtime = NaiveDateTime.from_erl!(mtime)
        diff_minutes = NaiveDateTime.diff(NaiveDateTime.utc_now(), naive_mtime, :second) |> div(60)
        active = diff_minutes < @active_threshold_minutes

        session_id = Path.rootname(filename)
        project = guess_project_name(session_id)

        %{
          session_id: session_id,
          project: project,
          file: filename,
          size_bytes: size,
          last_modified: naive_mtime,
          idle_minutes: diff_minutes,
          active: active
        }

      _ ->
        nil
    end
  end

  defp guess_project_name(session_id) do
    # session IDs are often paths like "-Users-jeremiah-Developer-myproject"
    session_id
    |> String.replace("-Users-jeremiah-Developer-", "~/Developer/")
    |> String.replace("-Users-jeremiah-", "~/")
    |> String.replace("-", "/")
    |> then(fn s ->
      if String.contains?(s, "~/Developer/") do
        s
        |> String.split("~/Developer/")
        |> List.last()
        |> String.split("/")
        |> List.first()
      else
        session_id
      end
    end)
  end
end
