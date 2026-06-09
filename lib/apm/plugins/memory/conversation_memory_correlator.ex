defmodule Apm.Plugins.Memory.ConversationMemoryCorrelator do
  @moduledoc """
  Correlates claude-mem observations with Claude Code sessions by timestamp and project.

  Stateless utility module — all functions take inputs and return results directly.
  Uses ObservationCache for fast local lookups, falling back to MemoryClientBridge
  for remote data not yet in cache.
  """

  alias Apm.Plugins.Memory.ObservationCache
  alias Apm.Plugins.Memory.MemoryClientBridge
  alias Apm.SessionManager

  require Logger

  @type observation :: map()
  @type session_context :: %{
          session_id: String.t(),
          branch: String.t() | nil,
          agent_id: String.t() | nil,
          formation_id: String.t() | nil
        }

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc """
  Returns observations created during a session's active timespan.

  Looks up session metadata via SessionManager, then queries ObservationCache
  (with MemoryClientBridge fallback) for observations whose timestamps fall
  within the session's active window. Results are additionally filtered by
  project path when the session carries project metadata.
  """
  @spec correlate_session(String.t()) :: {:ok, [observation()]} | {:error, term()}
  def correlate_session(session_id) do
    case SessionManager.get_session(session_id) do
      nil ->
        {:error, :session_not_found}

      session ->
        start_time = parse_time(session["start_time"] || session[:start_time])
        end_time = parse_time(session["end_time"] || session[:end_time])
        project = session["project"] || session[:project]

        observations = all_observations()

        filtered =
          observations
          |> filter_by_time_range(start_time, end_time)
          |> filter_by_project(project)

        {:ok, filtered}
    end
  end

  @doc """
  Returns all observations tagged with a specific project path.

  Queries ObservationCache.list/0 and filters by the project field matching
  the given project_path. Falls back to MemoryClientBridge.timeline/0 when
  the local cache is empty.
  """
  @spec correlate_project(String.t()) :: {:ok, [observation()]} | {:error, term()}
  def correlate_project(project_path) when is_binary(project_path) do
    observations = all_observations()
    matched = filter_by_project(observations, project_path)
    {:ok, matched}
  end

  @doc """
  Enriches an observation map with session context when a matching session is found.

  Finds sessions whose active window contains the observation's timestamp and
  merges a `session_context` key into the observation map with the fields:
  `session_id`, `branch`, `agent_id`, and `formation_id`.

  Returns the observation unchanged (without `session_context`) when no session
  can be matched.
  """
  @spec enrich_observation(observation()) :: observation()
  def enrich_observation(%{"timestamp" => ts} = observation) when is_binary(ts) do
    case parse_time(ts) do
      nil ->
        observation

      obs_time ->
        context = find_session_context_at(obs_time)
        Map.put(observation, "session_context", context)
    end
  end

  def enrich_observation(observation), do: observation

  @doc """
  Finds observations related to a given observation by ID.

  Retrieves the observation from cache or remote, determines its session
  correlation via correlate_session/1, and returns other observations from
  the same session. Additionally searches ObservationCache for observations
  sharing keywords extracted from the observation's narrative/content field.

  Returns `{:error, :not_found}` when the observation ID cannot be resolved.
  """
  @spec find_related(String.t()) :: {:ok, [observation()]} | {:error, term()}
  def find_related(observation_id) when is_binary(observation_id) do
    case get_observation(observation_id) do
      nil ->
        {:error, :not_found}

      observation ->
        session_id = extract_session_id(observation)

        session_peers =
          case session_id && correlate_session(session_id) do
            {:ok, peers} ->
              Enum.reject(peers, fn o ->
                Map.get(o, "id") == observation_id or Map.get(o, :id) == observation_id
              end)

            _ ->
              []
          end

        topic_peers =
          observation
          |> extract_keywords()
          |> Enum.flat_map(&search_observations/1)
          |> Enum.reject(fn o ->
            Map.get(o, "id") == observation_id or Map.get(o, :id) == observation_id
          end)

        related =
          (session_peers ++ topic_peers)
          |> Enum.uniq_by(fn o -> Map.get(o, "id") || Map.get(o, :id) end)

        {:ok, related}
    end
  end

  # ── Private helpers ─────────────────────────────────────────────────────────

  @spec all_observations() :: [observation()]
  defp all_observations do
    case ObservationCache.list() do
      [] -> fetch_from_bridge()
      local -> local
    end
  end

  @spec fetch_from_bridge() :: [observation()]
  defp fetch_from_bridge do
    case MemoryClientBridge.timeline() do
      {:ok, observations} when is_list(observations) -> observations
      _ -> []
    end
  end

  @spec get_observation(String.t()) :: observation() | nil
  defp get_observation(id) do
    case ObservationCache.get(id) do
      nil ->
        case MemoryClientBridge.get_observations([id]) do
          {:ok, [obs | _]} -> obs
          _ -> nil
        end

      obs when is_map(obs) ->
        obs
    end
  end

  @spec search_observations(String.t()) :: [observation()]
  defp search_observations(keyword) do
    case ObservationCache.search(keyword) do
      results when is_list(results) -> results
      _ -> []
    end
  end

  @spec parse_time(String.t() | nil) :: DateTime.t() | nil
  defp parse_time(nil), do: nil

  defp parse_time(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} ->
        dt

      _ ->
        Logger.debug("ConversationMemoryCorrelator: unparseable timestamp #{inspect(ts)}")
        nil
    end
  end

  defp parse_time(_), do: nil

  @spec filter_by_time_range([observation()], DateTime.t() | nil, DateTime.t() | nil) ::
          [observation()]
  defp filter_by_time_range(observations, nil, _end), do: observations

  defp filter_by_time_range(observations, _start, nil) do
    # No end time — session still active; include everything after start
    observations
  end

  defp filter_by_time_range(observations, start_time, end_time) do
    Enum.filter(observations, fn obs ->
      ts = obs["timestamp"] || obs[:timestamp]

      case parse_time(ts) do
        nil ->
          false

        obs_time ->
          not DateTime.before?(obs_time, start_time) and not DateTime.after?(obs_time, end_time)
      end
    end)
  end

  @spec filter_by_project([observation()], String.t() | nil) :: [observation()]
  defp filter_by_project(observations, nil), do: observations

  defp filter_by_project(observations, project_path) do
    Enum.filter(observations, fn obs ->
      obs_project = obs["project"] || obs[:project] || ""
      String.contains?(obs_project, project_path) or String.contains?(project_path, obs_project)
    end)
  end

  @spec find_session_context_at(DateTime.t()) :: session_context() | nil
  defp find_session_context_at(obs_time) do
    SessionManager.list_sessions()
    |> Enum.find_value(fn session ->
      start_time = parse_time(session["start_time"] || session[:start_time])
      end_time = parse_time(session["end_time"] || session[:end_time])

      in_window =
        case {start_time, end_time} do
          {nil, _} -> false
          {s, nil} -> not DateTime.before?(obs_time, s)
          {s, e} -> not DateTime.before?(obs_time, s) and not DateTime.after?(obs_time, e)
        end

      if in_window do
        %{
          session_id: session["session_id"] || session[:session_id],
          branch: session["branch"] || session[:branch],
          agent_id: session["agent_id"] || session[:agent_id],
          formation_id: session["formation_id"] || session[:formation_id]
        }
      end
    end)
  end

  @spec extract_session_id(observation()) :: String.t() | nil
  defp extract_session_id(observation) do
    observation["session_id"] || observation[:session_id]
  end

  @spec extract_keywords(observation()) :: [String.t()]
  defp extract_keywords(observation) do
    text =
      (observation["narrative"] || observation[:narrative] ||
         observation["content"] || observation[:content] || "")
      |> to_string()

    text
    |> String.split(~r/\s+/)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(fn word -> String.length(word) > 4 end)
    |> Enum.take(5)
  end
end
