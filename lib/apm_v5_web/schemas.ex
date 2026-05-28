defmodule ApmV5Web.Schemas do
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
        status: ApmV5Web.Schemas.AgentStatus,
        registered_at: %Schema{type: :string, format: :"date-time"},
        last_heartbeat: %Schema{type: :string, format: :"date-time"},
        health_score: %Schema{type: :number, nullable: true, description: "0–100 health score"},
        formation_id: %Schema{type: :string, nullable: true},
        formation_role: %Schema{type: :string, nullable: true},
        parent_agent_id: %Schema{type: :string, nullable: true},
        wave: %Schema{type: :integer, nullable: true},
        task_subject: %Schema{type: :string, nullable: true},
        session_id: %Schema{type: :string, nullable: true},
        display_name: %Schema{type: :string, nullable: true, description: "Scoped label (e.g. ccem/wave-1/stripe-env)"}
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
        data: %Schema{type: :array, items: ApmV5Web.Schemas.Agent},
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
        tool_name: %Schema{type: :string},
        role: %Schema{type: :string, default: "agent"},
        params: %Schema{type: :object, additionalProperties: true, description: "Tool parameters"}
      },
      required: [:agent_id, :session_id, :tool_name]
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
        risk_level: ApmV5Web.Schemas.RiskLevel
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
        tool_name: %Schema{type: :string, description: "Tool name or glob pattern (e.g. '*', 'Bash')"},
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
        rules: %Schema{type: :array, items: ApmV5Web.Schemas.PolicyRule},
        policies: %Schema{
          type: :array,
          items: ApmV5Web.Schemas.PolicyRule,
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
        status: ApmV5Web.Schemas.ApprovalStatus,
        risk_level: ApmV5Web.Schemas.RiskLevel,
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
        approvals: %Schema{type: :array, items: ApmV5Web.Schemas.ApprovalGate}
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
        risk_level: ApmV5Web.Schemas.RiskLevel,
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
        action: ApmV5Web.Schemas.ControlAction
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
        action: ApmV5Web.Schemas.ControlAction,
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
        data: %Schema{type: :array, items: ApmV5Web.Schemas.ChatMessage},
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
end
