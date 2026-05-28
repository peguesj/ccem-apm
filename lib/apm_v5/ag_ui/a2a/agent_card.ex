defmodule ApmV5.AgUi.A2A.AgentCard do
  @moduledoc """
  A2A v0.3.0 AgentCard — the industry-standard agent capability advertisement
  served at `/.well-known/agent-card.json`.

  Spec: https://github.com/agent2agent/a2a (Google A2A v0.3.0, RC1 January 2026).

  Story `coord-a1` from v9.2.1 hotfix sprint.
  See `docs/drtw-governance/09-multi-agent-coordination.md`.

  ## Structure

  ```json
  {
    "name": "CCEM APM",
    "description": "Agentic Performance Monitor",
    "version": "9.2.0",
    "url": "http://localhost:3032",
    "protocolVersion": "0.3.0",
    "preferredTransport": "JSONRPC",
    "capabilities": {"streaming": true, "pushNotifications": false},
    "defaultInputModes": ["text/plain"],
    "defaultOutputModes": ["application/json"],
    "skills": [%AgentSkill{}],
    "authentication": {"schemes": ["Bearer"]}
  }
  ```
  """

  alias ApmV5.AgUi.A2A.AgentSkill
  alias ApmV5.AgentIdentity

  @protocol_version "0.3.0"

  @type t() :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          version: String.t(),
          url: String.t(),
          protocolVersion: String.t(),
          preferredTransport: String.t(),
          capabilities: map(),
          defaultInputModes: [String.t()],
          defaultOutputModes: [String.t()],
          skills: [AgentSkill.t()],
          authentication: map()
        }

  @derive Jason.Encoder
  defstruct name: "",
            description: "",
            version: "",
            url: "",
            protocolVersion: @protocol_version,
            preferredTransport: "JSONRPC",
            capabilities: %{streaming: true, pushNotifications: false},
            defaultInputModes: ["text/plain"],
            defaultOutputModes: ["application/json"],
            skills: [],
            authentication: %{schemes: ["Bearer"]}

  @doc """
  Returns the AgentCard for the APM server itself — what gets served at
  `/.well-known/agent-card.json`.
  """
  @spec apm_card(String.t()) :: t()
  def apm_card(base_url \\ "http://localhost:3032") do
    version = ApmV5.AppVersion.current()

    %__MODULE__{
      name: "CCEM APM",
      description:
        "Agentic Performance Monitor — multi-agent formation orchestration, " <>
          "authorization, observability, and governance for Claude Code agents.",
      version: version,
      url: base_url,
      skills: [
        AgentSkill.new(
          id: "agent-register",
          name: "Agent Registration",
          description: "Register an agent with formation context and trust ceiling",
          inputModes: ["application/json"],
          outputModes: ["application/json"],
          tags: ["lifecycle", "agentlock"],
          examples: ["POST /api/register"]
        ),
        AgentSkill.new(
          id: "a2a-send",
          name: "A2A Message Delivery",
          description: "Deliver A2A envelopes with typed addressing (agent/formation/topic)",
          inputModes: ["application/json"],
          outputModes: ["application/json"],
          tags: ["a2a", "messaging"],
          examples: ["POST /api/v2/a2a/send", "GET /api/v2/a2a/stream/:agent_id"]
        ),
        AgentSkill.new(
          id: "formation-orchestrate",
          name: "Formation Orchestration",
          description:
            "Create, deploy, and monitor multi-wave agent formations with squadron/swarm/cluster hierarchy",
          inputModes: ["application/json"],
          outputModes: ["application/json"],
          tags: ["formation", "orchestration", "upm"],
          examples: ["POST /api/v2/formations", "GET /api/v2/formations/:id"]
        ),
        AgentSkill.new(
          id: "authorization-gate",
          name: "Authorization Gating",
          description:
            "Pre-tool-use authorization decisions via PolicyEngine, trust ceiling, and approval gates",
          inputModes: ["application/json"],
          outputModes: ["application/json"],
          tags: ["agentlock", "security", "policy"],
          examples: ["POST /api/v2/auth/authorize"]
        ),
        AgentSkill.new(
          id: "approval-workflow",
          name: "Human Approval Workflow",
          description: "20-second TTL countdown approval gates with sticky policy rules",
          inputModes: ["application/json"],
          outputModes: ["application/json"],
          tags: ["approval", "human-in-the-loop"],
          examples: ["GET /api/v2/auth/approvals/pending"]
        )
      ]
    }
  end

  @doc """
  Generates an AgentCard from an AgentIdentity struct — the response shape for
  `GET /api/v2/agents/:agent_id/agent-card.json`.
  """
  @spec from_identity(AgentIdentity.t(), String.t()) :: t()
  def from_identity(%AgentIdentity{} = identity, base_url \\ "http://localhost:3032") do
    %__MODULE__{
      name: identity.agent_name || identity.display_name || identity.agent_id,
      description: identity.agent_description || identity.display_name || "",
      version: identity.agent_version || ApmV5.AppVersion.current(),
      url: "#{base_url}/api/v2/agents/#{identity.agent_id}",
      skills: identity_to_skills(identity)
    }
  end

  defp identity_to_skills(%AgentIdentity{skills: skills})
       when is_list(skills) and skills != [] do
    Enum.map(skills, &AgentSkill.from_map/1)
  end

  defp identity_to_skills(%AgentIdentity{role: role, agent_type: agent_type}) do
    # Derive a single skill from role/type when no explicit skills are declared.
    [
      AgentSkill.new(
        id: role || agent_type || "default",
        name: role || agent_type || "Default Capability",
        description: "Role-derived skill for #{role || agent_type || "agent"}",
        tags: Enum.reject([role, agent_type], &is_nil/1) ++ ["derived"]
      )
    ]
  end

  defp identity_to_skills(_), do: []
end
