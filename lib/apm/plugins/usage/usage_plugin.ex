defmodule Apm.Plugins.Usage.UsagePlugin do
  @moduledoc """
  APM Plugin wrapping the ClaudeUsageStore.

  Exposes the following actions:
    - "summary"       — get overall usage summary with effort levels
    - "record"        — record a usage event for a project/model
    - "by_project"    — get usage breakdown for a specific project
    - "all_usage"     — get all usage data across projects
    - "reset_project" — reset usage counters for a specific project
  """

  @behaviour Apm.Plugins.PluginBehaviour

  alias Apm.ClaudeUsageStore

  # ── PluginBehaviour ──────────────────────────────────────────────────────────

  @impl true
  @spec plugin_name() :: String.t()
  def plugin_name, do: "usage"

  @impl true
  @spec plugin_description() :: String.t()
  def plugin_description,
    do: "Claude usage tracking — token consumption, effort levels, and project breakdowns"

  @impl true
  @spec plugin_version() :: String.t()
  def plugin_version, do: "1.0.0"

  @impl true
  @spec list_endpoints() :: [map()]
  def list_endpoints do
    [
      %{
        action: "summary",
        description: "Get overall usage summary with per-project effort levels",
        params: %{}
      },
      %{
        action: "record",
        description: "Record a usage event",
        params: %{project: "string", model: "string", input_tokens: "integer", output_tokens: "integer"}
      },
      %{
        action: "by_project",
        description: "Get usage breakdown for a specific project",
        params: %{project: "string"}
      },
      %{
        action: "all_usage",
        description: "Get all usage data across all projects",
        params: %{}
      },
      %{
        action: "reset_project",
        description: "Reset usage counters for a specific project",
        params: %{project: "string"}
      }
    ]
  end

  @impl true
  @spec handle_action(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def handle_action("summary", _params, _opts) do
    summary = ClaudeUsageStore.get_summary()
    {:ok, %{summary: summary}}
  end

  def handle_action("record", %{"project" => project, "model" => model} = params, _opts) do
    usage = %{
      input_tokens: Map.get(params, "input_tokens", 0),
      output_tokens: Map.get(params, "output_tokens", 0),
      tool_calls: Map.get(params, "tool_calls", 0)
    }

    ClaudeUsageStore.record_usage(project, model, usage)
    {:ok, %{status: "recorded", project: project, model: model}}
  end

  def handle_action("record", _params, _opts) do
    {:error, {:missing_param, "project and model are required"}}
  end

  def handle_action("by_project", %{"project" => project}, _opts) do
    usage = ClaudeUsageStore.get_usage(project)
    {:ok, %{project: project, usage: usage}}
  end

  def handle_action("by_project", _params, _opts) do
    {:error, {:missing_param, "project is required"}}
  end

  def handle_action("all_usage", _params, _opts) do
    all = ClaudeUsageStore.get_all_usage()
    {:ok, %{usage: all}}
  end

  def handle_action("reset_project", %{"project" => project}, _opts) do
    ClaudeUsageStore.reset_project(project)
    {:ok, %{status: "reset", project: project}}
  end

  def handle_action("reset_project", _params, _opts) do
    {:error, {:missing_param, "project is required"}}
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
