defmodule ApmV4.AlertRulesEngine do
  @moduledoc """
  GenServer for configurable alert rules with ETS-backed storage.
  Evaluates metrics against rules and fires alerts when thresholds are breached.
  """

  use GenServer

  @rules_table :apm_alert_rules
  @history_table :apm_alert_history
  @state_table :apm_alert_state
  @history_cap 1000

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec add_rule(map()) :: {:ok, String.t()}
  def add_rule(params) do
    GenServer.call(__MODULE__, {:add_rule, params})
  end

  @spec update_rule(String.t(), map()) :: :ok | {:error, :not_found}
  def update_rule(rule_id, params) do
    GenServer.call(__MODULE__, {:update_rule, rule_id, params})
  end

  @spec delete_rule(String.t()) :: :ok | {:error, :not_found}
  def delete_rule(rule_id) do
    GenServer.call(__MODULE__, {:delete_rule, rule_id})
  end

  @spec enable_rule(String.t()) :: :ok | {:error, :not_found}
  def enable_rule(rule_id), do: update_rule(rule_id, %{enabled: true})

  @spec disable_rule(String.t()) :: :ok | {:error, :not_found}
  def disable_rule(rule_id), do: update_rule(rule_id, %{enabled: false})

  @spec list_rules() :: [map()]
  def list_rules do
    :ets.tab2list(@rules_table)
    |> Enum.map(fn {_id, rule} -> rule end)
  end

  @spec get_rule(String.t()) :: map() | nil
  def get_rule(rule_id) do
    case :ets.lookup(@rules_table, rule_id) do
      [{^rule_id, rule}] -> rule
      [] -> nil
    end
  end

  @spec evaluate(String.t(), :fleet | :agent, number()) :: :ok
  def evaluate(metric, scope, value) do
    GenServer.call(__MODULE__, {:evaluate, metric, scope, value})
  end

  @spec get_alert_history(keyword()) :: [map()]
  def get_alert_history(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    rule_id_filter = Keyword.get(opts, :rule_id)
    severity_filter = Keyword.get(opts, :severity)
    since_filter = Keyword.get(opts, :since)

    :ets.tab2list(@history_table)
    |> Enum.map(fn {_key, alert} -> alert end)
    |> Enum.filter(fn alert ->
      (is_nil(rule_id_filter) or alert.rule_id == rule_id_filter) and
        (is_nil(severity_filter) or alert.severity == severity_filter) and
        (is_nil(since_filter) or DateTime.compare(alert.fired_at, since_filter) != :lt)
    end)
    |> Enum.sort_by(& &1.fired_at, {:desc, DateTime})
    |> Enum.take(limit)
  end

  @spec acknowledge(String.t()) :: :ok | {:error, :not_found}
  def acknowledge(alert_id) do
    GenServer.call(__MODULE__, {:acknowledge, alert_id})
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    :ets.new(@rules_table, [:named_table, :set, :public, read_concurrency: true])
    :ets.new(@history_table, [:named_table, :ordered_set, :public, read_concurrency: true])
    :ets.new(@state_table, [:named_table, :set, :public, read_concurrency: true])

    bootstrap_rules()

    {:ok, %{}}
  end

  @impl true
  def handle_call({:add_rule, params}, _from, state) do
    rule_id = Map.get(params, :id, generate_id())
    rule = build_rule(rule_id, params)
    :ets.insert(@rules_table, {rule_id, rule})
    :ets.insert(@state_table, {rule_id, 0})
    {:reply, {:ok, rule_id}, state}
  end

  def handle_call({:update_rule, rule_id, params}, _from, state) do
    case :ets.lookup(@rules_table, rule_id) do
      [{^rule_id, rule}] ->
        updated = Map.merge(rule, Map.drop(params, [:id]))
        :ets.insert(@rules_table, {rule_id, updated})
        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:delete_rule, rule_id}, _from, state) do
    case :ets.lookup(@rules_table, rule_id) do
      [{^rule_id, _}] ->
        :ets.delete(@rules_table, rule_id)
        :ets.delete(@state_table, rule_id)
        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:evaluate, metric, scope, value}, _from, state) do
    matching_rules =
      :ets.tab2list(@rules_table)
      |> Enum.map(fn {_id, rule} -> rule end)
      |> Enum.filter(fn rule ->
        rule.enabled and rule.metric == metric and rule.scope == scope
      end)

    Enum.each(matching_rules, fn rule ->
      if breached?(rule.comparator, value, rule.threshold) do
        breach_count = get_breach_count(rule.id) + 1
        :ets.insert(@state_table, {rule.id, breach_count})

        if breach_count >= rule.consecutive_breaches do
          fire_alert(rule, value)
          :ets.insert(@state_table, {rule.id, 0})
        end
      else
        :ets.insert(@state_table, {rule.id, 0})
      end
    end)

    {:reply, :ok, state}
  end

  def handle_call(:reinit, _from, _state) do
    :ets.delete_all_objects(@rules_table)
    :ets.delete_all_objects(@history_table)
    :ets.delete_all_objects(@state_table)
    bootstrap_rules()
    {:reply, :ok, %{}}
  end

  def handle_call({:acknowledge, alert_id}, _from, state) do
    found =
      :ets.tab2list(@history_table)
      |> Enum.find(fn {_key, alert} -> alert.id == alert_id end)

    case found do
      {key, alert} ->
        :ets.insert(@history_table, {key, %{alert | acknowledged: true}})
        {:reply, :ok, state}

      nil ->
        {:reply, {:error, :not_found}, state}
    end
  end

  # --- Private ---

  defp bootstrap_rules do
    defaults = [
      %{
        id: "fleet_error_rate",
        name: "Fleet Error Rate",
        metric: "error_rate",
        scope: :fleet,
        aggregation: :avg,
        threshold: 0.10,
        comparator: :gt,
        window_s: 300,
        consecutive_breaches: 2,
        severity: :warning,
        enabled: true,
        channels: ["pubsub", "notification"]
      },
      %{
        id: "agent_offline",
        name: "Agent Offline",
        metric: "heartbeat_gap",
        scope: :agent,
        aggregation: :max,
        threshold: 300,
        comparator: :gt,
        window_s: 60,
        consecutive_breaches: 1,
        severity: :critical,
        enabled: true,
        channels: ["pubsub", "notification"]
      },
      %{
        id: "token_spike",
        name: "Token Spike",
        metric: "token_usage",
        scope: :fleet,
        aggregation: :sum,
        threshold: 100_000,
        comparator: :gt,
        window_s: 300,
        consecutive_breaches: 1,
        severity: :info,
        enabled: true,
        channels: ["pubsub", "notification"]
      }
    ]

    Enum.each(defaults, fn params ->
      rule = build_rule(params.id, params)
      :ets.insert(@rules_table, {rule.id, rule})
      :ets.insert(@state_table, {rule.id, 0})
    end)
  end

  defp build_rule(id, params) do
    %{
      id: id,
      name: Map.get(params, :name, id),
      metric: Map.get(params, :metric, ""),
      scope: Map.get(params, :scope, :fleet),
      aggregation: Map.get(params, :aggregation, :avg),
      threshold: Map.get(params, :threshold, 0),
      comparator: Map.get(params, :comparator, :gt),
      window_s: Map.get(params, :window_s, 300),
      consecutive_breaches: Map.get(params, :consecutive_breaches, 1),
      severity: Map.get(params, :severity, :info),
      enabled: Map.get(params, :enabled, true),
      channels: Map.get(params, :channels, ["pubsub"])
    }
  end

  defp breached?(:gt, value, threshold), do: value > threshold
  defp breached?(:lt, value, threshold), do: value < threshold
  defp breached?(:gte, value, threshold), do: value >= threshold
  defp breached?(:lte, value, threshold), do: value <= threshold
  defp breached?(:eq, value, threshold), do: value == threshold

  defp get_breach_count(rule_id) do
    case :ets.lookup(@state_table, rule_id) do
      [{^rule_id, count}] -> count
      [] -> 0
    end
  end

  defp fire_alert(rule, value) do
    now = DateTime.utc_now()
    alert_id = generate_id()

    alert = %{
      id: alert_id,
      rule_id: rule.id,
      rule_name: rule.name,
      metric: rule.metric,
      scope: rule.scope,
      value: value,
      threshold: rule.threshold,
      severity: rule.severity,
      fired_at: now,
      acknowledged: false
    }

    key = {System.monotonic_time(), rule.id}
    :ets.insert(@history_table, {key, alert})
    cap_history()

    if Process.whereis(ApmV4.PubSub) do
      Phoenix.PubSub.broadcast(ApmV4.PubSub, "apm:alerts", {:alert_fired, alert})
    end

    if "notification" in rule.channels do
      if Process.whereis(ApmV4.AgentRegistry) do
        ApmV4.AgentRegistry.add_notification(%{
          title: "Alert: #{rule.name}",
          message: "#{rule.metric} = #{value} (threshold: #{rule.threshold})",
          level: to_string(rule.severity)
        })
      end
    end
  end

  defp cap_history do
    all_keys = :ets.tab2list(@history_table) |> Enum.map(fn {k, _} -> k end) |> Enum.sort()

    if length(all_keys) > @history_cap do
      to_delete = Enum.take(all_keys, length(all_keys) - @history_cap)
      Enum.each(to_delete, &:ets.delete(@history_table, &1))
    end
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
