defmodule Apm.Plugins.Builder.BuilderPlugin do
  @moduledoc """
  CCEM APM Builder plugin.

  Interactive wizard that walks users through creating a new CCEM plugin from
  an existing repository (GitHub URL, local path, or .git path).
  """

  @behaviour Apm.Plugins.PluginBehaviour

  alias Apm.Plugins.Builder.BuilderEngine

  @plugin_version "1.0.0"

  @impl true
  def plugin_name, do: "builder"

  @impl true
  def plugin_description, do: "Interactive wizard to scaffold CCEM plugins from existing repositories"

  @impl true
  def plugin_version, do: @plugin_version

  @impl true
  def plugin_scope, do: :ccem

  @impl true
  def list_endpoints do
    [
      %{action: "start_session", description: "Start a new Builder wizard session", params: %{}},
      %{action: "get_session", description: "Get session by ID", params: %{id: "string"}},
      %{
        action: "update_session",
        description: "Update session fields",
        params: %{id: "string", attrs: "map"}
      },
      %{
        action: "analyze_source",
        description: "Trigger async source analysis",
        params: %{id: "string"}
      },
      %{
        action: "generate_preview",
        description: "Generate plugin code and SKILL.md preview",
        params: %{id: "string"}
      }
    ]
  end

  @impl true
  def handle_action("start_session", _params, _opts) do
    BuilderEngine.start_session()
  end

  def handle_action("get_session", %{"id" => id}, _opts) do
    BuilderEngine.get_session(id)
  end

  def handle_action("update_session", %{"id" => id, "attrs" => attrs}, _opts) do
    BuilderEngine.update_session(id, attrs)
  end

  def handle_action("analyze_source", %{"id" => id}, _opts) do
    BuilderEngine.analyze_source(id)
  end

  def handle_action("generate_preview", %{"id" => id}, _opts) do
    BuilderEngine.generate_preview(id)
  end

  def handle_action(action, _params, _opts) do
    {:error, {:unknown_action, action}}
  end

  @impl true
  def supervisor_children do
    [BuilderEngine]
  end

  @impl true
  def live_views do
    [{"/plugins/builder", ApmWeb.BuilderLive, [as: :builder_live]}]
  end

  @impl true
  def nav_items do
    [{"builder", "/plugins/builder", "hero-wrench-screwdriver"}]
  end

  @impl true
  def dashboard_widgets do
    []
  end
end
