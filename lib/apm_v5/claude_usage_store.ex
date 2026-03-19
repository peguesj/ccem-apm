defmodule ApmV5.ClaudeUsageStore do
  # Author: Jeremiah Pegues <jeremiah@pegues.io>
  @moduledoc """
  GenServer tracking Claude model/token usage at user and project scope.

  Stores usage events in ETS keyed by `{project, model}` tuples.
  Broadcasts updates on `"apm:usage"` PubSub topic so UsageLive can
  react in real time without polling.

  Effort levels are inferred from the tool_calls:session ratio:
    - low       < 10  tool calls / session
    - medium    10–50 tool calls / session
    - high      50–100 tool calls / session
    - intensive > 100 tool calls / session
  """

  use GenServer

  require Logger

  @table :claude_usage

  # -------------------------------------------------------------------------
  # Client API
  # -------------------------------------------------------------------------

  @doc "Start the ClaudeUsageStore GenServer."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Record a usage event for the given project+model combination.

  Upserts into ETS and broadcasts `{:usage_updated, data}` on `"apm:usage"`.
  """
  @spec record_usage(String.t(), String.t(), map()) :: :ok
  def record_usage(project, model, %{} = usage) do
    GenServer.cast(__MODULE__, {:record_usage, project, model, usage})
  end

  @doc "Return usage map for a single project: %{model => %{...counters}}."
  @spec get_usage(String.t()) :: map()
  def get_usage(project) do
    case :ets.info(@table) do
      :undefined ->
        %{}

      _ ->
        :ets.tab2list(@table)
        |> Enum.filter(fn {{proj, _model}, _} -> proj == project end)
        |> Enum.map(fn {{_proj, model}, stats} -> {model, stats} end)
        |> Map.new()
    end
  end

  @doc "Return all usage data: %{project => %{model => %{...counters}}}."
  @spec get_all_usage() :: map()
  def get_all_usage do
    case :ets.info(@table) do
      :undefined ->
        %{}

      _ ->
        :ets.tab2list(@table)
        |> Enum.reduce(%{}, fn {{project, model}, stats}, acc ->
          Map.update(acc, project, %{model => stats}, &Map.put(&1, model, stats))
        end)
    end
  end

  @doc """
  Return an aggregated summary across all projects.

  Shape:
    %{
      total_input_tokens: integer,
      total_output_tokens: integer,
      total_cache_tokens: integer,
      total_tool_calls: integer,
      total_sessions: integer,
      top_model: String.t() | nil,
      model_breakdown: %{model => %{...counters}},
      projects: %{project => %{effort_level, model_breakdown, ...}}
    }
  """
  @spec get_summary() :: map()
  def get_summary do
    all = get_all_usage()

    # Aggregate per-model across all projects
    model_breakdown =
      all
      |> Map.values()
      |> Enum.reduce(%{}, fn model_map, acc ->
        Enum.reduce(model_map, acc, fn {model, stats}, inner ->
          Map.update(inner, model, stats, &merge_stats(&1, stats))
        end)
      end)

    # Aggregate totals
    totals =
      model_breakdown
      |> Map.values()
      |> Enum.reduce(
        %{input_tokens: 0, output_tokens: 0, cache_tokens: 0, tool_calls: 0, sessions: 0},
        &merge_stats(&2, &1)
      )

    top_model =
      model_breakdown
      |> Enum.max_by(fn {_m, s} -> Map.get(s, :input_tokens, 0) end, fn -> {nil, %{}} end)
      |> elem(0)

    projects =
      all
      |> Enum.map(fn {project, model_map} ->
        project_totals =
          model_map
          |> Map.values()
          |> Enum.reduce(
            %{input_tokens: 0, output_tokens: 0, cache_tokens: 0, tool_calls: 0, sessions: 0},
            &merge_stats(&2, &1)
          )

        effort = infer_effort_level(project_totals)

        {project, Map.merge(project_totals, %{effort_level: effort, model_breakdown: model_map})}
      end)
      |> Map.new()

    %{
      total_input_tokens: Map.get(totals, :input_tokens, 0),
      total_output_tokens: Map.get(totals, :output_tokens, 0),
      total_cache_tokens: Map.get(totals, :cache_tokens, 0),
      total_tool_calls: Map.get(totals, :tool_calls, 0),
      total_sessions: Map.get(totals, :sessions, 0),
      top_model: top_model,
      model_breakdown: model_breakdown,
      projects: projects
    }
  end

  @doc "Clear all usage data for a specific project."
  @spec reset_project(String.t()) :: :ok
  def reset_project(project) do
    GenServer.cast(__MODULE__, {:reset_project, project})
  end

  @doc "Infer effort level for a project based on tool_calls:session ratio."
  @spec get_effort_level(String.t()) :: String.t()
  def get_effort_level(project) do
    usage = get_usage(project)

    totals =
      usage
      |> Map.values()
      |> Enum.reduce(
        %{tool_calls: 0, sessions: 0},
        fn stats, acc ->
          %{
            tool_calls: acc.tool_calls + Map.get(stats, :tool_calls, 0),
            sessions: acc.sessions + Map.get(stats, :sessions, 0)
          }
        end
      )

    infer_effort_level(totals)
  end

  # -------------------------------------------------------------------------
  # GenServer callbacks
  # -------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    Logger.info("[ClaudeUsageStore] ETS table #{table} initialised")
    {:ok, %{table: table}}
  end

  @impl true
  def handle_cast({:record_usage, project, model, usage}, state) do
    key = {project, model}

    current =
      case :ets.lookup(@table, key) do
        [{^key, existing}] -> existing
        [] -> empty_stats()
      end

    updated = %{
      input_tokens: current.input_tokens + Map.get(usage, :input, 0),
      output_tokens: current.output_tokens + Map.get(usage, :output, 0),
      cache_tokens: current.cache_tokens + Map.get(usage, :cache, 0),
      tool_calls: current.tool_calls + Map.get(usage, :tool_calls, 0),
      sessions: current.sessions + 1,
      last_seen: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    :ets.insert(@table, {key, updated})

    Phoenix.PubSub.broadcast(ApmV5.PubSub, "apm:usage", {:usage_updated, get_all_usage()})

    {:noreply, state}
  end

  @impl true
  def handle_cast({:reset_project, project}, state) do
    :ets.tab2list(@table)
    |> Enum.each(fn
      {{^project, _model} = key, _} -> :ets.delete(@table, key)
      _ -> :ok
    end)

    Phoenix.PubSub.broadcast(ApmV5.PubSub, "apm:usage", {:usage_updated, get_all_usage()})

    {:noreply, state}
  end

  # -------------------------------------------------------------------------
  # Private helpers
  # -------------------------------------------------------------------------

  defp empty_stats do
    %{
      input_tokens: 0,
      output_tokens: 0,
      cache_tokens: 0,
      tool_calls: 0,
      sessions: 0,
      last_seen: nil
    }
  end

  defp merge_stats(a, b) do
    %{
      input_tokens: Map.get(a, :input_tokens, 0) + Map.get(b, :input_tokens, 0),
      output_tokens: Map.get(a, :output_tokens, 0) + Map.get(b, :output_tokens, 0),
      cache_tokens: Map.get(a, :cache_tokens, 0) + Map.get(b, :cache_tokens, 0),
      tool_calls: Map.get(a, :tool_calls, 0) + Map.get(b, :tool_calls, 0),
      sessions: Map.get(a, :sessions, 0) + Map.get(b, :sessions, 0),
      last_seen: max_date(Map.get(a, :last_seen), Map.get(b, :last_seen))
    }
  end

  defp max_date(nil, b), do: b
  defp max_date(a, nil), do: a
  defp max_date(a, b), do: if(a >= b, do: a, else: b)

  @effort_thresholds [
    {100, "intensive"},
    {50, "high"},
    {10, "medium"}
  ]

  defp infer_effort_level(%{tool_calls: tc, sessions: sessions}) do
    ratio = if sessions > 0, do: tc / sessions, else: tc

    @effort_thresholds
    |> Enum.find(fn {threshold, _label} -> ratio > threshold end)
    |> case do
      {_, label} -> label
      nil -> "low"
    end
  end

  defp infer_effort_level(_), do: "low"
end
