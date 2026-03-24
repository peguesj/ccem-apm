defmodule ApmV5.ExportManager do
  @moduledoc """
  Stateless Export/Import manager for CCEM APM data.
  Supports full and filtered exports with checksum integrity,
  CSV export for tabular sections, and validated imports.
  """

  @version "7.0.0"
  @all_sections [:agents, :sessions, :metrics, :slos, :alert_rules, :alert_history, :audit_log]

  @doc """
  Export APM data as a checksummed map.

  Options:
    - `sections` - list of sections to include (default: all)
    - `since` - DateTime filter for time-bound data (metrics, audit, alerts)
    - `agent_ids` - filter agent-specific data
  """
  @spec export(keyword()) :: map()
  def export(opts \\ []) do
    sections = Keyword.get(opts, :sections, @all_sections)
    since = Keyword.get(opts, :since)
    agent_ids = Keyword.get(opts, :agent_ids)

    data =
      %{
        manifest: build_manifest(sections),
      }
      |> maybe_put_section(:agents, sections, fn -> export_agents(agent_ids) end)
      |> maybe_put_section(:sessions, sections, fn -> export_sessions() end)
      |> maybe_put_section(:metrics, sections, fn -> export_metrics() end)
      |> maybe_put_section(:slos, sections, fn -> export_slos() end)
      |> maybe_put_section(:alert_rules, sections, fn -> export_alert_rules() end)
      |> maybe_put_section(:alert_history, sections, fn -> export_alert_history(since) end)
      |> maybe_put_section(:audit_log, sections, fn -> export_audit_log(since) end)

    checksum = compute_checksum(data)
    Map.put(data, :checksum, checksum)
  end

  @doc """
  Export a section as CSV string. Supports :agents, :alert_history, :audit_log.
  """
  @spec export_csv(atom()) :: String.t()
  def export_csv(:agents) do
    agents = export_agents(nil)
    headers = ~w(id name tier status project_name agent_type registered_at last_seen)

    rows =
      Enum.map(agents, fn agent ->
        Enum.map(headers, fn h ->
          agent |> Map.get(String.to_existing_atom(h), "") |> to_csv_field()
        end)
      end)

    build_csv(headers, rows)
  end

  def export_csv(:alert_history) do
    alerts = export_alert_history(nil)
    headers = ~w(id rule_id rule_name metric scope value threshold severity fired_at acknowledged)

    rows =
      Enum.map(alerts, fn alert ->
        Enum.map(headers, fn h ->
          key = String.to_existing_atom(h)
          alert |> Map.get(key, "") |> to_csv_field()
        end)
      end)

    build_csv(headers, rows)
  end

  def export_csv(:audit_log) do
    events = export_audit_log(nil)
    headers = ~w(id timestamp event_type actor resource)

    rows =
      Enum.map(events, fn event ->
        Enum.map(headers, fn h ->
          key = String.to_existing_atom(h)
          event |> Map.get(key, "") |> to_csv_field()
        end)
      end)

    build_csv(headers, rows)
  end

  def export_csv(_section), do: {:error, :unsupported_section}

  @doc """
  Import previously exported data. Validates checksum and version compatibility.
  Restores agents and alert rules. Does NOT import audit log (append-only).
  """
  @spec import(map()) :: {:ok, map()} | {:error, term()}
  def import(data) do
    with :ok <- validate_checksum(data),
         :ok <- validate_version(data) do
      summary = do_import(data)
      {:ok, summary}
    end
  end

  # --- Private: Export helpers ---

  defp build_manifest(sections) do
    %{
      version: @version,
      exported_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      hostname: hostname(),
      sections: Enum.map(sections, &to_string/1)
    }
  end

  defp hostname do
    {:ok, name} = :inet.gethostname()
    to_string(name)
  end

  defp maybe_put_section(data, section, sections, fun) do
    if section in sections do
      Map.put(data, section, fun.())
    else
      data
    end
  end

  defp export_agents(nil) do
    ApmV5.AgentRegistry.list_agents()
    |> sanitize_list()
  end

  defp export_agents(agent_ids) do
    ApmV5.AgentRegistry.list_agents()
    |> Enum.filter(fn agent -> agent.id in agent_ids end)
    |> sanitize_list()
  end

  defp export_sessions do
    ApmV5.AgentRegistry.list_sessions()
    |> sanitize_list()
  end

  defp export_metrics do
    ApmV5.MetricsCollector.get_fleet_metrics()
  end

  defp export_slos do
    ApmV5.SloEngine.get_all_slis()
    |> Enum.map(fn sli -> Map.delete(sli, :recent_events) end)
  end

  defp export_alert_rules do
    ApmV5.AlertRulesEngine.list_rules()
  end

  defp export_alert_history(nil) do
    ApmV5.AlertRulesEngine.get_alert_history(limit: 1000)
    |> Enum.map(&stringify_datetimes/1)
  end

  defp export_alert_history(%DateTime{} = since) do
    ApmV5.AlertRulesEngine.get_alert_history(limit: 1000, since: since)
    |> Enum.map(&stringify_datetimes/1)
  end

  defp export_audit_log(nil) do
    ApmV5.AuditLog.query(limit: 1000)
  end

  defp export_audit_log(%DateTime{} = since) do
    since_str = DateTime.to_iso8601(since)
    ApmV5.AuditLog.query(limit: 1000, since: since_str)
  end

  defp sanitize_list(list) when is_list(list), do: list
  defp sanitize_list(_), do: []

  defp stringify_datetimes(map) when is_map(map) do
    Map.new(map, fn
      {k, %DateTime{} = v} -> {k, DateTime.to_iso8601(v)}
      {k, v} -> {k, v}
    end)
  end

  # --- Private: Checksum ---

  defp compute_checksum(data) do
    data
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp validate_checksum(%{checksum: provided_checksum} = data) do
    data_without_checksum = Map.delete(data, :checksum)
    computed = compute_checksum(data_without_checksum)

    if computed == provided_checksum do
      :ok
    else
      {:error, :checksum_mismatch}
    end
  end

  defp validate_checksum(%{"checksum" => provided_checksum} = data) do
    data_without_checksum = Map.delete(data, "checksum")
    computed = compute_checksum(data_without_checksum)

    if computed == provided_checksum do
      :ok
    else
      {:error, :checksum_mismatch}
    end
  end

  defp validate_checksum(_), do: {:error, :missing_checksum}

  # --- Private: Version ---

  defp validate_version(%{manifest: %{version: version}}) do
    if compatible_version?(version), do: :ok, else: {:error, :incompatible_version}
  end

  defp validate_version(%{"manifest" => %{"version" => version}}) do
    if compatible_version?(version), do: :ok, else: {:error, :incompatible_version}
  end

  defp validate_version(_), do: {:error, :missing_manifest}

  defp compatible_version?(version) do
    case Version.parse(version) do
      {:ok, v} -> v.major == 5
      :error -> false
    end
  end

  # --- Private: Import ---

  defp do_import(data) do
    agents_imported = import_agents(data)
    rules_imported = import_alert_rules(data)

    %{
      agents_imported: agents_imported,
      alert_rules_imported: rules_imported,
      audit_log_skipped: true
    }
  end

  defp import_agents(%{agents: agents}) when is_list(agents) do
    Enum.each(agents, fn agent ->
      id = Map.get(agent, :id, Map.get(agent, "id"))
      if id, do: ApmV5.AgentRegistry.register_agent(id, agent)
    end)

    length(agents)
  end

  defp import_agents(%{"agents" => agents}) when is_list(agents) do
    Enum.each(agents, fn agent ->
      id = Map.get(agent, :id, Map.get(agent, "id"))
      if id, do: ApmV5.AgentRegistry.register_agent(id, atomize_keys(agent))
    end)

    length(agents)
  end

  defp import_agents(_), do: 0

  defp import_alert_rules(%{alert_rules: rules}) when is_list(rules) do
    Enum.each(rules, fn rule ->
      ApmV5.AlertRulesEngine.add_rule(rule)
    end)

    length(rules)
  end

  defp import_alert_rules(%{"alert_rules" => rules}) when is_list(rules) do
    Enum.each(rules, fn rule ->
      ApmV5.AlertRulesEngine.add_rule(atomize_keys(rule))
    end)

    length(rules)
  end

  defp import_alert_rules(_), do: 0

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) ->
        {String.to_existing_atom(k), v}
      {k, v} ->
        {k, v}
    end)
  rescue
    ArgumentError -> map
  end

  # --- Private: CSV ---

  defp build_csv(headers, rows) do
    iodata = [
      Enum.intersperse(headers, ","),
      "\n"
      | Enum.map(rows, fn row ->
          [Enum.intersperse(row, ","), "\n"]
        end)
    ]

    IO.iodata_to_binary(iodata)
  end

  defp to_csv_field(value) when is_binary(value) do
    if String.contains?(value, [",", "\"", "\n"]) do
      "\"" <> String.replace(value, "\"", "\"\"") <> "\""
    else
      value
    end
  end

  defp to_csv_field(value) when is_atom(value), do: to_string(value)
  defp to_csv_field(value) when is_number(value), do: to_string(value)
  defp to_csv_field(value) when is_boolean(value), do: to_string(value)
  defp to_csv_field(nil), do: ""
  defp to_csv_field(value), do: inspect(value)
end
