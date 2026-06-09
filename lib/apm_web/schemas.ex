defmodule ApmWeb.Schemas do
  @moduledoc """
  OpenAPI schema modules for open_api_spex annotations (CP-262 / US-494).

  Wave 1 schemas cover the 4 annotated controllers:
  - ApiV2Controller (status, list_agents, get_agent)
  - AuthController (authorize, list_policy_rules)
  - ApprovalController (index, show, request, approve, reject)
  - AgentControlController (control_agent, list_messages, send_message)

  Additional schemas will be added in api-s7 (v9.4.0).
  """

  require OpenApiSpex
  alias OpenApiSpex.Schema

  # ---------------------------------------------------------------------------
  # Common / shared
  # ---------------------------------------------------------------------------

  defmodule ErrorResponse do
    @moduledoc "Standard error envelope"
    OpenApiSpex.schema(%{
      title: "ErrorResponse",
      description: "Standard error response",
      type: :object,
      properties: %{
        error: %Schema{type: :string, description: "Error code or message"},
        detail: %Schema{type: :string, description: "Human-readable detail", nullable: true}
      },
      required: [:error]
    })
  end

  defmodule OkResponse do
    @moduledoc "Generic ok: true response"
    OpenApiSpex.schema(%{
      title: "OkResponse",
      type: :object,
      properties: %{
        ok: %Schema{type: :boolean, example: true}
      },
      required: [:ok]
    })
  end

  # ---------------------------------------------------------------------------
  # Agent schemas
  # ---------------------------------------------------------------------------

  defmodule AgentStatus do
    @moduledoc "Agent status enum"
    OpenApiSpex.schema(%{
      title: "AgentStatus",
      type: :string,
      enum: ["active", "idle", "error", "offline"],
      description: "Current lifecycle state of an agent"
    })
  end

  defmodule Agent do
    @moduledoc "Registered agent"
    OpenApiSpex.schema(%{
      title: "Agent",
      description: "A registered agent in the APM system",
      type: :object,
      properties: %{
        id: %Schema{type: :string, description: "Unique agent identifier"},
        name: %Schema{type: :string, description: "Human-readable agent name"},
        project: %Schema{type: :string},
        role: %Schema{type: :string, description: "Agent role (orchestrator, squadron_lead, …)"},
        status: ApmWeb.Schemas.AgentStatus,
        registered_at: %Schema{type: :string, format: :"date-time"},
        last_heartbeat: %Schema{type: :string, format: :"date-time"},
        health_score: %Schema{type: :number, nullable: true, description: "0–100 health score"},
        formation_id: %Schema{type: :string, nullable: true},
        formation_role: %Schema{type: :string, nullable: true},
        parent_agent_id: %Schema{type: :string, nullable: true},
        wave: %Schema{type: :integer, nullable: true},
        task_subject: %Schema{type: :string, nullable: true},
        session_id: %Schema{type: :string, nullable: true},
        display_name: %Schema{
          type: :string,
          nullable: true,
          description: "Scoped label (e.g. ccem/wave-1/stripe-env)"
        }
      },
      required: [:id, :name, :project, :role, :status, :registered_at, :last_heartbeat]
    })
  end

  defmodule AgentList do
    @moduledoc "Paginated agent list"
    OpenApiSpex.schema(%{
      title: "AgentList",
      type: :object,
      properties: %{
        data: %Schema{type: :array, items: ApmWeb.Schemas.Agent},
        meta: %Schema{
          type: :object,
          properties: %{
            total: %Schema{type: :integer},
            cursor: %Schema{type: :string, nullable: true},
            has_more: %Schema{type: :boolean}
          }
        },
        links: %Schema{type: :object, additionalProperties: %Schema{type: :string}}
      }
    })
  end

  defmodule StatusResponse do
    @moduledoc "Server status response"
    OpenApiSpex.schema(%{
      title: "StatusResponse",
      description: "APM server status and summary",
      type: :object,
      properties: %{
        status: %Schema{type: :string, enum: ["ok"], example: "ok"},
        version: %Schema{type: :string, example: "9.2.1"},
        agents: %Schema{type: :integer, description: "Total registered agents"},
        sessions: %Schema{type: :integer},
        uptime_s: %Schema{type: :number, description: "Server uptime in seconds", nullable: true}
      },
      required: [:status, :version]
    })
  end

  # ---------------------------------------------------------------------------
  # Auth schemas
  # ---------------------------------------------------------------------------

  defmodule RiskLevel do
    @moduledoc "Risk level enum"
    OpenApiSpex.schema(%{
      title: "RiskLevel",
      type: :string,
      enum: ["low", "medium", "high", "critical"]
    })
  end

  defmodule AuthorizeRequest do
    @moduledoc "POST /api/v2/auth/authorize request body"
    OpenApiSpex.schema(%{
      title: "AuthorizeRequest",
      type: :object,
      properties: %{
        agent_id: %Schema{type: :string},
        session_id: %Schema{type: :string},
        tool_name: %Schema{
          type: :string,
          description: "Preferred field; falls back to 'tool' for v9.x callers"
        },
        tool: %Schema{type: :string, description: "v9.x compat alias for tool_name"},
        role: %Schema{type: :string, default: "agent"},
        params: %Schema{type: :object, additionalProperties: true, description: "Tool parameters"},
        args: %Schema{
          type: :object,
          additionalProperties: true,
          description: "v9.x compat alias for params"
        },
        trust_requested: %Schema{type: :string, description: "v9.x compat; APM auto-downgrades"}
      },
      required: [:agent_id, :session_id]
    })
  end

  defmodule AuthDecision do
    @moduledoc "Authorization decision result"
    OpenApiSpex.schema(%{
      title: "AuthDecision",
      description: "Result of an authorization request",
      type: :object,
      properties: %{
        ok: %Schema{type: :boolean},
        allowed: %Schema{type: :boolean},
        decision: %Schema{type: :string, enum: ["allow", "deny", "ask"]},
        auth_token: %Schema{type: :string, nullable: true},
        token_id: %Schema{type: :string, nullable: true},
        reason: %Schema{type: :string, nullable: true},
        detail: %Schema{type: :string, nullable: true},
        risk_level: ApmWeb.Schemas.RiskLevel
      },
      required: [:ok, :allowed, :decision]
    })
  end

  defmodule PolicyRule do
    @moduledoc """
    A policy rule definition.

    Reflects the actual PolicyRulesStore.list_rules/0 response shape:
    %{tool_name: string, action: atom_as_string, inserted_at: datetime_string}.
    (api-s6: aligned to real store output — api-s7 may add id/tool_pattern aliases)
    """
    OpenApiSpex.schema(%{
      title: "PolicyRule",
      type: :object,
      properties: %{
        tool_name: %Schema{
          type: :string,
          description: "Tool name or glob pattern (e.g. '*', 'Bash')"
        },
        action: %Schema{
          type: :string,
          enum: ["always_allow", "always_deny", "permit", "deny", "escalate"],
          description: "Policy action for the tool"
        },
        inserted_at: %Schema{type: :string, format: :"date-time", nullable: true}
      },
      required: [:tool_name, :action]
    })
  end

  defmodule PolicyRuleList do
    @moduledoc "List of policy rules"
    OpenApiSpex.schema(%{
      title: "PolicyRuleList",
      type: :object,
      properties: %{
        ok: %Schema{type: :boolean, nullable: true},
        rules: %Schema{type: :array, items: ApmWeb.Schemas.PolicyRule},
        policies: %Schema{
          type: :array,
          items: ApmWeb.Schemas.PolicyRule,
          nullable: true,
          description: "Alias for rules (apm-auth skill compat)"
        },
        count: %Schema{type: :integer, nullable: true},
        total: %Schema{type: :integer, nullable: true}
      }
    })
  end

  # ---------------------------------------------------------------------------
  # Approval schemas
  # ---------------------------------------------------------------------------

  defmodule ApprovalStatus do
    @moduledoc "Approval status enum"
    OpenApiSpex.schema(%{
      title: "ApprovalStatus",
      type: :string,
      enum: ["pending", "approved", "rejected", "timeout"]
    })
  end

  defmodule ApprovalGate do
    @moduledoc "An approval gate / request"
    OpenApiSpex.schema(%{
      title: "ApprovalGate",
      description: "Approval gate for a tool invocation (v9.0.0)",
      type: :object,
      properties: %{
        id: %Schema{type: :string},
        agent_id: %Schema{type: :string},
        tool_name: %Schema{type: :string},
        status: ApmWeb.Schemas.ApprovalStatus,
        risk_level: ApmWeb.Schemas.RiskLevel,
        session_id: %Schema{type: :string, nullable: true},
        display_name: %Schema{type: :string, nullable: true},
        group_key: %Schema{type: :string, nullable: true},
        inserted_at: %Schema{type: :string, format: :"date-time"},
        expires_at: %Schema{type: :string, format: :"date-time", nullable: true},
        decided_at: %Schema{type: :string, format: :"date-time", nullable: true},
        decision: %Schema{type: :string, nullable: true}
      },
      required: [:id, :agent_id, :tool_name, :status]
    })
  end

  defmodule ApprovalList do
    @moduledoc "List of approval gates"
    OpenApiSpex.schema(%{
      title: "ApprovalList",
      type: :object,
      properties: %{
        approvals: %Schema{type: :array, items: ApmWeb.Schemas.ApprovalGate}
      }
    })
  end

  defmodule ApprovalRequestBody do
    @moduledoc "POST /api/v2/approvals/request body"
    OpenApiSpex.schema(%{
      title: "ApprovalRequestBody",
      type: :object,
      properties: %{
        agent_id: %Schema{type: :string},
        tool_name: %Schema{type: :string},
        risk_level: ApmWeb.Schemas.RiskLevel,
        session_id: %Schema{type: :string, nullable: true},
        params: %Schema{type: :object, additionalProperties: true, nullable: true}
      },
      required: [:agent_id, :tool_name]
    })
  end

  defmodule ApprovalRequestResult do
    @moduledoc "Result of POST /api/v2/approvals/request"
    OpenApiSpex.schema(%{
      title: "ApprovalRequestResult",
      type: :object,
      properties: %{
        gate_id: %Schema{type: :string},
        status: %Schema{type: :string, example: "pending"}
      },
      required: [:gate_id, :status]
    })
  end

  defmodule ApproveBody do
    @moduledoc "POST /api/v2/approvals/:id/approve body"
    OpenApiSpex.schema(%{
      title: "ApproveBody",
      type: :object,
      properties: %{
        approver: %Schema{type: :object, additionalProperties: true, nullable: true}
      }
    })
  end

  defmodule RejectBody do
    @moduledoc "POST /api/v2/approvals/:id/reject body"
    OpenApiSpex.schema(%{
      title: "RejectBody",
      type: :object,
      properties: %{
        reason: %Schema{type: :string, description: "Rejection reason"}
      }
    })
  end

  defmodule ApprovalDecisionResult do
    @moduledoc "Response for approve/reject actions"
    OpenApiSpex.schema(%{
      title: "ApprovalDecisionResult",
      type: :object,
      properties: %{
        status: %Schema{type: :string, enum: ["approved", "rejected"]}
      },
      required: [:status]
    })
  end

  # ---------------------------------------------------------------------------
  # Agent control schemas
  # ---------------------------------------------------------------------------

  defmodule ControlAction do
    @moduledoc "Agent control action enum"
    OpenApiSpex.schema(%{
      title: "ControlAction",
      type: :string,
      enum: ["connect", "disconnect", "restart", "stop", "pause", "resume"]
    })
  end

  defmodule ControlAgentBody do
    @moduledoc "POST /api/v2/agents/:id/control body"
    OpenApiSpex.schema(%{
      title: "ControlAgentBody",
      type: :object,
      properties: %{
        action: ApmWeb.Schemas.ControlAction
      },
      required: [:action]
    })
  end

  defmodule ControlAgentResult do
    @moduledoc "Response from agent control action"
    OpenApiSpex.schema(%{
      title: "ControlAgentResult",
      type: :object,
      properties: %{
        ok: %Schema{type: :boolean},
        agent_id: %Schema{type: :string},
        action: ApmWeb.Schemas.ControlAction,
        result: %Schema{type: :object, additionalProperties: true}
      },
      required: [:ok, :agent_id, :action]
    })
  end

  defmodule ChatMessage do
    @moduledoc "A chat message in an agent's message channel"
    OpenApiSpex.schema(%{
      title: "ChatMessage",
      type: :object,
      properties: %{
        id: %Schema{type: :string},
        scope: %Schema{type: :string, description: "Channel scope (e.g. agent:agent-id)"},
        role: %Schema{type: :string, enum: ["user", "assistant", "system"]},
        content: %Schema{type: :string},
        inserted_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :scope, :role, :content]
    })
  end

  defmodule MessageList do
    @moduledoc "List of agent messages"
    OpenApiSpex.schema(%{
      title: "MessageList",
      type: :object,
      properties: %{
        data: %Schema{type: :array, items: ApmWeb.Schemas.ChatMessage},
        agent_id: %Schema{type: :string},
        total: %Schema{type: :integer}
      }
    })
  end

  defmodule SendMessageBody do
    @moduledoc "POST /api/v2/agents/:id/messages body"
    OpenApiSpex.schema(%{
      title: "SendMessageBody",
      type: :object,
      properties: %{
        content: %Schema{type: :string, description: "Message content"},
        role: %Schema{type: :string, enum: ["user", "assistant", "system"], default: "user"}
      },
      required: [:content]
    })
  end

  # ---------------------------------------------------------------------------
  # api-s7 Wave 2 — Schemas ported from legacy build_spec/0 (CP-288)
  #
  # These mirror the 22 schemas previously hand-rolled in
  # `ApiV2Controller.build_schemas/0`. They preserve the exact field shapes
  # (names, types, formats, descriptions, enums) so the generated
  # `/api/v2/openapi.json` remains backward-compatible with the v9.x snapshot
  # at `priv/static/openapi.base.json`.
  #
  # Where a name collides with a Wave 1 module (Agent, AuthDecision) we keep
  # the Wave 1 typed-modern variant under its short name and the legacy variant
  # under `Legacy<Name>` so external clients pinned to the previous payload
  # shape continue to validate.
  # ---------------------------------------------------------------------------

  defmodule Error do
    @moduledoc "Legacy build_spec/0 error envelope"
    OpenApiSpex.schema(%{
      title: "Error",
      type: :object,
      properties: %{
        error: %Schema{type: :string},
        message: %Schema{type: :string}
      }
    })
  end

  defmodule LegacyAgent do
    @moduledoc """
    Legacy build_spec/0 Agent shape — preserves the 8-property contract used by
    `/api/agents`, `/api/agents/register`, etc. The Wave 1 `Agent` schema (above)
    is the modern typed variant referenced by `/api/v2/agents`.
    """
    OpenApiSpex.schema(%{
      title: "Agent",
      type: :object,
      properties: %{
        id: %Schema{type: :string},
        name: %Schema{type: :string},
        status: %Schema{type: :string, enum: ["active", "idle", "error", "offline"]},
        project: %Schema{type: :string},
        role: %Schema{type: :string},
        last_heartbeat: %Schema{type: :string, format: :"date-time"},
        registered_at: %Schema{type: :string, format: :"date-time"},
        display_name: %Schema{
          type: :string,
          nullable: true,
          description:
            "Human-readable scoped label for the agent (e.g. ccem/wave-1/stripe-env). Null if context unavailable."
        }
      }
    })
  end

  defmodule PaginatedAgents do
    @moduledoc "Paginated agent list — legacy v1 shape"
    OpenApiSpex.schema(%{
      title: "PaginatedAgents",
      type: :object,
      properties: %{
        data: %Schema{type: :array, items: ApmWeb.Schemas.LegacyAgent},
        meta: %Schema{
          type: :object,
          properties: %{
            total: %Schema{type: :integer},
            cursor: %Schema{type: :string},
            has_more: %Schema{type: :boolean}
          }
        }
      }
    })
  end

  defmodule Notification do
    @moduledoc "Notification record"
    OpenApiSpex.schema(%{
      title: "Notification",
      type: :object,
      properties: %{
        id: %Schema{type: :string},
        message: %Schema{type: :string},
        type: %Schema{type: :string},
        read: %Schema{type: :boolean},
        timestamp: %Schema{type: :string, format: :"date-time"}
      }
    })
  end

  defmodule AlertRule do
    @moduledoc "Alert rule definition"
    OpenApiSpex.schema(%{
      title: "AlertRule",
      type: :object,
      properties: %{
        id: %Schema{type: :string},
        name: %Schema{type: :string},
        metric: %Schema{type: :string},
        scope: %Schema{type: :string},
        threshold: %Schema{type: :number},
        comparator: %Schema{type: :string, enum: ["gt", "gte", "lt", "lte", "eq"]},
        severity: %Schema{type: :string, enum: ["info", "warning", "critical"]},
        enabled: %Schema{type: :boolean},
        consecutive_breaches: %Schema{type: :integer},
        window_s: %Schema{type: :integer}
      }
    })
  end

  defmodule Alert do
    @moduledoc "Alert occurrence"
    OpenApiSpex.schema(%{
      title: "Alert",
      type: :object,
      properties: %{
        id: %Schema{type: :string},
        rule_id: %Schema{type: :string},
        value: %Schema{type: :number},
        severity: %Schema{type: :string, enum: ["info", "warning", "critical"]},
        timestamp: %Schema{type: :string, format: :"date-time"},
        acknowledged: %Schema{type: :boolean}
      }
    })
  end

  defmodule SLO do
    @moduledoc "Service Level Objective record"
    OpenApiSpex.schema(%{
      title: "SLO",
      type: :object,
      properties: %{
        name: %Schema{type: :string},
        target: %Schema{type: :number},
        current: %Schema{type: :number},
        status: %Schema{type: :string, enum: ["ok", "at_risk", "breached"]},
        error_budget_remaining: %Schema{type: :number}
      }
    })
  end

  defmodule AuditEntry do
    @moduledoc "Audit log entry"
    OpenApiSpex.schema(%{
      title: "AuditEntry",
      type: :object,
      properties: %{
        id: %Schema{type: :string},
        action: %Schema{type: :string},
        actor: %Schema{type: :string},
        resource: %Schema{type: :string},
        timestamp: %Schema{type: :string, format: :"date-time"},
        metadata: %Schema{type: :object, additionalProperties: true}
      }
    })
  end

  defmodule PaginatedResponse do
    @moduledoc "Generic paginated response (legacy)"
    OpenApiSpex.schema(%{
      title: "PaginatedResponse",
      type: :object,
      properties: %{
        data: %Schema{type: :array, items: %Schema{}},
        next_cursor: %Schema{type: :string},
        total: %Schema{type: :integer}
      }
    })
  end

  defmodule PendingDecision do
    @moduledoc "AgentLock pending authorization request (v8.5.0)"
    OpenApiSpex.schema(%{
      title: "PendingDecision",
      description: "AgentLock pending authorization request (v8.5.0)",
      type: :object,
      properties: %{
        request_id: %Schema{type: :string},
        tool_name: %Schema{type: :string},
        session_id: %Schema{type: :string},
        agent_id: %Schema{type: :string},
        risk_level: %Schema{type: :string, enum: ["low", "medium", "high", "critical"]},
        params: %Schema{type: :object, additionalProperties: true},
        status: %Schema{type: :string, enum: ["pending", "approved", "denied", "timeout"]},
        decision: %Schema{type: :string, nullable: true},
        token_id: %Schema{type: :string, nullable: true},
        display_name: %Schema{
          type: :string,
          nullable: true,
          description:
            "Human-readable scoped label for the requesting agent (e.g. ccem/wave-1/stripe-env). Null if context unavailable."
        },
        decided_at: %Schema{type: :string, format: :"date-time", nullable: true},
        inserted_at: %Schema{type: :string, format: :"date-time"},
        expires_at: %Schema{type: :string, format: :"date-time"}
      }
    })
  end

  defmodule LegacyAuthDecision do
    @moduledoc """
    Legacy build_spec/0 AuthDecision — uses the older `permit|deny|escalate`
    enum from the AgentLock v8 protocol. The Wave 1 `AuthDecision` schema
    (above) uses the newer `allow|deny|ask` enum.
    """
    OpenApiSpex.schema(%{
      title: "AuthDecision",
      type: :object,
      properties: %{
        ok: %Schema{type: :boolean},
        decision: %Schema{type: :string, enum: ["permit", "deny", "escalate"]},
        token_id: %Schema{type: :string},
        reason: %Schema{type: :string},
        risk_level: %Schema{type: :string, enum: ["low", "medium", "high", "critical"]}
      }
    })
  end

  defmodule AuthTool do
    @moduledoc "Registered AgentLock tool descriptor"
    OpenApiSpex.schema(%{
      title: "AuthTool",
      type: :object,
      properties: %{
        name: %Schema{type: :string},
        risk_level: %Schema{type: :string, enum: ["low", "medium", "high", "critical"]},
        description: %Schema{type: :string},
        requires_approval: %Schema{type: :boolean},
        registered_at: %Schema{type: :string, format: :"date-time"}
      }
    })
  end

  defmodule AuthSession do
    @moduledoc "AgentLock authorization session"
    OpenApiSpex.schema(%{
      title: "AuthSession",
      type: :object,
      properties: %{
        session_id: %Schema{type: :string},
        user_id: %Schema{type: :string},
        role: %Schema{type: :string},
        trust_ceiling: %Schema{type: :string},
        scope: %Schema{type: :string},
        tool_calls: %Schema{type: :integer},
        denied_count: %Schema{type: :integer},
        created_at: %Schema{type: :string, format: :"date-time"},
        expires_at: %Schema{type: :string, format: :"date-time"}
      }
    })
  end

  defmodule Gate do
    @moduledoc "UPM decision gate record"
    OpenApiSpex.schema(%{
      title: "Gate",
      description: "UPM decision gate record",
      type: :object,
      properties: %{
        gate_id: %Schema{type: :string},
        question: %Schema{type: :string},
        context: %Schema{type: :string},
        options: %Schema{type: :array, items: %Schema{type: :string}},
        status: %Schema{type: :string, enum: ["pending", "approved", "rejected", "timeout"]},
        decision: %Schema{type: :string},
        method: %Schema{type: :string},
        requested_at: %Schema{type: :string, format: :"date-time"},
        resolved_at: %Schema{type: :string, format: :"date-time"}
      }
    })
  end

  defmodule GateDecision do
    @moduledoc "Result of a blocking gate request"
    OpenApiSpex.schema(%{
      title: "GateDecision",
      description: "Result of a blocking gate request",
      type: :object,
      properties: %{
        decision: %Schema{type: :string, enum: ["approved", "rejected", "timeout"]},
        method: %Schema{type: :string},
        reason: %Schema{type: :string},
        gate_id: %Schema{type: :string},
        question: %Schema{type: :string}
      }
    })
  end

  defmodule AgentContext do
    @moduledoc "Real-time AG-UI context for an agent (v8.4.0)"
    OpenApiSpex.schema(%{
      title: "AgentContext",
      description: "Real-time AG-UI context for an agent (v8.4.0)",
      type: :object,
      properties: %{
        agent_id: %Schema{type: :string},
        current_tool: %Schema{type: :string},
        current_phase: %Schema{type: :string},
        formation_id: %Schema{type: :string},
        squadron_id: %Schema{type: :string},
        upm_story_id: %Schema{type: :string},
        last_event_type: %Schema{type: :string},
        updated_at: %Schema{type: :string, format: :"date-time"}
      }
    })
  end

  defmodule ToolCallSummary do
    @moduledoc "Abbreviated tool call for context endpoints"
    OpenApiSpex.schema(%{
      title: "ToolCallSummary",
      description: "Abbreviated tool call for context endpoints",
      type: :object,
      properties: %{
        tool_call_id: %Schema{type: :string},
        tool_name: %Schema{type: :string},
        status: %Schema{type: :string, enum: ["pending", "running", "completed", "failed"]},
        started_at: %Schema{type: :string, format: :"date-time"},
        duration_ms: %Schema{type: :integer}
      }
    })
  end

  defmodule CoalesceRunSummary do
    @moduledoc "Summary of a Coalesce run"
    OpenApiSpex.schema(%{
      title: "CoalesceRunSummary",
      description: "Summary of a Coalesce run",
      type: :object,
      properties: %{
        run_id: %Schema{type: :string},
        status: %Schema{type: :string},
        scope: %Schema{type: :string},
        dry_run: %Schema{type: :boolean},
        affected_skill_count: %Schema{type: :integer},
        diff_count: %Schema{type: :integer},
        started_at: %Schema{type: :string, format: :"date-time"},
        completed_at: %Schema{type: :string, format: :"date-time"}
      }
    })
  end

  defmodule ExecutionContext do
    @moduledoc "Execution context for an approval request (v9.0.0)"
    OpenApiSpex.schema(%{
      title: "ExecutionContext",
      description:
        "Execution context for an approval request — describes what the tool will do and its impact",
      type: :object,
      properties: %{
        tool_name: %Schema{type: :string, description: "Name of the tool requesting approval"},
        tool_purpose: %Schema{
          type: :string,
          description: "Human-readable description of what the tool will do"
        },
        affected_files: %Schema{
          type: :array,
          items: %Schema{type: :string},
          description: "File paths that will be read, written, or deleted"
        },
        estimated_impact: %Schema{
          type: :string,
          enum: ["low", "medium", "high", "critical"],
          description: "Estimated impact level of the operation"
        }
      }
    })
  end

  defmodule ApprovalRequest do
    @moduledoc "Approval request with execution context for grouped notification display (v9.0.0)"
    OpenApiSpex.schema(%{
      title: "ApprovalRequest",
      description:
        "Approval request with execution context for grouped notification display (v9.0.0)",
      type: :object,
      properties: %{
        id: %Schema{type: :string},
        agent_id: %Schema{type: :string},
        session_id: %Schema{type: :string},
        tool_name: %Schema{type: :string},
        risk_level: %Schema{type: :string, enum: ["low", "medium", "high", "critical"]},
        status: %Schema{type: :string, enum: ["pending", "approved", "rejected", "timeout"]},
        execution_context: ApmWeb.Schemas.ExecutionContext,
        display_name: %Schema{
          type: :string,
          nullable: true,
          description: "Human-readable agent label"
        },
        keyboard_shortcuts: %Schema{
          type: :object,
          description: "Available keyboard shortcuts for this approval",
          properties: %{
            approve: %Schema{type: :string, example: "Cmd+Y", description: "Shortcut to approve"},
            reject: %Schema{type: :string, example: "Cmd+N", description: "Shortcut to reject"},
            details: %Schema{
              type: :string,
              example: "Cmd+D",
              description: "Shortcut to view details"
            },
            dismiss: %Schema{
              type: :string,
              example: "Escape",
              description: "Shortcut to dismiss modal"
            }
          }
        },
        group_key: %Schema{
          type: :string,
          nullable: true,
          description: "Grouping key for batched notifications (e.g. agent_id or tool_name)"
        },
        decision: %Schema{type: :string, nullable: true},
        decided_at: %Schema{type: :string, format: :"date-time", nullable: true},
        inserted_at: %Schema{type: :string, format: :"date-time"},
        expires_at: %Schema{type: :string, format: :"date-time"}
      }
    })
  end

  defmodule ApprovalAuditEntry do
    @moduledoc "Audit log entry for an approval decision (v9.0.0)"
    OpenApiSpex.schema(%{
      title: "ApprovalAuditEntry",
      description: "Audit log entry for an approval decision (v9.0.0)",
      type: :object,
      properties: %{
        id: %Schema{type: :string},
        agent_id: %Schema{type: :string},
        tool_name: %Schema{type: :string},
        timestamp: %Schema{type: :string, format: :"date-time"},
        decision: %Schema{type: :string, enum: ["approved", "rejected", "timeout"]},
        context_snapshot: ApmWeb.Schemas.ExecutionContext,
        reason: %Schema{type: :string, nullable: true},
        method: %Schema{
          type: :string,
          description: "How the decision was made",
          enum: ["keyboard_shortcut", "button_click", "api", "auto_approval", "timeout"]
        },
        session_id: %Schema{type: :string},
        risk_level: %Schema{type: :string, enum: ["low", "medium", "high", "critical"]}
      }
    })
  end

  defmodule Observation do
    @moduledoc "A claude-mem observation from the ObservationCache or claude-mem worker"
    OpenApiSpex.schema(%{
      title: "Observation",
      description: "A claude-mem observation from the ObservationCache or claude-mem worker",
      type: :object,
      properties: %{
        id: %Schema{type: :string, description: "Unique observation ID"},
        content: %Schema{type: :string, description: "Observation text content"},
        session_id: %Schema{
          type: :string,
          nullable: true,
          description: "Associated session ID"
        },
        agent_id: %Schema{
          type: :string,
          nullable: true,
          description: "Agent that produced this observation"
        },
        tags: %Schema{
          type: :array,
          items: %Schema{type: :string},
          description: "Classification tags"
        },
        metadata: %Schema{
          type: :object,
          additionalProperties: true,
          description: "Arbitrary observation metadata"
        },
        inserted_at: %Schema{
          type: :string,
          format: :"date-time",
          description: "When the observation was recorded"
        },
        updated_at: %Schema{
          type: :string,
          format: :"date-time",
          nullable: true,
          description: "Last update timestamp"
        }
      }
    })
  end
end
