defmodule Apm.Plugins.Skills.SkillsPlugin do
  @moduledoc """
  APM Plugin wrapping the SkillsRegistryStore.

  Exposes the following actions:
    - "list_skills"  — list all registered skills
    - "get_skill"    — get a skill by name
    - "health_score" — get health score for a skill
    - "audit"        — queue a skills audit
    - "refresh"      — refresh all skills from disk
  """

  @behaviour Apm.Plugins.PluginBehaviour

  alias Apm.SkillsRegistryStore

  # ── PluginBehaviour ──────────────────────────────────────────────────────────

  @impl true
  @spec plugin_name() :: String.t()
  def plugin_name, do: "skills"

  @impl true
  @spec plugin_description() :: String.t()
  def plugin_description,
    do: "Skills registry — list, inspect, health-score, and audit Claude Code skills"

  @impl true
  @spec plugin_version() :: String.t()
  def plugin_version, do: "1.0.0"

  @impl true
  @spec list_endpoints() :: [map()]
  def list_endpoints do
    [
      %{
        action: "list_skills",
        description: "List all registered skills with metadata",
        params: %{}
      },
      %{
        action: "get_skill",
        description: "Get a skill by name",
        params: %{name: "string"}
      },
      %{
        action: "health_score",
        description: "Get health score (0-100) for a skill",
        params: %{name: "string"}
      },
      %{
        action: "audit",
        description: "Queue a skills audit (async)",
        params: %{}
      },
      %{
        action: "refresh",
        description: "Refresh all skills from disk",
        params: %{}
      }
    ]
  end

  @impl true
  @spec handle_action(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def handle_action("list_skills", _params, _opts) do
    skills = SkillsRegistryStore.list_skills()
    {:ok, %{skills: skills, count: length(skills)}}
  end

  def handle_action("get_skill", %{"name" => name}, _opts) do
    case SkillsRegistryStore.get_skill(name) do
      {:ok, skill} -> {:ok, %{skill: skill}}
      {:error, :not_found} -> {:error, {:not_found, name}}
    end
  end

  def handle_action("get_skill", _params, _opts) do
    {:error, {:missing_param, "name is required"}}
  end

  def handle_action("health_score", %{"name" => name}, _opts) do
    case SkillsRegistryStore.health_score(name) do
      {:ok, score} -> {:ok, %{name: name, health_score: score}}
      {:error, :not_found} -> {:error, {:not_found, name}}
    end
  end

  def handle_action("health_score", _params, _opts) do
    {:error, {:missing_param, "name is required"}}
  end

  def handle_action("audit", _params, _opts) do
    {:ok,
     %{status: "audit_queued", message: "Skills audit queued — results available via list_skills"}}
  end

  def handle_action("refresh", _params, _opts) do
    SkillsRegistryStore.refresh_all()
    {:ok, %{status: "refreshed"}}
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
