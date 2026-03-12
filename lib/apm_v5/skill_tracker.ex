defmodule ApmV5.SkillTracker do
  @moduledoc """
  GenServer for tracking skill invocations across sessions.

  Uses ETS for fast reads and atomic JSON persistence for durability.
  Broadcasts updates via PubSub on the "apm:skills" topic.
  """

  use GenServer

  require Logger

  @table :apm_skills
  @storage_dir Path.expand("~/.claude/ccem/apm/skills")
  @storage_file "skill_data.json"
  @skills_scan_dir Path.expand("~/.claude/skills")

  # --- Public API ---

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Track a skill invocation for a session."
  def track_skill(session_id, skill_name, project \\ nil, args \\ nil) do
    GenServer.cast(__MODULE__, {:track, session_id, skill_name, project, args})
  end

  @doc "Get all skills tracked for a specific session."
  def get_session_skills(session_id) do
    @table
    |> :ets.match({{session_id, :"$1"}, :"$2"})
    |> Enum.into(%{}, fn [skill, data] -> {skill, data} end)
  end

  @doc "Get aggregated skill data across all sessions for a project."
  def get_project_skills(project_name) do
    @table
    |> :ets.tab2list()
    |> Enum.filter(fn {_key, data} -> data.project == project_name end)
    |> Enum.group_by(fn {{_sid, skill}, _data} -> skill end)
    |> Enum.into(%{}, fn {skill, entries} ->
      total = Enum.sum(Enum.map(entries, fn {_k, d} -> d.count end))
      sessions = length(entries)
      {skill, %{total_count: total, session_count: sessions}}
    end)
  end

  @doc "Get catalog of all observed skills plus filesystem scan."
  def get_skill_catalog do
    observed =
      @table
      |> :ets.tab2list()
      |> Enum.group_by(fn {{_sid, skill}, _data} -> skill end)
      |> Enum.into(%{}, fn {skill, entries} ->
        total = Enum.sum(Enum.map(entries, fn {_k, d} -> d.count end))
        sessions = length(entries)
        {skill, %{total_count: total, session_count: sessions, source: :observed}}
      end)

    fs_skills =
      if File.dir?(@skills_scan_dir) do
        @skills_scan_dir
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.map(&String.trim_trailing(&1, ".md"))
        |> Enum.reject(&Map.has_key?(observed, &1))
        |> Enum.into(%{}, fn name ->
          {name, %{total_count: 0, session_count: 0, source: :filesystem}}
        end)
      else
        %{}
      end

    Map.merge(fs_skills, observed)
  end

  @doc "Get skill co-occurrence pairs across sessions."
  def get_co_occurrence do
    @table
    |> :ets.tab2list()
    |> Enum.group_by(fn {{sid, _skill}, _data} -> sid end)
    |> Enum.flat_map(fn {_sid, entries} ->
      skills = Enum.map(entries, fn {{_sid, skill}, _data} -> skill end) |> Enum.sort()

      for a <- skills, b <- skills, a < b, do: {a, b}
    end)
    |> Enum.frequencies()
  end

  @doc "Detect active methodology for a session based on skill invocations."
  def active_methodology(session_id) do
    skills = get_session_skills(session_id) |> Map.keys()

    cond do
      "ralph" in skills -> :ralph
      "tdd:spawn" in skills or "spawn" in skills -> :tdd
      "elixir-architect" in skills -> :elixir_architect
      skills != [] -> :custom
      true -> nil
    end
  end

  @doc "Clear all tracked data (for tests)."
  def clear_all do
    GenServer.call(__MODULE__, :clear_all)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{table: table}, {:continue, :load_persisted}}
  end

  @impl true
  def handle_continue(:load_persisted, state) do
    load_persisted()
    {:noreply, state}
  end

  @impl true
  def handle_cast({:track, session_id, skill_name, project, args}, state) do
    key = {session_id, skill_name}
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    case :ets.lookup(@table, key) do
      [{^key, existing}] ->
        updated = %{existing | count: existing.count + 1, last_seen: now}
        :ets.insert(@table, {key, updated})

      [] ->
        data = %{
          count: 1,
          first_seen: now,
          last_seen: now,
          project: project,
          args_sample: args
        }

        :ets.insert(@table, {key, data})
    end

    Phoenix.PubSub.broadcast(ApmV5.PubSub, "apm:skills", {:skill_tracked, session_id, skill_name})
    persist()
    {:noreply, state}
  end

  @impl true
  def handle_call(:clear_all, _from, state) do
    :ets.delete_all_objects(@table)
    persist()
    {:reply, :ok, state}
  end

  # --- Private ---

  defp persist do
    File.mkdir_p!(@storage_dir)
    path = Path.join(@storage_dir, @storage_file)
    tmp = path <> ".tmp"

    data =
      @table
      |> :ets.tab2list()
      |> Enum.map(fn {{sid, skill}, d} ->
        %{
          session_id: sid,
          skill: skill,
          count: d.count,
          first_seen: d.first_seen,
          last_seen: d.last_seen,
          project: d.project,
          args_sample: d.args_sample
        }
      end)

    case Jason.encode(data, pretty: true) do
      {:ok, json} ->
        File.write!(tmp, json)
        File.rename!(tmp, path)

      {:error, reason} ->
        Logger.warning("SkillTracker: failed to persist: #{inspect(reason)}")
    end
  end

  defp load_persisted do
    path = Path.join(@storage_dir, @storage_file)

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, entries} when is_list(entries) ->
            Enum.each(entries, fn e ->
              key = {e["session_id"], e["skill"]}

              data = %{
                count: e["count"] || 1,
                first_seen: e["first_seen"],
                last_seen: e["last_seen"],
                project: e["project"],
                args_sample: e["args_sample"]
              }

              :ets.insert(@table, {key, data})
            end)

          _ ->
            :ok
        end

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Logger.warning("SkillTracker: failed to load persisted data: #{inspect(reason)}")
    end
  end
end
