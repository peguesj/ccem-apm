defmodule ApmV5.Plugins.OpenDesign.OpenDesignPlugin do
  @moduledoc """
  CCEM APM plugin for open-design (https://github.com/nexu-io/open-design).

  open-design is a local-first, open-source alternative to Anthropic's Claude Design.
  It runs a local daemon (default port 17456) that:
  - Detects installed agent CLIs (Claude Code, Codex, Cursor, Gemini, etc.)
  - Serves a skill registry from ~/.claude/skills/ and ./skills/
  - Manages design systems (DESIGN.md files), projects, and artifact templates
  - Streams agent runs and exposes artifacts (HTML, PDF, PPTX, etc.)

  This plugin provides:
  - Daemon reachability monitoring via OpenDesignMonitor GenServer (30s poll)
  - Actions: health, agents, skills, design_systems, projects, templates, skill_detail
  - LiveView dashboard at /plugins/open-design (3 tabs: Status, Skills, Projects)
  - Dashboard widget: daemon health + skill count summary
  - REST API at /api/v2/open-design/*
  """

  @behaviour ApmV5.Plugins.PluginBehaviour

  alias ApmV5.Plugins.OpenDesign.OpenDesignClient
  alias ApmV5.Plugins.OpenDesign.OpenDesignMonitor

  require Logger

  @plugin_version "1.0.0"

  # ── Identity ──────────────────────────────────────────────────────────────────

  @impl true
  def plugin_name, do: "open_design"

  @impl true
  def plugin_description,
    do: "open-design daemon integration — skill catalog, design systems, agents, projects, artifact templates"

  @impl true
  def plugin_version, do: @plugin_version

  @impl true
  def plugin_scope, do: :ccem

  # ── Configuration ─────────────────────────────────────────────────────────────

  @impl true
  def config_schema do
    %{
      daemon_port: "integer",
      poll_interval_ms: "integer",
      auto_start_daemon: "boolean"
    }
  end

  @impl true
  def default_config do
    %{
      daemon_port: 17_456,
      poll_interval_ms: 30_000,
      auto_start_daemon: false
    }
  end

  # ── Endpoints ─────────────────────────────────────────────────────────────────

  @impl true
  def list_endpoints do
    [
      %{
        action: "health",
        description: "Daemon reachability, version, and overall status",
        params: %{}
      },
      %{
        action: "agents",
        description: "Detected agent CLIs on the local machine (Claude Code, Codex, Cursor, etc.)",
        params: %{}
      },
      %{
        action: "skills",
        description: "Full skill catalog from the daemon's skill registry",
        params: %{}
      },
      %{
        action: "skill_detail",
        description: "Single skill metadata by ID",
        params: %{id: "string (required)"}
      },
      %{
        action: "design_systems",
        description: "All design systems (DESIGN.md files) known to the daemon",
        params: %{}
      },
      %{
        action: "design_system_detail",
        description: "Single design system by ID",
        params: %{id: "string (required)"}
      },
      %{
        action: "projects",
        description: "All open-design projects managed by the daemon",
        params: %{}
      },
      %{
        action: "project_detail",
        description: "Single project by ID",
        params: %{id: "string (required)"}
      },
      %{
        action: "templates",
        description: "Artifact templates (prototypes, decks, landing pages, etc.)",
        params: %{}
      }
    ]
  end

  # ── Actions ───────────────────────────────────────────────────────────────────

  @impl true
  def handle_action("health", _params, _opts) do
    state = safe_monitor_state()
    {:ok, state}
  end

  def handle_action("agents", _params, opts) do
    port = Keyword.get(opts, :port, 17_456)

    case OpenDesignClient.list_agents(port) do
      {:ok, agents} -> {:ok, %{agents: agents, count: length(agents)}}
      {:error, :daemon_unreachable} -> {:error, "open-design daemon not running on port #{port}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  def handle_action("skills", _params, opts) do
    port = Keyword.get(opts, :port, 17_456)

    case OpenDesignClient.list_skills(port) do
      {:ok, skills} -> {:ok, %{skills: skills, count: length(skills)}}
      {:error, :daemon_unreachable} -> {:error, "open-design daemon not running on port #{port}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  def handle_action("skill_detail", %{"id" => id}, opts) do
    port = Keyword.get(opts, :port, 17_456)

    case OpenDesignClient.get_skill(id, port) do
      {:ok, skill} -> {:ok, skill}
      {:error, {:http_error, 404}} -> {:error, "skill not found: #{id}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  def handle_action("design_systems", _params, opts) do
    port = Keyword.get(opts, :port, 17_456)

    case OpenDesignClient.list_design_systems(port) do
      {:ok, ds} -> {:ok, %{design_systems: ds, count: length(ds)}}
      {:error, :daemon_unreachable} -> {:error, "open-design daemon not running on port #{port}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  def handle_action("design_system_detail", %{"id" => id}, opts) do
    port = Keyword.get(opts, :port, 17_456)

    case OpenDesignClient.get_design_system(id, port) do
      {:ok, ds} -> {:ok, ds}
      {:error, {:http_error, 404}} -> {:error, "design system not found: #{id}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  def handle_action("projects", _params, opts) do
    port = Keyword.get(opts, :port, 17_456)

    case OpenDesignClient.list_projects(port) do
      {:ok, projects} -> {:ok, %{projects: projects, count: length(projects)}}
      {:error, :daemon_unreachable} -> {:error, "open-design daemon not running on port #{port}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  def handle_action("project_detail", %{"id" => id}, opts) do
    port = Keyword.get(opts, :port, 17_456)

    case OpenDesignClient.get_project(id, port) do
      {:ok, project} -> {:ok, project}
      {:error, {:http_error, 404}} -> {:error, "project not found: #{id}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  def handle_action("templates", _params, opts) do
    port = Keyword.get(opts, :port, 17_456)

    case OpenDesignClient.list_templates(port) do
      {:ok, templates} -> {:ok, %{templates: templates, count: length(templates)}}
      {:error, :daemon_unreachable} -> {:error, "open-design daemon not running on port #{port}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  def handle_action(action, _params, _opts) do
    {:error, {:unknown_action, action}}
  end

  # ── Supervision ───────────────────────────────────────────────────────────────

  @impl true
  def supervisor_children do
    [
      {OpenDesignMonitor, [port: 17_456]}
    ]
  end

  # ── LiveView routes ───────────────────────────────────────────────────────────

  @impl true
  def live_views do
    [{"/plugins/open-design", ApmV5Web.OpenDesignLive, [as: :open_design_live]}]
  end

  # ── Nav ───────────────────────────────────────────────────────────────────────

  @impl true
  def nav_items do
    [
      {"open-design", "/plugins/open-design", "hero-paint-brush"}
    ]
  end

  @impl true
  def plugin_live_module, do: ApmV5Web.OpenDesignLive

  @impl true
  def settings_path, do: "/plugins/open-design/settings"

  # ── Dashboard Widget ──────────────────────────────────────────────────────────

  @impl true
  def dashboard_widgets do
    [
      %{
        id: "open_design_status",
        name: "open-design",
        category: :plugin,
        source_module: __MODULE__,
        refresh_interval: 30_000,
        min_width: 3,
        min_height: 2,
        config_schema: %{},
        plugin: "open_design",
        version: @plugin_version,
        description: "open-design daemon status: reachability, skill count, agent detection"
      }
    ]
  end

  # ── Private ───────────────────────────────────────────────────────────────────

  defp safe_monitor_state do
    case Process.whereis(OpenDesignMonitor) do
      nil ->
        %{reachable: false, error: "OpenDesignMonitor not started", skill_count: 0, design_system_count: 0, project_count: 0}

      _pid ->
        OpenDesignMonitor.current_state()
    end
  rescue
    _ -> %{reachable: false, error: "monitor unavailable"}
  end
end
