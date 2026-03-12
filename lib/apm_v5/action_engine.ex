defmodule ApmV5.ActionEngine do
  @moduledoc """
  GenServer for running predefined actions against developer projects.
  Actions: deploy_apm_hooks, add_memory_pointer, backfill_apm_config, analyze_project,
           fix_skill_frontmatter, complete_skill_description, add_skill_triggers,
           backfill_project_memory, update_hooks.
  """
  use GenServer

  @skills_dir Path.expand("~/.claude/skills")

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
    }
  ]

  # --- Client API ---

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def list_catalog do
    @catalog
  end

  @doc """
  Returns the current application status of APM actions for a project path.
  Pure filesystem check — no GenServer call needed.
  """
  def project_status(project_path) do
    %{
      has_hooks: check_hooks_present(project_path),
      has_memory_pointer: check_memory_pointer_present(project_path),
      has_apm_config: check_apm_config_present(project_path)
    }
  end

  def run_action(action_type, project_path, params \\ %{}) do
    GenServer.call(__MODULE__, {:run_action, action_type, project_path, params})
  end

  def list_runs do
    GenServer.call(__MODULE__, :list_runs)
  end

  def get_run(run_id) do
    GenServer.call(__MODULE__, {:get_run, run_id})
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_) do
    {:ok, %{runs: %{}}}
  end

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

  def handle_call(:list_runs, _from, state) do
    runs =
      state.runs
      |> Map.values()
      |> Enum.sort_by(& &1.started_at, :desc)
    {:reply, runs, state}
  end

  def handle_call({:get_run, run_id}, _from, state) do
    case Map.get(state.runs, run_id) do
      nil -> {:reply, {:error, :not_found}, state}
      run -> {:reply, {:ok, run}, state}
    end
  end

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
- **APM Port**: 3031
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
      apm_port: 3031,
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
end
