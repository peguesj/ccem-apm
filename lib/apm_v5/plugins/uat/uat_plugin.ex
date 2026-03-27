defmodule ApmV5.Plugins.Uat.UatPlugin do
  @moduledoc """
  APM Plugin wrapping the UAT intake watcher.

  Delegates to `ApmV5.Intake.Watchers.UatWatcher` and `ApmV5.Intake.IntakeStore`
  for UAT test event data.
  Exposes the following actions:
    - "list_tests"    — list all UAT intake events of type "submission"
    - "run_test"      — submit a synthetic UAT event via the watcher
    - "get_result"    — get a single UAT intake event by ID
    - "clear_results" — not supported (intake is append-only); returns informational error
  """

  @behaviour ApmV5.Plugins.PluginBehaviour

  alias ApmV5.Intake.Store, as: IntakeStore

  # ── PluginBehaviour ──────────────────────────────────────────────────────────

  @impl true
  @spec plugin_name() :: String.t()
  def plugin_name, do: "uat"

  @impl true
  @spec plugin_description() :: String.t()
  def plugin_description,
    do: "UAT intake watcher — list test submissions, query results, and submit synthetic UAT events via the intake pipeline"

  @impl true
  @spec plugin_version() :: String.t()
  def plugin_version, do: "1.0.0"

  @impl true
  @spec list_endpoints() :: [map()]
  def list_endpoints do
    [
      %{
        action: "list_tests",
        description: "List all UAT intake events (submissions and context fetches)",
        params: %{limit: "integer (optional — default 50)", source: "string (optional — filter by source)"}
      },
      %{
        action: "run_test",
        description: "Submit a synthetic UAT event into the intake pipeline",
        params: %{
          event_type: "string (required — e.g. submission, context_fetch)",
          title: "string (optional)",
          severity: "string (optional — critical|high|medium|low)",
          payload: "map (optional — additional event data)"
        }
      },
      %{
        action: "get_result",
        description: "Get a single UAT intake event by its correlation ID",
        params: %{id: "string (required — correlation ID)"}
      },
      %{
        action: "clear_results",
        description: "Not supported — intake store is append-only. Use source filtering instead.",
        params: %{}
      }
    ]
  end

  @impl true
  @spec handle_action(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def handle_action("list_tests", params, _opts) do
    limit = Map.get(params, "limit", 50)
    source_filter = Map.get(params, "source")

    all_events = IntakeStore.list(source: "uat")

    filtered =
      case source_filter do
        nil -> all_events
        src -> Enum.filter(all_events, &(&1.source == src))
      end

    results = Enum.take(filtered, limit)
    {:ok, %{events: results, count: length(results), total: length(filtered)}}
  end

  def handle_action("run_test", %{"event_type" => event_type} = params, _opts) do
    payload =
      Map.get(params, "payload", %{})
      |> Map.put("title", Map.get(params, "title", "Synthetic UAT Event"))
      |> Map.put("severity", Map.get(params, "severity", "medium"))

    event = %{
      source: "uat",
      event_type: event_type,
      payload: payload,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    case IntakeStore.submit(event) do
      {:ok, stored} ->
        {:ok, %{submitted: true, event: stored}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def handle_action("run_test", _params, _opts) do
    {:error, {:missing_param, "event_type is required"}}
  end

  def handle_action("get_result", %{"id" => id}, _opts) do
    case IntakeStore.get(id) do
      {:ok, event} -> {:ok, event}
      {:error, :not_found} -> {:error, {:not_found, "UAT event #{id} not found"}}
      {:error, reason} -> {:error, reason}
    end
  end

  def handle_action("get_result", _params, _opts) do
    {:error, {:missing_param, "id is required"}}
  end

  def handle_action("clear_results", _params, _opts) do
    {:error, {:unsupported, "IntakeStore is append-only; clearing is not supported"}}
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
end
