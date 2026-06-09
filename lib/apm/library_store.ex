defmodule Apm.LibraryStore do
  @moduledoc """
  GenServer that scans and catalogs all CCEM ecosystem resources:
  agents, skills, MCP servers, tools/hooks, commands, patterns, and learnings.

  Results are cached in ETS `:library_store` and refreshed every 10 minutes.
  Broadcasts on `"apm:library"` PubSub topic on changes.
  """

  use GenServer
  require Logger

  @ets_table :library_store
  @refresh_interval :timer.minutes(10)
  @pubsub_topic "apm:library"

  # Scan paths
  @skills_dir Path.expand("~/.claude/skills")
  @agents_dir Path.expand("~/.claude/agents")
  @commands_dir Path.expand("~/.claude/commands")
  @config_dir Path.expand("~/.claude/config")
  @settings_path Path.expand("~/.claude/settings.json")
  @user_mcp_path Path.expand("~/.mcp.json")
  @memory_dir Path.expand("~/.claude/projects/-Users-jeremiah-Developer-ccem/memory")
  @hooks_dir Path.expand("~/Developer/ccem/apm/hooks")

  # ── Public API ──────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Returns all agents from the catalog."
  @spec list_agents() :: [map()]
  def list_agents, do: get_category(:agents)

  @doc "Returns all skills from the catalog."
  @spec list_skills() :: [map()]
  def list_skills, do: get_category(:skills)

  @doc "Returns all MCP servers from the catalog."
  @spec list_mcp_servers() :: [map()]
  def list_mcp_servers, do: get_category(:mcp_servers)

  @doc "Returns all tools/hooks from the catalog."
  @spec list_tools() :: [map()]
  def list_tools, do: get_category(:tools)

  @doc "Returns all commands from the catalog."
  @spec list_commands() :: [map()]
  def list_commands, do: get_category(:commands)

  @doc "Returns all patterns from the catalog."
  @spec list_patterns() :: [map()]
  def list_patterns, do: get_category(:patterns)

  @doc "Returns all learnings from the catalog."
  @spec list_learnings() :: [map()]
  def list_learnings, do: get_category(:learnings)

  @doc "Returns all hooks from the catalog."
  @spec list_hooks() :: [map()]
  def list_hooks, do: get_category(:hooks)

  @doc "Returns a summary of all categories with counts."
  @spec summary() :: map()
  def summary do
    %{
      agents: length(list_agents()),
      skills: length(list_skills()),
      mcp_servers: length(list_mcp_servers()),
      tools: length(list_tools()),
      hooks: length(list_hooks()),
      commands: length(list_commands()),
      patterns: length(list_patterns()),
      learnings: length(list_learnings()),
      last_scanned: get_meta(:last_scanned)
    }
  end

  @doc "Triggers an asynchronous full rescan."
  @spec refresh() :: :ok
  def refresh, do: GenServer.cast(__MODULE__, :refresh)

  # ── GenServer callbacks ──────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    :ets.new(@ets_table, [:named_table, :public, :set, read_concurrency: true])
    send(self(), :scan)
    {:ok, %{last_hash: nil}}
  end

  @impl true
  def handle_info(:scan, state) do
    server = self()
    pubsub_topic = @pubsub_topic
    last_hash = state.last_hash

    Task.start(fn ->
      do_full_scan()
      hash = compute_hash()

      if hash != last_hash do
        Phoenix.PubSub.broadcast(Apm.PubSub, pubsub_topic, {:library_updated, summary()})
      end

      send(server, {:scan_complete, hash})
    end)

    Process.send_after(self(), :scan, @refresh_interval)
    {:noreply, state}
  end

  @impl true
  def handle_info({:scan_complete, hash}, state) do
    {:noreply, %{state | last_hash: hash}}
  end

  @impl true
  def handle_cast(:refresh, state) do
    send(self(), :scan)
    {:noreply, state}
  end

  # ── Private: category retrieval ────────────────────────────────────────────

  defp get_category(key) do
    case :ets.whereis(@ets_table) do
      :undefined ->
        []

      _ ->
        case :ets.lookup(@ets_table, key) do
          [{^key, items}] -> items
          [] -> []
        end
    end
  end

  defp get_meta(key) do
    case :ets.whereis(@ets_table) do
      :undefined ->
        nil

      _ ->
        case :ets.lookup(@ets_table, {:meta, key}) do
          [{{:meta, ^key}, value}] -> value
          [] -> nil
        end
    end
  end

  defp compute_hash do
    data = [
      get_category(:agents),
      get_category(:skills),
      get_category(:mcp_servers),
      get_category(:tools),
      get_category(:hooks),
      get_category(:commands),
      get_category(:patterns),
      get_category(:learnings)
    ]

    :erlang.phash2(data)
  end

  # ── Private: full scan ─────────────────────────────────────────────────────

  defp do_full_scan do
    Logger.info("[LibraryStore] Scanning all CCEM ecosystem resources")

    :ets.insert(@ets_table, {:agents, scan_agents()})
    :ets.insert(@ets_table, {:skills, scan_skills()})
    :ets.insert(@ets_table, {:mcp_servers, scan_mcp_servers()})
    :ets.insert(@ets_table, {:tools, scan_tools()})
    :ets.insert(@ets_table, {:hooks, scan_all_hooks()})
    :ets.insert(@ets_table, {:commands, scan_commands()})
    :ets.insert(@ets_table, {:patterns, scan_patterns()})
    :ets.insert(@ets_table, {:learnings, scan_learnings()})
    :ets.insert(@ets_table, {{:meta, :last_scanned}, DateTime.utc_now() |> DateTime.to_iso8601()})
  end

  # ── Agents scanner ─────────────────────────────────────────────────────────

  defp scan_agents do
    file_agents = scan_agent_files()
    identity_agents = scan_agent_identity_types()
    (file_agents ++ identity_agents) |> Enum.uniq_by(& &1.name)
  end

  defp scan_agent_files do
    case File.ls(@agents_dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(fn entry ->
          path = Path.join(@agents_dir, entry)

          String.ends_with?(entry, ".md") or
            String.ends_with?(entry, ".py") or
            File.dir?(path)
        end)
        |> Enum.map(fn entry ->
          path = Path.join(@agents_dir, entry)
          name = entry |> String.replace_suffix(".md", "") |> String.replace_suffix(".py", "")

          description =
            if File.regular?(path),
              do: extract_description(path),
              else: "Agent directory: #{entry}"

          type =
            cond do
              String.contains?(name, "orchestrat") ->
                "orchestrator"

              String.contains?(name, "registry") ->
                "persistent_service"

              String.contains?(name, "analysis") or String.contains?(name, "analyzer") ->
                "quality_agent"

              true ->
                "individual"
            end

          %{
            name: name,
            display_name:
              name |> String.replace("-", " ") |> String.replace("_", " ") |> titlecase(),
            type: type,
            source: "~/.claude/agents/",
            path: path,
            description: description,
            last_modified: file_mtime_iso(path)
          }
        end)

      {:error, _} ->
        []
    end
  end

  defp scan_agent_identity_types do
    # Return the 8 canonical agent types from AgentIdentity
    ~w(orchestrator squadron_lead swarm_agent cluster_agent individual persistent_service quality_agent unknown)
    |> Enum.map(fn type ->
      %{
        name: "agent-type-#{type}",
        display_name: type |> String.replace("_", " ") |> titlecase(),
        type: type,
        source: "AgentIdentity",
        path: "lib/apm/agent_identity.ex",
        description: "Canonical agent type: #{type}",
        last_modified: nil
      }
    end)
  end

  # ── Skills scanner ─────────────────────────────────────────────────────────

  defp scan_skills do
    case File.ls(@skills_dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(fn entry ->
          File.dir?(Path.join(@skills_dir, entry))
        end)
        |> Enum.map(fn skill_name ->
          skill_dir = Path.join(@skills_dir, skill_name)
          skill_md = Path.join(skill_dir, "SKILL.md")
          content = if File.exists?(skill_md), do: safe_read(skill_md), else: ""
          frontmatter = parse_frontmatter(content)

          %{
            name: skill_name,
            display_name:
              Map.get(frontmatter, "name", skill_name |> String.replace("-", " ") |> titlecase()),
            description: Map.get(frontmatter, "description", extract_first_paragraph(content)),
            triggers: parse_triggers(content),
            source: "~/.claude/skills/#{skill_name}/",
            path: skill_dir,
            has_skill_md: File.exists?(skill_md),
            file_count: count_dir_files(skill_dir),
            last_modified: file_mtime_iso(skill_dir)
          }
        end)
        |> Enum.sort_by(& &1.name)

      {:error, _} ->
        []
    end
  end

  # ── MCP Servers scanner ─────────────────────────────────────────────────────

  defp scan_mcp_servers do
    settings_mcps = scan_settings_mcp()
    user_mcps = scan_user_mcp_json()
    project_mcps = scan_project_mcps()
    (settings_mcps ++ user_mcps ++ project_mcps) |> Enum.uniq_by(& &1.name)
  end

  defp scan_user_mcp_json do
    case safe_read_json(@user_mcp_path) do
      {:ok, data} ->
        servers = Map.get(data, "mcpServers", %{})

        Enum.map(servers, fn {name, config} ->
          %{
            name: name,
            display_name: name |> String.replace("-", " ") |> titlecase(),
            source: "~/.mcp.json",
            scope: "user",
            status: "configured",
            description: "User MCP: #{Map.get(config, "command", name)}"
          }
        end)

      {:error, _} ->
        []
    end
  end

  defp scan_settings_mcp do
    case safe_read_json(@settings_path) do
      {:ok, data} ->
        # enabledMcpjsonServers is the list of enabled MCP server names
        enabled = Map.get(data, "enabledMcpjsonServers", [])

        enabled
        |> Enum.map(fn name ->
          %{
            name: name,
            display_name: name |> String.replace("-", " ") |> titlecase(),
            source: "~/.claude/settings.json",
            scope: "user",
            status: "enabled",
            description: "MCP server: #{name}"
          }
        end)

      {:error, _} ->
        []
    end
  end

  defp scan_project_mcps do
    # Scan .mcp.json files in known project roots
    project_roots = [
      Path.expand("~/Developer/ccem/apm-v4"),
      Path.expand("~/Developer/ccem")
    ]

    project_roots
    |> Enum.flat_map(fn root ->
      mcp_path = Path.join(root, ".mcp.json")

      case safe_read_json(mcp_path) do
        {:ok, data} ->
          servers = Map.get(data, "mcpServers", %{})

          Enum.map(servers, fn {name, config} ->
            %{
              name: name,
              display_name: name |> String.replace("-", " ") |> titlecase(),
              source: mcp_path,
              scope: "project",
              status: "configured",
              description: "Project MCP: #{Map.get(config, "command", name)}"
            }
          end)

        {:error, _} ->
          []
      end
    end)
  end

  # ── Tools/Hooks scanner ────────────────────────────────────────────────────

  defp scan_tools do
    hooks = scan_hooks()
    hook_tools = scan_hook_tools()
    (hooks ++ hook_tools) |> Enum.uniq_by(& &1.name)
  end

  defp scan_hooks do
    case File.ls(@hooks_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".sh"))
        |> Enum.map(fn file ->
          path = Path.join(@hooks_dir, file)
          name = String.replace_suffix(file, ".sh", "")

          category =
            cond do
              String.contains?(name, "agentlock") -> "agentlock"
              String.contains?(name, "usage") -> "usage"
              String.contains?(name, "session") -> "session"
              String.contains?(name, "subagent") -> "subagent"
              String.contains?(name, "pre_tool") -> "pre_tool_use"
              String.contains?(name, "post_tool") -> "post_tool_use"
              true -> "general"
            end

          %{
            name: name,
            display_name: name |> String.replace("_", " ") |> titlecase(),
            type: "hook",
            category: category,
            source: "~/Developer/ccem/apm/hooks/",
            path: path,
            description: "Shell hook: #{file}",
            last_modified: file_mtime_iso(path)
          }
        end)

      {:error, _} ->
        []
    end
  end

  defp scan_hook_tools do
    # Extract configured hooks from settings.json
    case safe_read_json(@settings_path) do
      {:ok, data} ->
        hooks = Map.get(data, "hooks", %{})

        hooks
        |> Enum.flat_map(fn {hook_type, entries} ->
          entries
          |> Enum.with_index()
          |> Enum.map(fn {entry, idx} ->
            matcher = Map.get(entry, "matcher", "*")
            hook_list = Map.get(entry, "hooks", [])

            command =
              case hook_list do
                [%{"command" => cmd} | _] -> cmd
                _ -> "unknown"
              end

            short_cmd = command |> String.split("/") |> List.last() |> String.slice(0, 60)

            %{
              name: "#{hook_type}-#{idx}-#{matcher}",
              display_name: "#{hook_type}: #{matcher}",
              type: "configured_hook",
              category: String.downcase(hook_type),
              source: "~/.claude/settings.json",
              path: @settings_path,
              description: "#{hook_type} hook [#{matcher}] -> #{short_cmd}",
              last_modified: nil
            }
          end)
        end)

      {:error, _} ->
        []
    end
  end

  # ── Hooks scanner (dedicated category) ─────────────────────────────────────

  defp scan_all_hooks do
    fs_hooks = scan_hooks()
    configured = scan_hook_tools()
    user_hooks = scan_user_hooks_dir()
    (fs_hooks ++ configured ++ user_hooks) |> Enum.uniq_by(& &1.name)
  end

  defp scan_user_hooks_dir do
    user_hooks_dir = Path.expand("~/.claude/hooks")

    case File.ls(user_hooks_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".sh"))
        |> Enum.map(fn file ->
          path = Path.join(user_hooks_dir, file)
          name = String.replace_suffix(file, ".sh", "")

          %{
            name: "user-#{name}",
            display_name: name |> String.replace("_", " ") |> titlecase(),
            type: "user_hook",
            category:
              cond do
                String.contains?(name, "529") -> "rate_limit"
                String.contains?(name, "pre_tool") -> "pre_tool_use"
                String.contains?(name, "post_tool") -> "post_tool_use"
                String.contains?(name, "usage") -> "usage"
                true -> "custom"
              end,
            source: "~/.claude/hooks/",
            scope: "user",
            path: path,
            description: "User hook: #{file}",
            last_modified: file_mtime_iso(path)
          }
        end)

      {:error, _} ->
        []
    end
  end

  # ── Commands scanner ───────────────────────────────────────────────────────

  defp scan_commands do
    file_commands = scan_command_files()
    registry_commands = scan_command_registry()
    (file_commands ++ registry_commands) |> Enum.uniq_by(& &1.name)
  end

  defp scan_command_files do
    case File.ls(@commands_dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(fn entry ->
          String.ends_with?(entry, ".md") or String.ends_with?(entry, ".json")
        end)
        |> Enum.map(fn entry ->
          path = Path.join(@commands_dir, entry)

          name =
            entry
            |> String.replace_suffix(".md", "")
            |> String.replace_suffix(".json", "")

          content = safe_read(path)

          %{
            name: name,
            display_name: "/" <> name,
            source: "~/.claude/commands/",
            path: path,
            description: extract_first_paragraph(content) |> String.slice(0, 200),
            file_type: Path.extname(entry),
            last_modified: file_mtime_iso(path)
          }
        end)

      {:error, _} ->
        []
    end
  end

  defp scan_command_registry do
    slash_path = Path.join(@config_dir, "slash-commands.json")

    case safe_read_json(slash_path) do
      {:ok, data} ->
        commands = Map.get(data, "commands", [])
        normalize_commands(commands, slash_path)

      {:error, _} ->
        []
    end
  end

  # Commands can be a list of maps (each with "command" key) or a map of name->info
  defp normalize_commands(commands, slash_path) when is_list(commands) do
    Enum.map(commands, fn entry ->
      name = Map.get(entry, "command", Map.get(entry, "name", "unknown"))
      desc = Map.get(entry, "description", "")
      subcmds = Map.get(entry, "subcommands", [])
      subcmd_names = Enum.map(subcmds, fn sc -> Map.get(sc, "name", "") end) |> Enum.join(", ")

      %{
        name: name,
        display_name: name,
        source: "~/.claude/config/slash-commands.json",
        path: slash_path,
        description: if(subcmd_names != "", do: "#{desc} [sub: #{subcmd_names}]", else: desc),
        file_type: ".json",
        last_modified: nil
      }
    end)
  end

  defp normalize_commands(commands, slash_path) when is_map(commands) do
    Enum.map(commands, fn {name, info} ->
      %{
        name: name,
        display_name: "/" <> name,
        source: "~/.claude/config/slash-commands.json",
        path: slash_path,
        description:
          if(is_map(info), do: Map.get(info, "description", ""), else: to_string(info)),
        file_type: ".json",
        last_modified: nil
      }
    end)
  end

  defp normalize_commands(_, _), do: []

  # ── Patterns scanner ───────────────────────────────────────────────────────

  defp scan_patterns do
    [
      %{
        name: "formation-topology",
        display_name: "Formation Topology",
        category: "architecture",
        description:
          "Hierarchical agent deployment: Orchestrator > Squadron > Swarm > Cluster > Individual. 5-level tree with wave-based execution.",
        source: "~/.claude/skills/formation/",
        related_skills: ["formation", "orchestrator", "upm"]
      },
      %{
        name: "ralph-autonomous-loop",
        display_name: "Ralph Autonomous Loop",
        category: "methodology",
        description:
          "PRD-driven autonomous fix loop with backpressure management. Reads prd.json, implements stories, runs quality gates, commits, and iterates.",
        source: "~/.claude/skills/ralph/",
        related_skills: ["ralph", "fix-loop"]
      },
      %{
        name: "tdd-red-green-refactor",
        display_name: "TDD Red-Green-Refactor",
        category: "methodology",
        description:
          "Test-driven development with 95% coverage target. Red (failing test) > Green (make it pass) > Refactor. Squadron-based parallel execution.",
        source: "~/.claude/methodologies/claude-flow-tdd.md",
        related_skills: ["spawn", "tdd"]
      },
      %{
        name: "fix-loop",
        display_name: "Fix Loop Process",
        category: "methodology",
        description:
          "4-phase fix loop: Designate agents > Generate combined todo > Create agent tasks with callbacks > Run concurrently in git worktrees.",
        source: "~/.claude/methodologies/fix-loop.md",
        related_skills: ["autofix", "worktree"]
      },
      %{
        name: "coalesce-refinement",
        display_name: "Coalesce Refinement",
        category: "methodology",
        description:
          "5-phase skill refinement from external sources: Research > Analyze > Plan > Apply > Verify. Deploys max-agentic formation (32-128 agents).",
        source: "~/.claude/skills/coalesce/",
        related_skills: ["coalesce", "drtw"]
      },
      %{
        name: "ship-scx-workflow",
        display_name: "Ship / SCX Workflow",
        category: "workflow",
        description:
          "Source Control Excellence: PRD activation > structured commits > QA gates > PR creation > semver tagging > release.",
        source: "~/.claude/skills/ship/",
        related_skills: ["ship", "double-verify"]
      },
      %{
        name: "agentlock-authorization",
        display_name: "AgentLock Authorization",
        category: "security",
        description:
          "3-layer authorization for Claude Code tool invocations. PolicyEngine > TokenStore > RateLimiter with trust ceiling and redaction.",
        source: "~/.claude/skills/apm-auth/",
        related_skills: ["apm-auth", "apm"]
      },
      %{
        name: "upm-project-management",
        display_name: "UPM Project Management",
        category: "workflow",
        description:
          "Unified Project Management: Plane PM integration > Ralph PRD > Formation deployment > TDD verification > Live integration testing.",
        source: "~/.claude/skills/upm/",
        related_skills: ["upm", "plane-pm", "formation"]
      },
      %{
        name: "double-verify",
        display_name: "Double Verify",
        category: "quality",
        description:
          "Cross-agent verification protocol. Spawns independent verification agents to confirm output of primary operations for high-confidence validation.",
        source: "~/.claude/skills/double-verify/",
        related_skills: ["double-verify", "ship"]
      },
      %{
        name: "opsdoc-generation",
        display_name: "OpsDoc Generation",
        category: "documentation",
        description:
          "Production-grade interactive knowledge reports with glassmorphism UI, multi-scenario support, slideshow summaries, and presenter console.",
        source: "~/.claude/skills/opsdoc/",
        related_skills: ["opsdoc", "showcase"]
      }
    ]
  end

  # ── Learnings scanner ──────────────────────────────────────────────────────

  defp scan_learnings do
    case File.ls(@memory_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.map(fn file ->
          path = Path.join(@memory_dir, file)
          name = String.replace_suffix(file, ".md", "")
          content = safe_read(path)

          category =
            cond do
              String.starts_with?(name, "design_") -> "design_decision"
              String.starts_with?(name, "feedback_") -> "feedback"
              String.starts_with?(name, "project_") -> "project"
              String.starts_with?(name, "reference_") -> "reference"
              String.starts_with?(name, "usage_") -> "usage"
              name == "MEMORY" -> "index"
              true -> "general"
            end

          %{
            name: name,
            display_name: name |> String.replace("_", " ") |> titlecase(),
            category: category,
            source: "~/.claude/projects/-Users-jeremiah-Developer-ccem/memory/",
            path: path,
            description: extract_first_paragraph(content) |> String.slice(0, 200),
            size_bytes: byte_size(content),
            last_modified: file_mtime_iso(path)
          }
        end)

      {:error, _} ->
        []
    end
  end

  # ── Shared helpers ─────────────────────────────────────────────────────────

  defp safe_read(path) do
    case File.read(path) do
      {:ok, content} -> content
      {:error, _} -> ""
    end
  end

  defp safe_read_json(path) do
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, data} -> {:ok, data}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_frontmatter(content) do
    case Regex.run(~r/^---\n(.*?)\n---/s, content) do
      [_, yaml_block] ->
        yaml_block
        |> String.split("\n")
        |> Enum.reduce(%{}, fn line, acc ->
          case String.split(line, ": ", parts: 2) do
            [k, v] -> Map.put(acc, String.trim(k), String.trim(v))
            _ -> acc
          end
        end)

      _ ->
        %{}
    end
  end

  defp parse_triggers(content) do
    # Look for "Triggers on:", "Use when:", or "trigger" keyword lines
    content
    |> String.split("\n")
    |> Enum.filter(fn line ->
      lower = String.downcase(line)

      String.contains?(lower, "trigger") or
        String.contains?(lower, "use when") or
        String.contains?(lower, "use this when")
    end)
    |> Enum.take(3)
    |> Enum.map(&String.trim/1)
  end

  defp extract_description(path) do
    content = safe_read(path)
    # Try frontmatter first
    fm = parse_frontmatter(content)

    case Map.get(fm, "description") do
      nil -> extract_first_paragraph(content) |> String.slice(0, 200)
      desc -> desc
    end
  end

  defp extract_first_paragraph(content) do
    content
    |> String.split("\n\n", parts: 3)
    |> Enum.drop_while(fn p ->
      trimmed = String.trim(p)
      trimmed == "" or String.starts_with?(trimmed, "#") or String.starts_with?(trimmed, "---")
    end)
    |> List.first("")
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
  end

  defp file_mtime_iso(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} ->
        mtime |> DateTime.from_unix!() |> DateTime.to_iso8601()

      _ ->
        nil
    end
  end

  defp count_dir_files(dir) do
    case File.ls(dir) do
      {:ok, files} -> length(files)
      _ -> 0
    end
  end

  defp titlecase(str) do
    str
    |> String.split(~r/[\s\-_]+/)
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end
end
