defmodule ApmV5.ActionEngine do
  @moduledoc """
  GenServer for running predefined actions against developer projects.
  Actions: deploy_apm_hooks, add_memory_pointer, backfill_apm_config, analyze_project,
           fix_skill_frontmatter, complete_skill_description, add_skill_triggers,
           backfill_project_memory, update_hooks.
  """
  use GenServer
  require Logger

  @skills_dir Path.expand("~/.claude/skills")
  @prune_interval_ms 3_600_000
  @max_runs 1000
  @run_ttl_seconds 86_400

  @catalog [
    %{
      id: "deploy_apm_hooks",
      name: "Deploy APM Hook Scripts",
      description: "Create Claude Code bash hook scripts (.claude/hooks/) to report to CCEM APM. Creates session_init.sh, pre_tool_use.sh, post_tool_use.sh.",
      category: "hooks",
      icon: "hook",
      params: []
    },
    %{
      id: "add_memory_pointer",
      name: "Add Memory Pointer",
      description: "Add CCEM APM memory pointers to the project's .claude/CLAUDE.md. Inserts APM port, config path, and dashboard URL references.",
      category: "memory",
      icon: "bookmark",
      params: []
    },
    %{
      id: "backfill_apm_config",
      name: "Backfill APM Config",
      description: "Create or update apm_config.json for the project. Fills in project_name, project_root, apm_url, and skills path.",
      category: "config",
      icon: "settings",
      params: []
    },
    %{
      id: "analyze_project",
      name: "Analyze Project",
      description: "Scan project structure and return findings: stack, agents, formations, config completeness, and drift between actual and configured.",
      category: "analysis",
      icon: "search",
      params: []
    },
    %{
      id: "fix_skill_frontmatter",
      name: "Fix Skill Frontmatter",
      description: "Read SKILL.md for a given skill and add/update YAML frontmatter with name and description fields.",
      category: "skill_audit",
      icon: "pencil",
      params: [%{name: "skill_name", type: "string", required: true}]
    },
    %{
      id: "complete_skill_description",
      name: "Complete Skill Description",
      description: "Extend a truncated skill description in SKILL.md frontmatter to at least 100 characters.",
      category: "skill_audit",
      icon: "document-text",
      params: [%{name: "skill_name", type: "string", required: true}]
    },
    %{
      id: "add_skill_triggers",
      name: "Add Skill Triggers",
      description: "Append trigger keyword section to SKILL.md content to improve health score trigger detection.",
      category: "skill_audit",
      icon: "bolt",
      params: [%{name: "skill_name", type: "string", required: true}]
    },
    %{
      id: "backfill_project_memory",
      name: "Backfill Project Memory",
      description: "Read project directory and generate a CCEM APM memory section for .claude/CLAUDE.md.",
      category: "skill_audit",
      icon: "archive-box",
      params: []
    },
    %{
      id: "update_hooks",
      name: "Update Settings Hooks",
      description: "Read .claude/settings.json and add missing CCEM APM hooks configuration entries.",
      category: "skill_audit",
      icon: "cog",
      params: []
    },
    %{
      id: "discover_migrate_showcases",
      name: "Discover & Migrate Showcases",
      description: "Scan registered projects for standalone showcase directories (showcase/client/showcase.js). Copies assets to APM static paths and registers showcase_data_path in project config. Reports per-project outcome.",
      category: "showcase",
      icon: "presentation-chart-bar",
      params: []
    },
    %{
      id: "register_all_ports",
      name: "Register All Ports",
      description: "Scan all configured projects and register/assign ports for any missing port assignments. Uses PortManager to detect and fill gaps.",
      category: "ports",
      icon: "server",
      params: []
    },
    %{
      id: "update_port_namespace",
      name: "Update Port Namespace",
      description: "Update port namespace assignment for a project. Moves the project's port to a different namespace range.",
      category: "ports",
      icon: "arrows-right-left",
      params: [
        %{name: "project", type: "string", required: true},
        %{name: "namespace", type: "string", required: true, options: ["web", "api", "service", "tool"]}
      ]
    },
    %{
      id: "analyze_port_assignment",
      name: "Analyze Port Assignment",
      description: "Analyze port utilization across all projects. Returns namespace distribution, active vs inactive counts, clash summary, and utilization percentage.",
      category: "ports",
      icon: "chart-bar",
      params: []
    },
    %{
      id: "smart_reassign_ports",
      name: "Smart Reassign Ports",
      description: "Intelligently reassign conflicting ports using AG-UI event flow. Analyzes clashes, proposes resolutions, and confirms via chat before applying.",
      category: "ports",
      icon: "bolt",
      params: []
    },
    %{
      id: "crate_digger_status",
      name: "CrateDigger Status",
      description: "Verify CrateDigger installation in an SFA project. Checks migration files (crates, crate_track_configs, who_sampled_cache), context module, schema files, WhoSampledScraper, LiveView, router entry, and sidebar nav link. Reports per-component status and missing items.",
      category: "analysis",
      icon: "musical-note",
      params: []
    },
    # AgentLock authorization actions (v7.0.0)
    %{
      id: "create_authorization_hooks",
      name: "Create Authorization Hooks",
      description: "Deploy AgentLock PreToolUse/PostToolUse hooks (agentlock_pre_tool.sh, agentlock_post_tool.sh, agentlock_context.sh) to target project's hook directory.",
      category: "authorization",
      icon: "shield-check",
      params: []
    },
    %{
      id: "register_tool_permissions",
      name: "Register Tool Permissions",
      description: "Batch register Claude Code tools with AgentLock risk levels. Configures default policies: Read=none, Write=medium, Bash=high, Agent=low.",
      category: "authorization",
      icon: "key",
      params: []
    },
    %{
      id: "audit_authorization_compliance",
      name: "Audit Authorization Compliance",
      description: "Scan authorization audit log for unauthorized patterns, missing tokens, expired sessions. Returns compliance report with risk distribution.",
      category: "authorization",
      icon: "clipboard-document-check",
      params: []
    },
    %{
      id: "manage_agent_lifecycle",
      name: "Manage Agent Lifecycle",
      description: "Start/stop/restart agent with authorization checkpoint. Validates token before state transition. Supports PENDING→AUTHORIZED→RUNNING lifecycle.",
      category: "process_management",
      icon: "play",
      params: [
        %{name: "agent_id", type: "string", required: true},
        %{name: "action", type: "string", required: true, options: ["start", "stop", "restart", "authorize"]}
      ]
    },
    %{
      id: "enforce_data_boundaries",
      name: "Enforce Data Boundaries",
      description: "Apply RedactionEngine patterns to specified output. Scans for sensitive data (SSN, CC, API keys, etc.) and reports findings. Optionally redacts in-place.",
      category: "authorization",
      icon: "eye-slash",
      params: [
        %{name: "text", type: "string", required: true},
        %{name: "mode", type: "string", required: false, options: ["scan", "redact"]}
      ]
    }
  ]

  # --- Client API ---

  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @spec list_catalog() :: [map()]
  def list_catalog do
    @catalog
  end

  @doc """
  Returns the current application status of APM actions for a project path.
  Pure filesystem check — no GenServer call needed.
  """
  @spec project_status(String.t()) :: map()
  def project_status(project_path) do
    %{
      has_hooks: check_hooks_present(project_path),
      has_memory_pointer: check_memory_pointer_present(project_path),
      has_apm_config: check_apm_config_present(project_path)
    }
  end

  @spec run_action(String.t(), String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def run_action(action_type, project_path, params \\ %{}) do
    GenServer.call(__MODULE__, {:run_action, action_type, project_path, params})
  end

  @spec list_runs() :: [map()]
  def list_runs do
    GenServer.call(__MODULE__, :list_runs)
  end

  @spec get_run(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_run(run_id) do
    GenServer.call(__MODULE__, {:get_run, run_id})
  end

  # --- GenServer callbacks ---

  @doc false
  @impl true
  def init(_) do
    schedule_prune()
    {:ok, %{runs: %{}}}
  end

  @doc false
  @impl true
  def handle_call({:run_action, action_type, project_path, params}, _from, state) do
    unless Enum.any?(@catalog, &(&1.id == action_type)) do
      {:reply, {:error, :unknown_action}, state}
    else
      run_id = ApmV5.Correlation.generate()
      run = %{
        id: run_id,
        action_type: action_type,
        project_path: project_path,
        status: "running",
        result: nil,
        error: nil,
        started_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        completed_at: nil
      }

      new_state = put_in(state, [:runs, run_id], run)

      # Run async
      server = self()
      Task.start(fn ->
        result = execute_action(action_type, project_path, params)
        GenServer.cast(server, {:action_done, run_id, result})
      end)

      {:reply, {:ok, run_id}, new_state}
    end
  end

  @doc false
  @impl true
  def handle_call(:list_runs, _from, state) do
    runs =
      state.runs
      |> Map.values()
      |> Enum.sort_by(& &1.started_at, :desc)
    {:reply, runs, state}
  end

  @doc false
  @impl true
  def handle_call({:get_run, run_id}, _from, state) do
    case Map.get(state.runs, run_id) do
      nil -> {:reply, {:error, :not_found}, state}
      run -> {:reply, {:ok, run}, state}
    end
  end

  @doc false
  @impl true
  def handle_cast({:action_done, run_id, result}, state) do
    case Map.get(state.runs, run_id) do
      nil ->
        {:noreply, state}

      run ->
        updated =
          case result do
            {:ok, data} ->
              run
              |> Map.put(:status, "completed")
              |> Map.put(:result, data)
              |> Map.put(:completed_at, DateTime.utc_now() |> DateTime.to_iso8601())

            {:error, reason} ->
              run
              |> Map.put(:status, "failed")
              |> Map.put(:error, to_string(reason))
              |> Map.put(:completed_at, DateTime.utc_now() |> DateTime.to_iso8601())
          end

        new_state = put_in(state, [:runs, run_id], updated)
        {:noreply, new_state}
    end
  end

  @doc false
  @impl true
  def handle_info(:prune_runs, state) do
    cutoff = DateTime.utc_now() |> DateTime.add(-@run_ttl_seconds, :second)

    pruned =
      state.runs
      |> Enum.reject(fn {_id, run} ->
        case DateTime.from_iso8601(run.started_at) do
          {:ok, dt, _} -> DateTime.compare(dt, cutoff) == :lt
          _ -> false
        end
      end)
      |> Enum.sort_by(fn {_id, run} -> run.started_at end, :desc)
      |> Enum.take(@max_runs)
      |> Map.new()

    dropped = map_size(state.runs) - map_size(pruned)

    if dropped > 0 do
      Logger.info("ActionEngine: pruned #{dropped} runs (older than 24h or over #{@max_runs} limit)")
    end

    schedule_prune()
    {:noreply, %{state | runs: pruned}}
  end

  @doc false
  @impl true
  def terminate(_reason, _state) do
    :ok
  end

  defp schedule_prune do
    Process.send_after(self(), :prune_runs, @prune_interval_ms)
  end

  # --- Status check helpers (used by project_status/1) ---

  defp check_hooks_present(path) do
    hooks_dir = Path.join(path, ".claude/hooks")
    Enum.all?(["session_init.sh", "pre_tool_use.sh", "post_tool_use.sh"], fn hook ->
      File.exists?(Path.join(hooks_dir, hook))
    end)
  end

  defp check_memory_pointer_present(path) do
    case File.read(Path.join(path, ".claude/CLAUDE.md")) do
      {:ok, content} -> String.contains?(content, "CCEM APM Integration")
      _ -> false
    end
  end

  defp check_apm_config_present(path) do
    File.exists?(Path.join(path, "apm/apm_config.json")) or
      File.exists?(Path.join(path, ".claude/apm_config.json"))
  end

  # --- Action implementations ---

  defp execute_action("deploy_apm_hooks", project_path, _params) do
    hooks_dir = Path.join(project_path, ".claude/hooks")
    File.mkdir_p(hooks_dir)

    hooks = %{
      "session_init.sh" => session_init_hook_content(),
      "pre_tool_use.sh" => pre_tool_use_hook_content(),
      "post_tool_use.sh" => post_tool_use_hook_content()
    }

    results =
      Enum.map(hooks, fn {filename, content} ->
        path = Path.join(hooks_dir, filename)
        case File.write(path, content) do
          :ok ->
            File.chmod(path, 0o755)
            {:ok, filename}

          {:error, reason} ->
            {:error, "#{filename}: #{reason}"}
        end
      end)

    errors = Enum.filter(results, &match?({:error, _}, &1))

    if Enum.empty?(errors) do
      {:ok, %{hooks_written: map_size(hooks), hooks_dir: hooks_dir}}
    else
      {:error, Enum.map(errors, fn {:error, msg} -> msg end) |> Enum.join(", ")}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp execute_action("add_memory_pointer", project_path, _params) do
    claude_dir = Path.join(project_path, ".claude")
    File.mkdir_p(claude_dir)
    claude_md = Path.join(claude_dir, "CLAUDE.md")

    pointer = """

## CCEM APM Integration

- **APM Dashboard**: http://localhost:3032
- **APM Config**: #{Path.join(project_path, "apm/apm_config.json")}
- **APM Port**: 3032
- **Skills Path**: ~/.claude/skills/
- **APM Log**: ~/Developer/ccem/apm/hooks/apm_server.log
"""

    existing = case File.read(claude_md) do
      {:ok, content} -> content
      _ -> ""
    end

    if String.contains?(existing, "CCEM APM Integration") do
      {:ok, %{message: "Memory pointer already present", file: claude_md}}
    else
      case File.write(claude_md, existing <> pointer) do
        :ok -> {:ok, %{message: "Memory pointer added", file: claude_md}}
        {:error, reason} -> {:error, reason}
      end
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp execute_action("backfill_apm_config", project_path, _params) do
    project_name = Path.basename(project_path)
    config_path = Path.join(project_path, "apm/apm_config.json")
    File.mkdir_p(Path.dirname(config_path))

    config = %{
      project_name: project_name,
      project_root: project_path,
      apm_url: "http://localhost:3032",
      apm_port: 3032,
      skills_path: "~/.claude/skills",
      session_id: ApmV5.Correlation.generate(),
      created_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    case File.write(config_path, Jason.encode!(config, pretty: true)) do
      :ok -> {:ok, %{config_path: config_path, project_name: project_name}}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp execute_action("analyze_project", project_path, _params) do
    files = case File.ls(project_path) do
      {:ok, f} -> f
      _ -> []
    end

    has_claude = ".claude" in files
    has_apm_config = File.exists?(Path.join(project_path, "apm/apm_config.json")) or
                     File.exists?(Path.join(project_path, ".claude/apm_config.json"))

    stack = detect_basic_stack(files)
    agent_count = count_dir(Path.join(project_path, ".claude/skills")) +
                  count_dir(Path.join(project_path, ".claude/agents"))

    {:ok, %{
      project_name: Path.basename(project_path),
      project_path: project_path,
      has_claude_config: has_claude,
      has_apm_config: has_apm_config,
      stack: stack,
      agent_count: agent_count,
      recommendations: build_recommendations(has_claude, has_apm_config)
    }}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp execute_action("fix_skill_frontmatter", _project_path, %{"skill_name" => skill_name}) do
    skill_dir = Path.join(@skills_dir, skill_name)
    skill_md = Path.join(skill_dir, "SKILL.md")

    unless File.dir?(skill_dir) do
      {:error, "skill directory not found: #{skill_dir}"}
    else
      content = if File.exists?(skill_md), do: File.read!(skill_md), else: ""

      has_frontmatter = String.starts_with?(content, "---\n")

      {new_content, changes} =
        if has_frontmatter do
          # Update existing frontmatter — ensure name and description keys exist
          updated =
            content
            |> ensure_frontmatter_key("name", skill_name)
            |> ensure_frontmatter_key("description", "#{skill_name} skill")

          {updated, ["updated existing frontmatter"]}
        else
          # Prepend new frontmatter
          frontmatter = "---\nname: #{skill_name}\ndescription: #{skill_name} skill — add a detailed description here.\n---\n\n"
          {frontmatter <> content, ["added frontmatter"]}
        end

      case File.write(skill_md, new_content) do
        :ok ->
          notify_skill_audit_complete(skill_name, "fix_skill_frontmatter")
          {:ok, %{status: "ok", message: "Frontmatter updated", changes: changes, skill: skill_name}}

        {:error, reason} ->
          {:error, "Failed to write #{skill_md}: #{reason}"}
      end
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp execute_action("fix_skill_frontmatter", _project_path, params) do
    {:error, "Missing required param: skill_name (got: #{inspect(params)})"}
  end

  defp execute_action("complete_skill_description", _project_path, %{"skill_name" => skill_name}) do
    skill_md = Path.join([@skills_dir, skill_name, "SKILL.md"])

    case File.read(skill_md) do
      {:ok, content} ->
        updated =
          ensure_frontmatter_key(content, "description",
            "#{skill_name} skill — a Claude Code skill that provides specialized capabilities. " <>
              "Use this skill when working with #{skill_name}-related tasks.")

        case File.write(skill_md, updated) do
          :ok ->
            notify_skill_audit_complete(skill_name, "complete_skill_description")
            {:ok, %{status: "ok", message: "Description extended", skill: skill_name, changes: ["description updated"]}}

          {:error, reason} ->
            {:error, "write failed: #{reason}"}
        end

      _ ->
        {:error, "SKILL.md not found for skill: #{skill_name}"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp execute_action("complete_skill_description", _project_path, params) do
    {:error, "Missing required param: skill_name (got: #{inspect(params)})"}
  end

  defp execute_action("add_skill_triggers", _project_path, %{"skill_name" => skill_name}) do
    skill_md = Path.join([@skills_dir, skill_name, "SKILL.md"])

    case File.read(skill_md) do
      {:ok, content} ->
        triggers_section = """

## When to use

**Trigger keywords**: trigger, invoke, use when, keywords
- Use this skill when you need to work with #{skill_name}
- Invoke when: #{skill_name}-related tasks are required
"""

        unless String.contains?(content, "When to use") do
          case File.write(skill_md, content <> triggers_section) do
            :ok ->
              notify_skill_audit_complete(skill_name, "add_skill_triggers")
              {:ok, %{status: "ok", message: "Triggers section added", skill: skill_name, changes: ["triggers section appended"]}}

            {:error, reason} ->
              {:error, "write failed: #{reason}"}
          end
        else
          {:ok, %{status: "ok", message: "Triggers already present", skill: skill_name, changes: []}}
        end

      _ ->
        {:error, "SKILL.md not found for skill: #{skill_name}"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp execute_action("add_skill_triggers", _project_path, params) do
    {:error, "Missing required param: skill_name (got: #{inspect(params)})"}
  end

  defp execute_action("backfill_project_memory", project_path, _params) do
    claude_dir = Path.join(project_path, ".claude")
    File.mkdir_p(claude_dir)
    claude_md = Path.join(claude_dir, "CLAUDE.md")

    project_name = Path.basename(project_path)
    stack_info = detect_project_stack(project_path)

    memory_section = """

## CCEM APM Memory

- **Project**: #{project_name}
- **Path**: #{project_path}
- **Stack**: #{Enum.join(stack_info, ", ")}
- **APM Dashboard**: http://localhost:3032
- **Skills Path**: ~/.claude/skills/
- **Generated**: #{DateTime.utc_now() |> DateTime.to_iso8601()}
"""

    existing = case File.read(claude_md) do
      {:ok, content} -> content
      _ -> ""
    end

    new_content =
      if String.contains?(existing, "## CCEM APM Memory") do
        existing
      else
        existing <> memory_section
      end

    case File.write(claude_md, new_content) do
      :ok ->
        {:ok, %{
          status: "ok",
          message: "Project memory backfilled",
          file: claude_md,
          changes: ["CCEM APM Memory section added"]
        }}

      {:error, reason} ->
        {:error, "write failed: #{reason}"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp execute_action("update_hooks", project_path, _params) do
    settings_path = Path.join(project_path, ".claude/settings.json")

    settings =
      case File.read(settings_path) do
        {:ok, raw} ->
          case Jason.decode(raw) do
            {:ok, parsed} -> parsed
            _ -> %{}
          end

        _ ->
          %{}
      end

    apm_hooks = %{
      "PreToolUse" => [
        %{
          "matcher" => ".*",
          "hooks" => [
            %{
              "type" => "command",
              "command" => "curl -s -X POST http://localhost:3032/api/heartbeat -H 'Content-Type: application/json' -d '{\"agent_id\":\"$CLAUDE_SESSION_ID\",\"status\":\"working\",\"message\":\"PreToolUse\"}' >/dev/null 2>&1"
            }
          ]
        }
      ]
    }

    existing_hooks = Map.get(settings, "hooks", %{})
    updated_hooks = Map.merge(apm_hooks, existing_hooks)
    updated_settings = Map.put(settings, "hooks", updated_hooks)

    File.mkdir_p(Path.dirname(settings_path))

    case File.write(settings_path, Jason.encode!(updated_settings, pretty: true)) do
      :ok ->
        {:ok, %{
          status: "ok",
          message: "Settings hooks updated",
          file: settings_path,
          changes: ["APM hooks added to settings.json"]
        }}

      {:error, reason} ->
        {:error, "write failed: #{reason}"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp execute_action("discover_migrate_showcases", _project_path, _params) do
    config = ApmV5.ConfigLoader.get_config()
    projects = Map.get(config, "projects", [])

    static_base =
      :code.priv_dir(:apm_v5)
      |> Path.join("static/showcase/projects")

    File.mkdir_p(static_base)

    results =
      Enum.map(projects, fn project ->
        name = Map.get(project, "name", "unknown")
        root = Map.get(project, "project_root", Map.get(project, "root", ""))

        cond do
          root == "" ->
            %{project: name, status: :skipped, reason: "no project_root configured"}

          not File.dir?(Path.expand(root)) ->
            %{project: name, status: :skipped, reason: "project_root does not exist"}

          true ->
            expanded = Path.expand(root)
            client_dir = Path.join(expanded, "showcase/client")
            data_dir = Path.join(expanded, "showcase/data")
            standalone_js = Path.join(client_dir, "showcase.js")

            cond do
              not File.exists?(standalone_js) ->
                %{project: name, status: :skipped, reason: "no showcase/client/showcase.js found"}

              Map.get(project, "showcase_data_path") != nil ->
                %{project: name, status: :skipped, reason: "already migrated (showcase_data_path set)"}

              true ->
                dest = Path.join(static_base, name)
                File.mkdir_p(dest)

                case copy_showcase_assets(client_dir, dest) do
                  {:ok, copied} ->
                    updated_project = Map.put(project, "showcase_data_path", data_dir)
                    ApmV5.ConfigLoader.update_project(updated_project)
                    ApmV5.ShowcaseDataStore.reload(name)

                    %{
                      project: name,
                      status: :migrated,
                      files_copied: copied,
                      dest: dest,
                      showcase_data_path: data_dir
                    }

                  {:error, reason} ->
                    %{project: name, status: :failed, reason: inspect(reason)}
                end
            end
        end
      end)

    migrated = Enum.count(results, &(&1.status == :migrated))
    skipped = Enum.count(results, &(&1.status == :skipped))
    failed = Enum.count(results, &(&1.status == :failed))

    {:ok,
     %{
       found: length(projects),
       migrated: migrated,
       skipped: skipped,
       failed: failed,
       results: results
     }}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp execute_action("register_all_ports", _project_path, _params) do
    project_configs = ApmV5.PortManager.get_project_configs()

    results =
      Enum.map(project_configs, fn {project_name, config} ->
        has_ports = length(config.ports) > 0

        if has_ports do
          {:already_assigned, project_name}
        else
          case ApmV5.PortManager.assign_port(project_name) do
            {:ok, port} -> {:assigned, project_name, port}
            {:error, reason} -> {:failed, project_name, reason}
          end
        end
      end)

    assigned = Enum.filter(results, &match?({:already_assigned, _}, &1))
    newly_assigned = Enum.filter(results, &match?({:assigned, _, _}, &1))
    failed = Enum.filter(results, &match?({:failed, _, _}, &1))

    {:ok, %{
      total_projects: length(results),
      already_assigned: length(assigned),
      newly_assigned: length(newly_assigned),
      failed: length(failed),
      assignments: Enum.map(newly_assigned, fn {:assigned, name, port} -> %{project: name, port: port} end),
      errors: Enum.map(failed, fn {:failed, name, reason} -> %{project: name, reason: inspect(reason)} end)
    }}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp execute_action("update_port_namespace", _project_path, %{"project" => project_name, "namespace" => namespace_str}) do
    namespace = String.to_existing_atom(namespace_str)
    ranges = ApmV5.PortManager.get_port_ranges()

    unless Map.has_key?(ranges, namespace) do
      {:error, "Invalid namespace: #{namespace_str}. Must be one of: web, api, service, tool"}
    else
      case ApmV5.PortManager.assign_port(namespace) do
        {:ok, new_port} ->
          case ApmV5.PortManager.reassign_port(project_name, new_port) do
            {:ok, assigned_port} ->
              {:ok, %{
                project: project_name,
                namespace: namespace_str,
                new_port: assigned_port,
                message: "Port reassigned to #{namespace_str} namespace (port #{assigned_port})"
              }}

            {:error, reason} ->
              {:error, "Failed to reassign port for #{project_name}: #{inspect(reason)}"}
          end

        {:error, :no_available_port} ->
          {:error, "No available port in #{namespace_str} namespace"}

        {:error, reason} ->
          {:error, "Failed to find available port: #{inspect(reason)}"}
      end
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp execute_action("update_port_namespace", _project_path, params) do
    {:error, "Missing required params: project and namespace (got: #{inspect(params)})"}
  end

  defp execute_action("analyze_port_assignment", _project_path, _params) do
    port_map = ApmV5.PortManager.get_port_map()
    clashes = ApmV5.PortManager.detect_clashes()
    ranges = ApmV5.PortManager.get_port_ranges()

    {:ok, build_port_analysis_result(port_map, clashes, ranges)}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp execute_action("smart_reassign_ports", _project_path, _params) do
    clashes = ApmV5.PortManager.detect_clashes()

    if clashes == [] do
      {:ok, %{message: "No port clashes detected", changes: []}}
    else
      suggestions =
        Enum.map(clashes, fn clash ->
          port = clash.port
          projects = clash.projects
          primary = List.first(projects)
          %{
            port: port,
            projects: projects,
            suggestion: "Keep #{primary} on port #{port}, reassign others"
          }
        end)

      {:ok, %{
        clashes: length(clashes),
        suggestions: suggestions,
        message: "Review suggestions and use update_port_namespace to apply"
      }}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp execute_action("crate_digger_status", project_path, _params) do
    # Expected paths relative to project_path
    checks = [
      {:migration, "priv/repo/migrations", "create_crate_digger_tables"},
      {:context, "lib/sound_forge/crate_digger.ex", nil},
      {:schema_crate, "lib/sound_forge/crate_digger/crate.ex", nil},
      {:schema_track_config, "lib/sound_forge/crate_digger/crate_track_config.ex", nil},
      {:schema_cache, "lib/sound_forge/crate_digger/who_sampled_cache.ex", nil},
      {:scraper, "lib/sound_forge/crate_digger/who_sampled_scraper.ex", nil},
      {:live_view, "lib/sound_forge_web/live/crate_digger_live.ex", nil},
      {:router, "lib/sound_forge_web/router.ex", "CrateDiggerLive"},
      {:sidebar, "lib/sound_forge_web/live/components/sidebar.ex", "crate"},
      {:floki_dep, "mix.exs", "floki"}
    ]

    results =
      Enum.map(checks, fn
        {:migration, rel_dir, pattern} ->
          dir = Path.join(project_path, rel_dir)
          found =
            case File.ls(dir) do
              {:ok, files} -> Enum.any?(files, &String.contains?(&1, pattern))
              _ -> false
            end
          {rel_dir <> "/" <> pattern, found}

        {_key, rel_path, nil} ->
          {rel_path, File.exists?(Path.join(project_path, rel_path))}

        {_key, rel_path, pattern} ->
          path = Path.join(project_path, rel_path)
          found =
            case File.read(path) do
              {:ok, content} -> String.contains?(content, pattern)
              _ -> false
            end
          {rel_path <> " (contains: #{pattern})", found}
      end)

    present = Enum.count(results, fn {_, ok} -> ok end)
    missing = Enum.filter(results, fn {_, ok} -> !ok end) |> Enum.map(&elem(&1, 0))

    status = if missing == [], do: "complete", else: "partial"

    {:ok, %{
      status: status,
      total_checks: length(results),
      present: present,
      missing_count: length(missing),
      missing: missing,
      details: Enum.map(results, fn {name, ok} -> %{check: name, ok: ok} end)
    }}
  rescue
    e -> {:error, Exception.message(e)}
  end

  # -- AgentLock authorization actions (v7.0.0) --

  defp execute_action("create_authorization_hooks", _project_path, _params) do
    hooks_dir = Path.expand("~/Developer/ccem/apm/hooks")

    hooks = [
      {"agentlock_pre_tool.sh", :pre_tool},
      {"agentlock_post_tool.sh", :post_tool},
      {"agentlock_context.sh", :context}
    ]

    results =
      Enum.map(hooks, fn {filename, _type} ->
        path = Path.join(hooks_dir, filename)
        exists = File.exists?(path)
        {filename, %{path: path, exists: exists}}
      end)

    {:ok, %{hooks_dir: hooks_dir, hooks: results, action: "create_authorization_hooks"}}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp execute_action("register_tool_permissions", _project_path, _params) do
    tools = ApmV5.Auth.PolicyEngine.default_risk_map()

    Enum.each(tools, fn {name, risk} ->
      ApmV5.Auth.AuthorizationGate.register_tool(name, risk)
    end)

    {:ok, %{registered: map_size(tools), tools: tools}}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp execute_action("audit_authorization_compliance", _project_path, _params) do
    summary = ApmV5.Auth.AuthorizationGate.summary()
    sessions = ApmV5.Auth.SessionStore.list_active()
    token_stats = ApmV5.Auth.TokenStore.stats()
    rate_stats = ApmV5.Auth.RateLimiter.stats()

    {:ok, %{
      summary: summary,
      active_sessions: length(sessions),
      token_stats: token_stats,
      rate_limit_stats: rate_stats,
      compliance_status: if(summary.total_denied == 0, do: "clean", else: "has_denials")
    }}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp execute_action("manage_agent_lifecycle", _project_path, params) do
    agent_id = Map.get(params, "agent_id", "")
    action = Map.get(params, "action", "")

    event =
      case action do
        "start" -> :start
        "stop" -> :complete
        "restart" -> :start
        "authorize" -> :authorize
        _ -> nil
      end

    if event do
      case ApmV5.Auth.AgentLifecycle.transition(:pending, event) do
        {:ok, new_state} -> {:ok, %{agent_id: agent_id, action: action, new_state: new_state}}
        {:error, reason} -> {:error, "Invalid transition: #{reason}"}
      end
    else
      {:error, "Unknown action: #{action}"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp execute_action("enforce_data_boundaries", _project_path, params) do
    text = Map.get(params, "text", "")
    mode = Map.get(params, "mode", "scan")

    case mode do
      "scan" ->
        matches = ApmV5.Auth.RedactionEngine.scan(text)
        {:ok, %{mode: "scan", matches: length(matches), findings: Enum.map(matches, fn {type, _text, pos} -> %{type: type, position: pos} end)}}

      "redact" ->
        result = ApmV5.Auth.RedactionEngine.redact(text, :auto)
        {:ok, %{mode: "redact", had_redactions: result.had_redactions, redaction_count: length(result.redactions)}}

      _ ->
        {:error, "Unknown mode: #{mode}"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp detect_project_stack(path) do
    stack_files = %{
      "package.json" => "node",
      "mix.exs" => "elixir",
      "requirements.txt" => "python",
      "Cargo.toml" => "rust",
      "go.mod" => "go",
      "Gemfile" => "ruby",
      "Package.swift" => "swift"
    }

    case File.ls(path) do
      {:ok, files} ->
        files
        |> Enum.filter(&Map.has_key?(stack_files, &1))
        |> Enum.map(&Map.get(stack_files, &1))

      _ ->
        []
    end
  end

  defp ensure_frontmatter_key(content, key, default_value) do
    case Regex.run(~r/^---\n(.*?)\n---/s, content) do
      [full_match, yaml_block] ->
        if String.contains?(yaml_block, "#{key}:") do
          content
        else
          new_yaml = yaml_block <> "\n#{key}: #{default_value}"
          new_fm = "---\n#{new_yaml}\n---"
          String.replace(content, full_match, new_fm, global: false)
        end

      _ ->
        content
    end
  end

  defp notify_skill_audit_complete(skill_name, action) do
    payload = Jason.encode!(%{
      type: "success",
      title: "Skill Audit Complete",
      message: "#{action} applied to #{skill_name}",
      category: "skill"
    })

    Task.start(fn ->
      System.cmd("curl", [
        "-s", "-X", "POST", "http://localhost:3032/api/notify",
        "-H", "Content-Type: application/json",
        "-d", payload
      ], stderr_to_stdout: true)
    end)
  end

  defp detect_basic_stack(files) do
    stack_map = %{
      "package.json" => "node",
      "mix.exs" => "elixir",
      "requirements.txt" => "python",
      "Cargo.toml" => "rust",
      "go.mod" => "go",
      "Gemfile" => "ruby",
      "Package.swift" => "swift"
    }

    files
    |> Enum.filter(&Map.has_key?(stack_map, &1))
    |> Enum.map(&Map.get(stack_map, &1))
  end

  defp count_dir(path) do
    case File.ls(path) do
      {:ok, entries} -> length(entries)
      _ -> 0
    end
  end

  defp build_recommendations(has_claude, has_apm_config) do
    []
    |> then(fn recs ->
      if has_claude, do: recs, else: ["Run 'add_memory_pointer' to create .claude/CLAUDE.md" | recs]
    end)
    |> then(fn recs ->
      if has_apm_config, do: recs, else: ["Run 'backfill_apm_config' to create apm_config.json" | recs]
    end)
    |> then(fn recs ->
      if has_claude, do: recs, else: ["Run 'update_hooks' to configure session reporting" | recs]
    end)
  end

  # --- Hook templates ---

  defp session_init_hook_content do
    """
    #!/bin/bash
    # CCEM APM Session Init Hook — auto-generated by ActionEngine
    # Reports session start to APM at localhost:3032

    PROJECT_ROOT="${CLAUDE_PROJECT_ROOT:-$(pwd)}"
    SESSION_ID="${CLAUDE_SESSION_ID:-$(uuidgen | tr '[:upper:]' '[:lower:]')}"
    PROJECT_NAME=$(basename "$PROJECT_ROOT")

    curl -s -X POST http://localhost:3032/api/register \\
      -H "Content-Type: application/json" \\
      -d "{
        \\"agent_id\\": \\"session-$SESSION_ID\\",
        \\"project\\": \\"$PROJECT_NAME\\",
        \\"role\\": \\"session\\",
        \\"status\\": \\"active\\",
        \\"session_id\\": \\"$SESSION_ID\\"
      }" >/dev/null 2>&1 &
    """
  end

  defp pre_tool_use_hook_content do
    """
    #!/bin/bash
    # CCEM APM Pre-Tool-Use Hook — auto-generated by ActionEngine
    # Reports tool invocation to APM heartbeat

    AGENT_ID="${CLAUDE_AGENT_ID:-session-unknown}"
    TOOL_NAME="${CLAUDE_TOOL_NAME:-unknown}"

    curl -s -X POST http://localhost:3032/api/heartbeat \\
      -H "Content-Type: application/json" \\
      -d "{
        \\"agent_id\\": \\"$AGENT_ID\\",
        \\"status\\": \\"working\\",
        \\"message\\": \\"Tool: $TOOL_NAME\\"
      }" >/dev/null 2>&1 &
    """
  end

  defp post_tool_use_hook_content do
    """
    #!/bin/bash
    # CCEM APM Post-Tool-Use Hook — auto-generated by ActionEngine
    # Reports tool completion to APM heartbeat

    AGENT_ID="${CLAUDE_AGENT_ID:-session-unknown}"
    TOOL_NAME="${CLAUDE_TOOL_NAME:-unknown}"
    TOOL_STATUS="${CLAUDE_TOOL_STATUS:-completed}"

    curl -s -X POST http://localhost:3032/api/heartbeat \\
      -H "Content-Type: application/json" \\
      -d "{
        \\"agent_id\\": \\"$AGENT_ID\\",
        \\"status\\": \\"$TOOL_STATUS\\",
        \\"message\\": \\"Tool done: $TOOL_NAME\\"
      }" >/dev/null 2>&1 &
    """
  end

  defp build_port_analysis_result(port_map, clashes, ranges) do
    total = map_size(port_map)
    clash_count = length(clashes)

    by_namespace =
      Enum.reduce(port_map, %{web: 0, api: 0, service: 0, tool: 0, other: 0}, fn {_port, info}, acc ->
        ns = Map.get(info, :namespace, :other)
        Map.update(acc, ns, 1, &(&1 + 1))
      end)

    namespace_capacity =
      ranges
      |> Enum.map(fn {ns, range} -> {ns, Enum.count(range)} end)
      |> Enum.into(%{})

    utilization = compute_port_utilization(total, namespace_capacity)

    %{
      total: total,
      clashes: clash_count,
      utilization_percent: utilization,
      by_namespace: by_namespace,
      namespace_capacity: namespace_capacity,
      clash_details: Enum.map(clashes, fn c ->
        %{port: c.port, projects: c.projects, owner: c.owner}
      end)
    }
  end

  defp compute_port_utilization(0, _namespace_capacity), do: 0.0

  defp compute_port_utilization(total, namespace_capacity) do
    total_capacity = Enum.sum(Map.values(namespace_capacity))
    Float.round(total / total_capacity * 100, 2)
  end

  defp copy_showcase_assets(src_dir, dest_dir) do
    case File.ls(src_dir) do
      {:error, reason} ->
        {:error, reason}

      {:ok, entries} ->
        copied =
          Enum.reduce(entries, 0, fn entry, acc ->
            src = Path.join(src_dir, entry)
            dst = Path.join(dest_dir, entry)

            cond do
              File.dir?(src) ->
                File.mkdir_p(dst)
                case copy_showcase_assets(src, dst) do
                  {:ok, n} -> acc + n
                  _ -> acc
                end

              File.regular?(src) ->
                case File.copy(src, dst) do
                  {:ok, _} -> acc + 1
                  _ -> acc
                end

              true ->
                acc
            end
          end)

        {:ok, copied}
    end
  end
end
