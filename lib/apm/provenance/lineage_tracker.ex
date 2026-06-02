defmodule Apm.Provenance.LineageTracker do
  @moduledoc """
  GenServer that tracks tool-call lineage edges between agents.

  ## How it works

  The tracker subscribes to the `"apm:audit"` PubSub topic.

  On `:tool_call_end` audit events: records
  `{invocation_id, agent_id, output_hash}` in ETS `:apm_tool_outputs` (cap 5000).

  On `:tool_call_start` audit events: checks whether any `input_hash` from the
  event's details matches a known `output_hash` in `:apm_tool_outputs`. If so,
  records a `wasDerivedFrom` edge in ETS `:apm_lineage_edges` (cap 5000).

  ## Edge structure

  ```elixir
  %{
    from_invocation_id: string,
    to_invocation_id:   string,
    agent_id:           string,  # the consuming agent
    timestamp:          iso8601_string
  }
  ```

  ## Explicit API

  `record_tool_end/3` and `record_tool_start/3` are exposed for direct
  invocation from tests and from HTTP hooks that don't go through AuditLog.

  ## ProvExporter integration

  `Apm.Provenance.ProvExporter.build_bundle/2` reads `:apm_lineage_edges`
  via `build_derived_from/1` to populate the `wasDerivedFrom` section of the
  PROV-JSONLD bundle.

  ## DRTW

  Uses OTP `Phoenix.PubSub` (already a project dependency) for event ingestion.
  ETS ring-buffer pattern consistent with ArtifactAttestation. No new deps.
  """

  use GenServer

  require Logger

  @outputs_table :apm_tool_outputs
  @edges_table :apm_lineage_edges
  @outputs_cap 5_000
  @edges_cap 5_000
  @pubsub Apm.PubSub
  @audit_topic "apm:audit"

  # Persistent term keys for ring counters
  @outputs_counter_key {__MODULE__, :outputs_counter}
  @edges_counter_key {__MODULE__, :edges_counter}

  # ── Client API ─────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Records a tool-call end: stores `{invocation_id, agent_id, output_hash}` in
  `:apm_tool_outputs` ring buffer.

  Called either directly or via `"apm:audit"` PubSub subscription.
  """
  @spec record_tool_end(String.t(), String.t(), String.t()) :: :ok
  def record_tool_end(invocation_id, agent_id, output_hash)
      when is_binary(invocation_id) and is_binary(agent_id) and is_binary(output_hash) do
    GenServer.call(__MODULE__, {:record_tool_end, invocation_id, agent_id, output_hash})
  end

  @doc """
  Records a tool-call start: checks if `input_hash` matches any known
  `output_hash` and creates a `wasDerivedFrom` edge if so.

  Called either directly or via `"apm:audit"` PubSub subscription.
  """
  @spec record_tool_start(String.t(), String.t(), String.t()) :: :ok
  def record_tool_start(invocation_id, agent_id, input_hash)
      when is_binary(invocation_id) and is_binary(agent_id) and is_binary(input_hash) do
    GenServer.call(__MODULE__, {:record_tool_start, invocation_id, agent_id, input_hash})
  end

  @doc """
  Returns all output entries from `:apm_tool_outputs` as a list of maps.
  """
  @spec list_outputs() :: [map()]
  def list_outputs do
    case :ets.whereis(@outputs_table) do
      :undefined -> []
      _tid -> :ets.tab2list(@outputs_table) |> Enum.map(fn {_k, v} -> v end)
    end
  end

  @doc """
  Returns all `wasDerivedFrom` edges from `:apm_lineage_edges` as a list of maps.
  """
  @spec list_edges() :: [map()]
  def list_edges do
    case :ets.whereis(@edges_table) do
      :undefined -> []
      _tid -> :ets.tab2list(@edges_table) |> Enum.map(fn {_k, v} -> v end)
    end
  end

  @doc """
  Returns a lineage DAG `%{nodes: [...], edges: [...]}` for the given `agent_id`.

  Includes all edges where the agent appears as producer or consumer, and the
  corresponding invocation_ids as nodes.
  """
  @spec lineage_for_agent(String.t()) :: %{nodes: [String.t()], edges: [map()]}
  def lineage_for_agent(agent_id) when is_binary(agent_id) do
    edges =
      list_edges()
      |> Enum.filter(fn e ->
        consumer = Map.get(e, :agent_id) || Map.get(e, "agent_id")
        source = Map.get(e, :source_agent_id) || Map.get(e, "source_agent_id")
        consumer == agent_id or source == agent_id
      end)

    nodes =
      edges
      |> Enum.flat_map(fn e ->
        from = Map.get(e, :from_invocation_id) || Map.get(e, "from_invocation_id")
        to = Map.get(e, :to_invocation_id) || Map.get(e, "to_invocation_id")
        [from, to]
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    %{nodes: nodes, edges: edges}
  end

  @doc """
  Clears all ETS state. Test-only.
  """
  @spec clear_for_test() :: :ok
  def clear_for_test do
    if Mix.env() == :test do
      :ets.delete_all_objects(@outputs_table)
      :ets.delete_all_objects(@edges_table)
      :persistent_term.put(@outputs_counter_key, 0)
      :persistent_term.put(@edges_counter_key, 0)
      :ok
    else
      {:error, :not_allowed_in_production}
    end
  end

  # ── GenServer callbacks ─────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    ensure_tables()
    init_counters()

    # Subscribe to AuditLog events — filter tool_call_start / tool_call_end
    Phoenix.PubSub.subscribe(@pubsub, @audit_topic)

    Logger.info("[LineageTracker] started — subscribed to #{@audit_topic}")
    {:ok, %{}}
  end

  @impl true
  def handle_call({:record_tool_end, invocation_id, agent_id, output_hash}, _from, state) do
    do_record_output(invocation_id, agent_id, output_hash)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:record_tool_start, invocation_id, agent_id, input_hash}, _from, state) do
    do_check_and_record_edge(invocation_id, agent_id, input_hash)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:audit_event, event}, state) do
    event_type = Map.get(event, :event_type) || Map.get(event, "event_type")
    details = Map.get(event, :details) || Map.get(event, "details") || %{}
    actor = Map.get(event, :actor) || Map.get(event, "actor") || "unknown"

    invocation_id =
      Map.get(details, :invocation_id) ||
        Map.get(details, "invocation_id") ||
        Map.get(event, :event_id) ||
        Map.get(event, "event_id") ||
        "#{:erlang.unique_integer([:positive])}"

    case to_string(event_type) do
      "tool_call_end" ->
        output_hash =
          Map.get(details, :output_hash) ||
            Map.get(details, "output_hash") ||
            hash_resource(Map.get(event, :resource) || Map.get(event, "resource") || "")

        do_record_output(invocation_id, actor, output_hash)

      "tool_call_start" ->
        input_hash =
          Map.get(details, :input_hash) ||
            Map.get(details, "input_hash") ||
            hash_resource(Map.get(event, :resource) || Map.get(event, "resource") || "")

        do_check_and_record_edge(invocation_id, actor, input_hash)

      _ ->
        :ok
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Private helpers ─────────────────────────────────────────────────────────

  @spec do_record_output(String.t(), String.t(), String.t()) :: :ok
  defp do_record_output(invocation_id, agent_id, output_hash) do
    counter = next_counter(@outputs_counter_key)
    ring_key = rem(counter - 1, @outputs_cap)

    entry = %{
      invocation_id: invocation_id,
      agent_id: agent_id,
      output_hash: output_hash,
      recorded_at: DateTime.to_iso8601(DateTime.utc_now())
    }

    :ets.insert(@outputs_table, {ring_key, entry})
    :ok
  end

  @spec do_check_and_record_edge(String.t(), String.t(), String.t()) :: :ok
  defp do_check_and_record_edge(to_invocation_id, agent_id, input_hash) do
    # Look for any output entry whose output_hash matches the given input_hash
    matching_output =
      :ets.tab2list(@outputs_table)
      |> Enum.find(fn {_k, entry} ->
        Map.get(entry, :output_hash) == input_hash
      end)

    case matching_output do
      {_k, output_entry} ->
        from_invocation_id = Map.get(output_entry, :invocation_id)
        record_edge(from_invocation_id, to_invocation_id, agent_id)

      nil ->
        :ok
    end
  end

  @spec record_edge(String.t(), String.t(), String.t()) :: :ok
  defp record_edge(from_invocation_id, to_invocation_id, consumer_agent_id) do
    counter = next_counter(@edges_counter_key)
    ring_key = rem(counter - 1, @edges_cap)

    # Look up the source agent_id from the producing output entry
    source_agent_id =
      case :ets.tab2list(@outputs_table)
           |> Enum.find(fn {_k, e} -> Map.get(e, :invocation_id) == from_invocation_id end) do
        {_k, entry} -> Map.get(entry, :agent_id)
        nil -> nil
      end

    edge = %{
      from_invocation_id: from_invocation_id,
      to_invocation_id: to_invocation_id,
      # agent_id = consuming agent (canonical per spec)
      agent_id: consumer_agent_id,
      source_agent_id: source_agent_id,
      timestamp: DateTime.to_iso8601(DateTime.utc_now())
    }

    :ets.insert(@edges_table, {ring_key, edge})

    Logger.debug(
      "[LineageTracker] wasDerivedFrom edge: #{from_invocation_id} → #{to_invocation_id} (consumer=#{consumer_agent_id})"
    )

    :ok
  end

  @spec hash_resource(String.t()) :: String.t()
  defp hash_resource(resource) when is_binary(resource) do
    :crypto.hash(:sha256, resource) |> Base.encode16(case: :lower)
  end

  @spec next_counter(term()) :: non_neg_integer()
  defp next_counter(key) do
    current = :persistent_term.get(key, 0)
    :persistent_term.put(key, current + 1)
    current + 1
  end

  @spec ensure_tables() :: :ok
  defp ensure_tables do
    for {name, opts} <- [
          {@outputs_table, [:set, :named_table, :public, read_concurrency: true]},
          {@edges_table, [:set, :named_table, :public, read_concurrency: true]}
        ] do
      case :ets.whereis(name) do
        :undefined -> :ets.new(name, opts)
        _ -> :ok
      end
    end

    :ok
  end

  @spec init_counters() :: :ok
  defp init_counters do
    if :persistent_term.get(@outputs_counter_key, nil) == nil do
      :persistent_term.put(@outputs_counter_key, 0)
    end

    if :persistent_term.get(@edges_counter_key, nil) == nil do
      :persistent_term.put(@edges_counter_key, 0)
    end

    :ok
  end
end
