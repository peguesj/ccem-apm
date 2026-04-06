defmodule ApmV5.Integrations.ClaudeFlow.ClaudeFlowIntegration do
  @moduledoc "Claude Flow integration — methodology workflow access from ~/.claude/methodologies/"

  @behaviour ApmV5.Integrations.IntegrationBehaviour

  @methodologies_path Path.expand("~/.claude/methodologies")

  @impl true
  def integration_name, do: "claude_flow"
  @impl true
  def integration_description, do: "Claude Flow — TDD, fix-loop, and ralph workflow orchestration"
  @impl true
  def integration_version, do: "1.0.0"
  @impl true
  def protocol, do: :custom
  @impl true
  def required_plugin, do: "ralph"
  @impl true
  def target_native_feature, do: :workflow_engine

  @impl true
  def connect(_config), do: {:ok, %{path: @methodologies_path}}
  @impl true
  def disconnect, do: :ok
  @impl true
  def status, do: if(File.dir?(@methodologies_path), do: :connected, else: :disconnected)

  @impl true
  def list_endpoints do
    [
      %{action: "list_workflows", description: "List available methodology workflows"},
      %{action: "get_workflow", description: "Get a specific workflow definition"},
      %{action: "trigger_workflow", description: "Trigger a workflow via PubSub"}
    ]
  end

  @impl true
  def handle_event("list_workflows", _payload, _opts) do
    workflows =
      Path.wildcard(Path.join(@methodologies_path, "*.md"))
      |> Enum.map(fn path -> %{name: Path.basename(path, ".md"), path: path} end)

    {:ok, %{workflows: workflows, count: length(workflows)}}
  end

  def handle_event("get_workflow", %{"name" => name}, _opts) do
    path = Path.join(@methodologies_path, "#{name}.md")

    case File.read(path) do
      {:ok, content} -> {:ok, %{name: name, content: content}}
      {:error, reason} -> {:error, "Failed to read #{name}: #{inspect(reason)}"}
    end
  end

  def handle_event("trigger_workflow", %{"name" => name}, _opts) do
    Phoenix.PubSub.broadcast(ApmV5.PubSub, "apm:workflows", {:workflow_triggered, name})
    {:ok, %{triggered: name, timestamp: DateTime.utc_now()}}
  end

  def handle_event(event, _payload, _opts), do: {:error, {:unknown_event, event}}

  @impl true
  def supervisor_children, do: []
end
