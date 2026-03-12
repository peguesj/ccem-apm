defmodule ApmV5.AnalyticsStore do
  @moduledoc """
  GenServer that aggregates Claude Code session analytics from ~/.claude/projects/*.jsonl files.
  Tracks token usage, model distribution, tool frequency, and active project counts.
  """
  use GenServer
  require Logger

  @refresh_interval_ms 60_000

  # --- Client API ---

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @spec get_summary() :: map()
  def get_summary do
    GenServer.call(__MODULE__, :get_summary)
  end

  @spec get_sessions() :: [map()]
  def get_sessions do
    GenServer.call(__MODULE__, :get_sessions)
  end

  @spec refresh() :: :ok
  def refresh do
    GenServer.cast(__MODULE__, :refresh)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_) do
    state = %{
      summary: default_summary(),
      sessions: [],
      last_refreshed: nil
    }
    schedule_refresh()
    {:ok, state, {:continue, :initial_load}}
  end

  @impl true
  def handle_continue(:initial_load, state) do
    {:noreply, do_refresh(state)}
  end

  @impl true
  def handle_call(:get_summary, _from, state) do
    {:reply, state.summary, state}
  end

  @impl true
  def handle_call(:get_sessions, _from, state) do
    {:reply, state.sessions, state}
  end

  @impl true
  def handle_cast(:refresh, state) do
    {:noreply, do_refresh(state)}
  end

  @impl true
  def handle_info(:refresh, state) do
    schedule_refresh()
    {:noreply, do_refresh(state)}
  end

  # --- Private helpers ---

  defp schedule_refresh do
    Process.send_after(self(), :refresh, @refresh_interval_ms)
  end

  defp do_refresh(state) do
    sessions = scan_sessions()
    summary = aggregate_summary(sessions)
    %{state | summary: summary, sessions: sessions, last_refreshed: DateTime.utc_now()}
  end

  defp scan_sessions do
    projects_dir = Path.expand("~/.claude/projects")

    case File.ls(projects_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
        |> Enum.map(&parse_session_file(Path.join(projects_dir, &1), &1))
        |> Enum.reject(&is_nil/1)

      {:error, _} ->
        []
    end
  end

  defp parse_session_file(path, filename) do
    with {:ok, content} <- File.read(path),
         lines <- String.split(content, "\n", trim: true),
         [_ | _] <- lines do
      entries =
        lines
        |> Enum.map(&Jason.decode/1)
        |> Enum.filter(&match?({:ok, _}, &1))
        |> Enum.map(fn {:ok, entry} -> entry end)

      token_entries = Enum.filter(entries, &Map.has_key?(&1, "usage"))
      total_tokens = Enum.reduce(token_entries, 0, fn e, acc ->
        usage = Map.get(e, "usage", %{})
        acc + Map.get(usage, "input_tokens", 0) + Map.get(usage, "output_tokens", 0)
      end)

      models =
        entries
        |> Enum.map(&Map.get(&1, "model"))
        |> Enum.reject(&is_nil/1)
        |> Enum.frequencies()

      tools =
        entries
        |> Enum.flat_map(fn e -> Map.get(e, "content", []) end)
        |> Enum.filter(&is_map/1)
        |> Enum.filter(&(Map.get(&1, "type") == "tool_use"))
        |> Enum.map(&Map.get(&1, "name"))
        |> Enum.reject(&is_nil/1)
        |> Enum.frequencies()

      %{
        session_id: Path.rootname(filename),
        file: filename,
        total_messages: length(entries),
        total_tokens: total_tokens,
        models: models,
        tools: tools,
        last_modified: file_mtime(path)
      }
    else
      _ -> nil
    end
  end

  defp file_mtime(path) do
    case File.stat(path) do
      {:ok, %{mtime: mtime}} -> mtime
      _ -> nil
    end
  end

  defp aggregate_summary(sessions) do
    total_tokens = Enum.sum(Enum.map(sessions, & &1.total_tokens))
    total_messages = Enum.sum(Enum.map(sessions, & &1.total_messages))

    model_dist =
      sessions
      |> Enum.flat_map(fn s -> Map.to_list(s.models) end)
      |> Enum.reduce(%{}, fn {model, count}, acc -> Map.update(acc, model, count, &(&1 + count)) end)

    tool_freq =
      sessions
      |> Enum.flat_map(fn s -> Map.to_list(s.tools) end)
      |> Enum.reduce(%{}, fn {tool, count}, acc -> Map.update(acc, tool, count, &(&1 + count)) end)
      |> Enum.sort_by(fn {_, v} -> -v end)
      |> Enum.take(10)
      |> Map.new()

    active_count =
      sessions
      |> Enum.count(fn s ->
        case s.last_modified do
          {date, time} ->
            naive = NaiveDateTime.from_erl!({date, time})
            diff = NaiveDateTime.diff(NaiveDateTime.utc_now(), naive, :minute)
            diff < 5
          _ -> false
        end
      end)

    %{
      total_sessions: length(sessions),
      active_sessions: active_count,
      total_tokens: total_tokens,
      total_messages: total_messages,
      model_distribution: model_dist,
      top_tools: tool_freq
    }
  end

  defp default_summary do
    %{
      total_sessions: 0,
      active_sessions: 0,
      total_tokens: 0,
      total_messages: 0,
      model_distribution: %{},
      top_tools: %{}
    }
  end
end
