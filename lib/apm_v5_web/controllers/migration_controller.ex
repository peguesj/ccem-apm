defmodule ApmV5Web.V2.MigrationController do
  @moduledoc """
  Migration guide and deprecation status for AG-UI v5.

  ## US-037 Acceptance Criteria (DoD):
  - GET /api/v2/ag-ui/migration — returns migration guide JSON
  - Lists deprecated v4 PubSub topics with EventBus replacements
  - Shows migration progress (which LiveViews migrated)
  - Includes v4_compat toggle status
  - mix compile --warnings-as-errors passes
  """

  use ApmV5Web, :controller

  @deprecated_topics %{
    "agent_update" => "lifecycle:RUN_STARTED, lifecycle:RUN_FINISHED, lifecycle:RUN_ERROR",
    "notification_update" => "special:custom",
    "skill_update" => "special:custom",
    "formation_update" => "lifecycle:*",
    "timeline_update" => "lifecycle:*, text:*, tool:*, state:*, activity:*",
    "tasks_update" => "activity:*",
    "scanner_update" => "activity:*",
    "actions_update" => "activity:*",
    "analytics_update" => "lifecycle:*, tool:*",
    "health_update" => "lifecycle:*",
    "conversation_update" => "lifecycle:*"
  }

  @migrated_liveviews [
    %{name: "DashboardLive", route: "/", status: "migrated", topics: ["lifecycle:*", "state:*", "activity:*", "special:custom"]},
    %{name: "FormationLive", route: "/formation", status: "migrated", topics: ["lifecycle:*"]},
    %{name: "NotificationLive", route: "/notifications", status: "migrated", topics: ["special:custom"]},
    %{name: "SessionTimelineLive", route: "/timeline", status: "migrated", topics: ["lifecycle:*", "text:*", "tool:*", "state:*", "activity:*"]},
    %{name: "SkillsLive", route: "/skills", status: "migrated", topics: ["special:custom"]},
    %{name: "TasksLive", route: "/tasks", status: "migrated", topics: ["activity:*"]},
    %{name: "ScannerLive", route: "/scanner", status: "migrated", topics: ["activity:*"]},
    %{name: "ActionsLive", route: "/actions", status: "migrated", topics: ["activity:*"]},
    %{name: "AnalyticsLive", route: "/analytics", status: "migrated", topics: ["lifecycle:*", "tool:*"]},
    %{name: "HealthCheckLive", route: "/health", status: "migrated", topics: ["lifecycle:*"]},
    %{name: "ConversationMonitorLive", route: "/conversations", status: "migrated", topics: ["lifecycle:*"]},
    %{name: "ToolCallLive", route: "/tool-calls", status: "migrated", topics: ["tool:*"]},
    %{name: "GenerativeUILive", route: "/generative-ui", status: "migrated", topics: ["special:custom"]},
    %{name: "A2ALive", route: "/a2a", status: "migrated", topics: ["a2a:*", "special:custom"]}
  ]

  @doc "GET /api/v2/ag-ui/migration — migration guide and status"
  def migration_status(conn, _params) do
    v4_compat_enabled = Application.get_env(:apm_v5, :ag_ui_native_events, false) == false

    json(conn, %{
      version: "5.1.0",
      migration_guide: %{
        summary: "CCEM APM v5.1.0 introduces the AG-UI EventBus as the primary event transport. " <>
                 "Legacy PubSub topics are preserved via V4Compat shim during migration.",
        v4_compat_enabled: v4_compat_enabled,
        v4_compat_toggle: "Application.put_env(:apm_v5, :ag_ui_native_events, true) to disable V4Compat",
        event_bus_module: "ApmV5.AgUi.EventBus",
        topic_taxonomy: %{
          lifecycle: "Agent run lifecycle (RUN_STARTED, RUN_FINISHED, RUN_ERROR, STEP_STARTED, STEP_FINISHED)",
          text: "Text streaming (TEXT_MESSAGE_START, TEXT_MESSAGE_CONTENT, TEXT_MESSAGE_END)",
          tool: "Tool calls (TOOL_CALL_START, TOOL_CALL_ARGS, TOOL_CALL_END, TOOL_CALL_RESULT)",
          state: "Agent state (STATE_SNAPSHOT, STATE_DELTA, MESSAGES_SNAPSHOT)",
          activity: "Activity inference (ACTIVITY_SNAPSHOT, ACTIVITY_DELTA)",
          thinking: "Thinking display (THINKING_START, THINKING_END)",
          special: "Custom events (CUSTOM)",
          unknown: "Unmapped event types"
        }
      },
      deprecated_topics: @deprecated_topics,
      migrated_liveviews: @migrated_liveviews,
      new_subsystems: %{
        event_bus: "Centralized pub/sub with typed topics, wildcard matching, sequence numbering, replay",
        tool_call_tracker: "ETS-backed tool call lifecycle tracking with auto-prune",
        generative_ui: "Agent-declared dynamic UI components (card, chart, table, alert, progress, badge)",
        approval_gate: "Human-in-the-loop approval with pending/approve/reject/expire lifecycle",
        a2a_messaging: "Agent-to-Agent messaging with structured addressing, queues, correlation",
        websocket_channel: "Bidirectional WebSocket channel at ag_ui:lobby and ag_ui:{agent_id}",
        dashboard_state_sync: "Aggregated state deltas for dashboard real-time updates",
        activity_tracker: "Per-agent activity inference from event types",
        metrics_bridge: "EventBus → MetricsCollector counter bridge",
        audit_bridge: "EventBus → AuditLog lifecycle event recording",
        event_bus_health: "Periodic health checks, zero-subscriber warnings, diagnostics"
      },
      migration_steps: [
        "1. EventBus subscriptions already added alongside PubSub in all LiveViews",
        "2. V4Compat shim re-broadcasts EventBus events to legacy PubSub topics",
        "3. When ready, set :ag_ui_native_events to true to disable V4Compat",
        "4. Remove legacy PubSub.subscribe calls from LiveViews",
        "5. Update handle_info clauses to match {:event_bus, topic, event} format"
      ]
    })
  end
end
