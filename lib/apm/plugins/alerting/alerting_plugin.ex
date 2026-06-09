defmodule Apm.Plugins.Alerting.AlertingPlugin do
  @moduledoc """
  APM Plugin wrapping the AlertRulesEngine and SloEngine.

  Exposes the following actions:
    - "list_rules"    — list all alert rules
    - "get_rule"      — get a specific rule by ID
    - "add_rule"      — create a new alert rule
    - "enable_rule"   — enable a rule by ID
    - "disable_rule"  — disable a rule by ID
    - "evaluate"      — evaluate a metric against rules
    - "alert_history" — get alert firing history
    - "list_slis"     — list all SLIs (SloEngine)
    - "get_sli"       — get a specific SLI
    - "error_budget"  — get error budget for an SLI
  """

  @behaviour Apm.Plugins.PluginBehaviour

  alias Apm.AlertRulesEngine
  alias Apm.SloEngine

  # ── PluginBehaviour ──────────────────────────────────────────────────────────

  @impl true
  @spec plugin_name() :: String.t()
  def plugin_name, do: "alerting"

  @impl true
  @spec plugin_description() :: String.t()
  def plugin_description,
    do: "Alerting and SLO engine — alert rules, SLI tracking, error budgets, and alert history"

  @impl true
  @spec plugin_version() :: String.t()
  def plugin_version, do: "1.0.0"

  @impl true
  def config_schema do
    %{
      enabled: "boolean",
      cooldown_ms: "integer",
      max_notifications_per_minute: "integer",
      default_channel: "enum:system,agentlock,session,formation"
    }
  end

  @impl true
  def default_config do
    %{
      enabled: true,
      cooldown_ms: 5_000,
      max_notifications_per_minute: 30,
      default_channel: "system"
    }
  end

  @impl true
  @spec list_endpoints() :: [map()]
  def list_endpoints do
    [
      %{
        action: "list_rules",
        description: "List all alert rules",
        params: %{}
      },
      %{
        action: "get_rule",
        description: "Get a specific alert rule by ID",
        params: %{id: "string"}
      },
      %{
        action: "add_rule",
        description: "Create a new alert rule",
        params: %{name: "string", condition: "string", threshold: "number"}
      },
      %{
        action: "enable_rule",
        description: "Enable an alert rule by ID",
        params: %{id: "string"}
      },
      %{
        action: "disable_rule",
        description: "Disable an alert rule by ID",
        params: %{id: "string"}
      },
      %{
        action: "evaluate",
        description: "Evaluate a metric value against all matching rules",
        params: %{metric: "string", scope: "string", value: "number"}
      },
      %{
        action: "alert_history",
        description: "Get alert firing history",
        params: %{}
      },
      %{
        action: "list_slis",
        description: "List all SLIs from the SLO engine",
        params: %{}
      },
      %{
        action: "get_sli",
        description: "Get a specific SLI by name",
        params: %{name: "string"}
      },
      %{
        action: "error_budget",
        description: "Get the error budget for an SLI",
        params: %{name: "string"}
      }
    ]
  end

  @impl true
  @spec handle_action(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def handle_action("list_rules", _params, _opts) do
    rules = AlertRulesEngine.list_rules()
    {:ok, %{rules: rules, count: length(rules)}}
  end

  def handle_action("get_rule", %{"id" => id}, _opts) do
    case AlertRulesEngine.get_rule(id) do
      nil -> {:error, {:not_found, id}}
      rule -> {:ok, %{rule: rule}}
    end
  end

  def handle_action("get_rule", _params, _opts) do
    {:error, {:missing_param, "id is required"}}
  end

  def handle_action("add_rule", params, _opts) do
    case AlertRulesEngine.add_rule(params) do
      {:ok, rule_id} -> {:ok, %{status: "created", rule_id: rule_id}}
      {:error, reason} -> {:error, reason}
    end
  end

  def handle_action("enable_rule", %{"id" => id}, _opts) do
    case AlertRulesEngine.enable_rule(id) do
      :ok -> {:ok, %{status: "enabled", id: id}}
      {:error, :not_found} -> {:error, {:not_found, id}}
    end
  end

  def handle_action("enable_rule", _params, _opts) do
    {:error, {:missing_param, "id is required"}}
  end

  def handle_action("disable_rule", %{"id" => id}, _opts) do
    case AlertRulesEngine.disable_rule(id) do
      :ok -> {:ok, %{status: "disabled", id: id}}
      {:error, :not_found} -> {:error, {:not_found, id}}
    end
  end

  def handle_action("disable_rule", _params, _opts) do
    {:error, {:missing_param, "id is required"}}
  end

  def handle_action("evaluate", %{"metric" => metric, "scope" => scope, "value" => value}, _opts) do
    scope_atom = safe_atom(scope)
    AlertRulesEngine.evaluate(metric, scope_atom, value)
    {:ok, %{status: "evaluated", metric: metric, scope: scope, value: value}}
  end

  def handle_action("evaluate", _params, _opts) do
    {:error, {:missing_param, "metric, scope, and value are required"}}
  end

  def handle_action("alert_history", _params, _opts) do
    history = AlertRulesEngine.get_alert_history()
    {:ok, %{history: history, count: length(history)}}
  end

  def handle_action("list_slis", _params, _opts) do
    slis = SloEngine.get_all_slis()
    {:ok, %{slis: slis, count: length(slis)}}
  end

  def handle_action("get_sli", %{"name" => name}, _opts) do
    sli_name = safe_atom(name)

    case SloEngine.get_sli(sli_name) do
      nil -> {:error, {:not_found, name}}
      sli -> {:ok, %{sli: sli}}
    end
  end

  def handle_action("get_sli", _params, _opts) do
    {:error, {:missing_param, "name is required"}}
  end

  def handle_action("error_budget", %{"name" => name}, _opts) do
    sli_name = safe_atom(name)

    case SloEngine.get_error_budget(sli_name) do
      nil -> {:error, {:not_found, name}}
      budget -> {:ok, %{name: name, error_budget: budget}}
    end
  end

  def handle_action("error_budget", _params, _opts) do
    {:error, {:missing_param, "name is required"}}
  end

  def handle_action(action, _params, _opts) do
    {:error, {:unknown_action, action}}
  end

  @impl true
  @spec supervisor_children() :: [Supervisor.child_spec()]
  def supervisor_children, do: []

  @impl true
  @spec default_enabled?() :: boolean()
  def default_enabled?, do: true

  # ── Private helpers ──────────────────────────────────────────────────────────

  @spec safe_atom(String.t()) :: atom()
  defp safe_atom(str) when is_binary(str) do
    String.to_atom(str)
  rescue
    _ -> :unknown
  end
end
