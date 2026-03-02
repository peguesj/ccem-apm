defmodule ApmV4.ActionEngine do
  @moduledoc """
  GenServer for running predefined actions against developer projects.
  Actions: update_hooks, add_memory_pointer, backfill_apm_config, analyze_project.
  """
  use GenServer

  @catalog [
    %{
      id: "update_hooks",
      name: "Update Session Hooks",
      description: "Update Claude Code session hooks to correctly report to CCEM APM. Creates/updates pre_tool_use, post_tool_use, and session_init hooks.",
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
    }
  ]

  # --- Client API ---

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def list_catalog do
    @catalog
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
      run_id = ApmV4.Correlation.generate()
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

  # --- Action implementations ---

  defp execute_action("update_hooks", project_path, _params) do
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

- **APM Dashboard**: http://localhost:3031
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
      apm_url: "http://localhost:3031",
      apm_port: 3031,
      skills_path: "~/.claude/skills",
      session_id: ApmV4.Correlation.generate(),
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
    # Reports session start to APM at localhost:3031

    PROJECT_ROOT="${CLAUDE_PROJECT_ROOT:-$(pwd)}"
    SESSION_ID="${CLAUDE_SESSION_ID:-$(uuidgen | tr '[:upper:]' '[:lower:]')}"
    PROJECT_NAME=$(basename "$PROJECT_ROOT")

    curl -s -X POST http://localhost:3031/api/register \\
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

    curl -s -X POST http://localhost:3031/api/heartbeat \\
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

    curl -s -X POST http://localhost:3031/api/heartbeat \\
      -H "Content-Type: application/json" \\
      -d "{
        \\"agent_id\\": \\"$AGENT_ID\\",
        \\"status\\": \\"$TOOL_STATUS\\",
        \\"message\\": \\"Tool done: $TOOL_NAME\\"
      }" >/dev/null 2>&1 &
    """
  end
end
