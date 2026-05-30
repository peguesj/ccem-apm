defmodule Apm.Plugins.SimpleAgents.SimpleAgentsPlugin do
  @moduledoc """
  CCEM APM Plugin for SimpleAgents — a Rust-first, multi-provider LLM framework.

  ## What is SimpleAgents?

  SimpleAgents (github.com/CraftsMan-Labs/SimpleAgents) is a Rust workspace providing:
  - Provider-agnostic unified client (OpenAI, Anthropic, OpenRouter)
  - Routing strategies: round-robin, latency-based, cost-based, fallback, circuit-breaker
  - Healing/coercion: JSON-ish parsing and schema coercion
  - Workflow engine: YAML-authored DAG workflows with IR validation, tracing, replay
  - Language bindings: CLI, FFI, Node.js (napi), Python (PyO3), Go
  - OTLP observability: spans for workflow/node execution
  - gRPC worker protocol for distributed task execution

  ## Integration Architecture

  SimpleAgents is a LIBRARY — it exposes no HTTP server.
  This plugin integrates via four data surfaces:

  1. **Workspace metadata** — reads Cargo.toml for crate inventory and version
  2. **CLI subprocess** — runs `simple-agents` binary to inspect workspace state
  3. **Trace file scan** — discovers `*.trace.json` files emitted by workflows
  4. **Process inspection** — detects live SimpleAgents processes via OS tools

  ## AgentLock Context

  READ-ONLY data bridge. No destructive operations. No write access.
  - Risk level: LOW
  - Auth scope: read:agents, read:tools, read:tasks
  - Trust level: internal (same machine)

  ## Actions

  - `workspace_info`  — crate inventory, version, Rust edition from Cargo.toml
  - `list_agents`     — detect running SimpleAgents OS processes
  - `list_tools`      — tool definitions extracted from workflow YAML files
  - `list_traces`     — discover trace JSON files under configured trace directories
  - `get_trace`       — parse and return a single trace file
  - `list_tasks`      — scan traces for task executions with status filtering
  - `get_metrics`     — aggregate metrics: success rate, durations, workflow frequency
  - `trace_summary`   — aggregate stats: min/max/avg durations, error rates, unique workflows
  - `provider_stats`  — token/request metrics grouped by inferred provider
  - `list_workflows`  — discover YAML workflow definitions in the workspace
  - `parity_status`   — parse parity-fixtures binding contracts
  """

  @behaviour Apm.Plugins.PluginBehaviour

  require Logger

  # Workspace defaults
  @default_workspace Path.expand("~/Developer/SimpleAgents")
  @default_trace_dirs [
    "examples/workflow_email/traces",
    "crates/simple-agents-workflow/tests/fixtures"
  ]

  # Fallback scan roots for wildcard discovery
  @scan_roots [
    "~/Developer/SimpleAgents",
    "~/Developer",
    "/tmp"
  ]

  @crate_names [
    "simple-agent-type",
    "simple-agents-core",
    "simple-agents-providers",
    "simple-agents-router",
    "simple-agents-cache",
    "simple-agents-healing",
    "simple-agents-workflow",
    "simple-agents-workflow-workers",
    "simple-agents-cli",
    "simple-agents-ffi",
    "simple-agents-napi",
    "simple-agents-py",
    "simple-agents-macros"
  ]

  @cli_binary "simple-agents"
  @max_trace_files 50
  @max_workflow_files 100

  # ── PluginBehaviour ──────────────────────────────────────────────────────────

  @impl true
  @spec plugin_name() :: String.t()
  def plugin_name, do: "simple_agents"

  @impl true
  @spec plugin_description() :: String.t()
  def plugin_description,
    do: "SimpleAgents — Rust LLM framework bridge: workspace info, running agents, workflow traces, tool definitions, execution metrics, provider stats, parity contracts"

  @impl true
  @spec plugin_version() :: String.t()
  def plugin_version, do: "2.0.0"

  @impl true
  @spec list_endpoints() :: [map()]
  def list_endpoints do
    [
      %{
        action: "workspace_info",
        description: "Workspace metadata: root path, workspace version, Rust edition, crate inventory",
        params: %{workspace_root: "string (optional)"}
      },
      %{
        action: "list_agents",
        description: "Detect running SimpleAgents OS processes (CLI sessions, gRPC workers) via pgrep",
        params: %{}
      },
      %{
        action: "list_tools",
        description: "Extract tool definitions from workflow YAML files in known SimpleAgents directories",
        params: %{
          scan_path: "string (optional — override default scan root)",
          workflow_name: "string (optional — filter by workflow name substring)"
        }
      },
      %{
        action: "list_traces",
        description: "Discover workflow trace JSON files under configured trace directories",
        params: %{
          workspace_root: "string (optional)",
          trace_dirs: "list of strings (optional)"
        }
      },
      %{
        action: "get_trace",
        description: "Parse and return a single trace file by path (absolute or workspace-relative)",
        params: %{path: "string (required)"}
      },
      %{
        action: "list_tasks",
        description: "Scan trace files for task executions with optional status filtering",
        params: %{
          scan_path: "string (optional)",
          status: "string (optional — one of: completed|failed|active)",
          limit: "integer (optional — max results, default 10)"
        }
      },
      %{
        action: "get_metrics",
        description: "Aggregate metrics across all discovered traces: counts, success rate, node stats, workflow frequency",
        params: %{scan_path: "string (optional)"}
      },
      %{
        action: "trace_summary",
        description: "Aggregate stats across workspace traces: min/max/avg durations, unique workflows",
        params: %{
          workspace_root: "string (optional)",
          trace_dirs: "list of strings (optional)"
        }
      },
      %{
        action: "provider_stats",
        description: "Token and request metrics from traces grouped by inferred provider (openai/anthropic/openrouter)",
        params: %{
          workspace_root: "string (optional)",
          trace_dirs: "list of strings (optional)"
        }
      },
      %{
        action: "list_workflows",
        description: "Discover YAML workflow definition files in the workspace with metadata",
        params: %{
          workspace_root: "string (optional)",
          scan_path: "string (optional — alternate wildcard scan root)"
        }
      },
      %{
        action: "parity_status",
        description: "Parse parity-fixtures binding contracts for multi-language parity checks",
        params: %{workspace_root: "string (optional)"}
      }
    ]
  end

  @impl true
  @spec handle_action(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}

  # ── workspace_info ────────────────────────────────────────────────────────────

  def handle_action("workspace_info", params, _opts) do
    root = workspace_root(params)

    case read_workspace_cargo(root) do
      {:ok, cargo_data} ->
        crate_inventory = build_crate_inventory(root)

        {:ok,
         %{
           workspace_root: root,
           workspace_version: extract_version(cargo_data),
           rust_edition: extract_edition(cargo_data),
           crates: crate_inventory,
           crate_count: length(crate_inventory),
           repository: "https://github.com/CraftsMan-Labs/SimpleAgents",
           docs: "https://docs.simpleagents.craftsmanlabs.net/",
           playground: "https://yamslam.craftsmanlabs.net/playground"
         }}

      {:error, :not_found} ->
        {:error, {:not_found, "SimpleAgents workspace not found at #{root}. Set workspace_root param."}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── list_agents ───────────────────────────────────────────────────────────────

  def handle_action("list_agents", _params, _opts) do
    agents = detect_running_agents()
    cli_path = find_cli_binary()

    {:ok,
     %{
       agents: agents,
       count: length(agents),
       cli_binary: cli_path,
       cli_available: cli_path != nil,
       scanned_at: DateTime.utc_now() |> DateTime.to_iso8601()
     }}
  end

  # ── list_tools ────────────────────────────────────────────────────────────────

  def handle_action("list_tools", params, _opts) do
    scan_path = resolve_scan_path(params)
    filter = Map.get(params, "workflow_name", "")

    workflows = discover_workflow_files(scan_path)
    tools = extract_tools_from_workflows(workflows, filter)

    {:ok,
     %{
       tools: tools,
       count: length(tools),
       workflows_scanned: length(workflows),
       scan_path: scan_path
     }}
  end

  # ── list_traces ───────────────────────────────────────────────────────────────

  def handle_action("list_traces", params, _opts) do
    root = workspace_root(params)
    dirs = trace_dirs(params)
    traces = discover_traces(root, dirs)

    {:ok,
     %{
       workspace_root: root,
       trace_dirs: dirs,
       traces: traces,
       count: length(traces)
     }}
  end

  # ── get_trace ─────────────────────────────────────────────────────────────────

  def handle_action("get_trace", %{"path" => path}, _opts) do
    abs_path =
      if Path.type(path) == :absolute do
        path
      else
        Path.join(@default_workspace, path)
      end

    case read_json_file(abs_path) do
      {:ok, data} -> {:ok, %{path: abs_path, trace: normalize_trace(data)}}
      {:error, reason} -> {:error, {:read_failed, abs_path, reason}}
    end
  end

  def handle_action("get_trace", _params, _opts) do
    {:error, {:missing_param, "path is required"}}
  end

  # ── list_tasks ────────────────────────────────────────────────────────────────

  def handle_action("list_tasks", params, _opts) do
    scan_path = resolve_scan_path(params)
    status_filter = Map.get(params, "status")
    limit = parse_integer(Map.get(params, "limit"), 10)

    trace_files = discover_trace_files(scan_path)
    tasks = load_tasks(trace_files, status_filter, limit)

    {:ok,
     %{
       tasks: tasks,
       count: length(tasks),
       trace_files_found: length(trace_files),
       scan_path: scan_path
     }}
  end

  # ── get_metrics ───────────────────────────────────────────────────────────────

  def handle_action("get_metrics", params, _opts) do
    scan_path = resolve_scan_path(params)
    trace_files = discover_trace_files(scan_path)
    all_traces = load_tasks(trace_files, nil, @max_trace_files)

    metrics = compute_aggregate_metrics(all_traces)

    {:ok,
     Map.merge(metrics, %{
       trace_files_found: length(trace_files),
       scan_path: scan_path,
       computed_at: DateTime.utc_now() |> DateTime.to_iso8601()
     })}
  end

  # ── trace_summary ─────────────────────────────────────────────────────────────

  def handle_action("trace_summary", params, _opts) do
    root = workspace_root(params)
    dirs = trace_dirs(params)
    traces = discover_and_parse_traces(root, dirs)

    summary = aggregate_trace_summary(traces)

    {:ok,
     %{
       workspace_root: root,
       trace_count: length(traces),
       summary: summary
     }}
  end

  # ── provider_stats ────────────────────────────────────────────────────────────

  def handle_action("provider_stats", params, _opts) do
    root = workspace_root(params)
    dirs = trace_dirs(params)
    traces = discover_and_parse_traces(root, dirs)

    stats = build_provider_stats(traces)

    {:ok,
     %{
       workspace_root: root,
       trace_count: length(traces),
       provider_stats: stats
     }}
  end

  # ── list_workflows ────────────────────────────────────────────────────────────

  def handle_action("list_workflows", params, _opts) do
    root = workspace_root(params)

    # Prefer workspace-structured discovery; fall back to wildcard scan
    workflows =
      case discover_workspace_workflows(root) do
        [] -> discover_workflow_files(resolve_scan_path(params)) |> Enum.map(&enrich_workflow_file/1)
        found -> found
      end

    {:ok,
     %{
       workspace_root: root,
       workflows: workflows,
       count: length(workflows)
     }}
  end

  # ── parity_status ─────────────────────────────────────────────────────────────

  def handle_action("parity_status", params, _opts) do
    root = workspace_root(params)
    fixtures_dir = Path.join(root, "parity-fixtures")

    case File.ls(fixtures_dir) do
      {:ok, files} ->
        contracts =
          files
          |> Enum.filter(&String.ends_with?(&1, ".json"))
          |> Enum.map(fn file ->
            path = Path.join(fixtures_dir, file)

            case read_json_file(path) do
              {:ok, data} ->
                %{file: file, path: path, keys: (if is_map(data), do: Map.keys(data), else: []), status: "parsed"}

              {:error, _} ->
                %{file: file, path: path, keys: [], status: "parse_error"}
            end
          end)

        {:ok, %{fixtures_dir: fixtures_dir, contracts: contracts, count: length(contracts)}}

      {:error, :enoent} ->
        {:ok, %{fixtures_dir: fixtures_dir, contracts: [], count: 0, note: "parity-fixtures directory not found"}}

      {:error, reason} ->
        {:error, {:filesystem_error, reason}}
    end
  end

  def handle_action(action, _params, _opts) do
    {:error, {:unknown_action, action}}
  end

  # ── Workspace helpers ─────────────────────────────────────────────────────────

  defp workspace_root(%{"workspace_root" => root}) when is_binary(root) and root != "", do: Path.expand(root)
  defp workspace_root(_), do: @default_workspace

  defp trace_dirs(%{"trace_dirs" => dirs}) when is_list(dirs) and dirs != [], do: dirs
  defp trace_dirs(_), do: @default_trace_dirs

  defp read_workspace_cargo(root) do
    path = Path.join(root, "Cargo.toml")

    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp extract_version(cargo_toml) when is_binary(cargo_toml) do
    case Regex.run(~r/\[workspace\.package\].*?version\s*=\s*"([^"]+)"/ms, cargo_toml) do
      [_, version] -> version
      _ ->
        case Regex.run(~r/version\s*=\s*"([^"]+)"/, cargo_toml) do
          [_, version] -> version
          _ -> "unknown"
        end
    end
  end

  defp extract_edition(cargo_toml) when is_binary(cargo_toml) do
    case Regex.run(~r/edition\s*=\s*"([^"]+)"/, cargo_toml) do
      [_, edition] -> edition
      _ -> "unknown"
    end
  end

  defp build_crate_inventory(root) do
    crates_dir = Path.join(root, "crates")

    case File.ls(crates_dir) do
      {:ok, dirs} ->
        dirs
        |> Enum.filter(&File.dir?(Path.join(crates_dir, &1)))
        |> Enum.map(fn crate ->
          crate_path = Path.join(crates_dir, crate)
          cargo_path = Path.join(crate_path, "Cargo.toml")

          %{
            name: crate,
            path: crate_path,
            version: read_crate_version(cargo_path),
            src_files: count_rust_files(Path.join(crate_path, "src")),
            is_known: Enum.member?(@crate_names, crate)
          }
        end)
        |> Enum.sort_by(& &1.name)

      {:error, _} ->
        Enum.map(@crate_names, fn name ->
          %{name: name, path: Path.join([root, "crates", name]), version: "unknown", src_files: 0, is_known: true}
        end)
    end
  end

  defp read_crate_version(cargo_path) do
    case File.read(cargo_path) do
      {:ok, content} ->
        case Regex.run(~r/^version\s*=\s*"([^"]+)"/m, content) do
          [_, v] -> v
          _ -> "workspace"
        end

      {:error, _} ->
        "unknown"
    end
  end

  defp count_rust_files(src_dir) do
    case File.ls(src_dir) do
      {:ok, files} -> files |> Enum.filter(&String.ends_with?(&1, ".rs")) |> length()
      {:error, _} -> 0
    end
  end

  # ── Agent Detection ──────────────────────────────────────────────────────────

  defp detect_running_agents do
    case System.cmd("pgrep", ["-l", "simple-agents"], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.map(&parse_pgrep_line/1)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp parse_pgrep_line(line) do
    case String.split(line, " ", parts: 2) do
      [pid_str, cmd] ->
        %{
          pid: String.trim(pid_str),
          command: String.trim(cmd),
          type: classify_agent_command(cmd),
          detected_at: DateTime.utc_now() |> DateTime.to_iso8601()
        }

      _ ->
        nil
    end
  end

  defp classify_agent_command(cmd) do
    cond do
      String.contains?(cmd, "worker") -> "grpc_worker"
      String.contains?(cmd, "chat") -> "cli_chat"
      String.contains?(cmd, "complete") -> "cli_complete"
      String.contains?(cmd, "workflow") -> "workflow_runner"
      String.contains?(cmd, "benchmark") -> "cli_benchmark"
      true -> "simple_agents_process"
    end
  end

  defp find_cli_binary do
    case System.cmd("which", [@cli_binary], stderr_to_stdout: true) do
      {path, 0} -> String.trim(path)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # ── Wildcard Workflow Discovery (for list_tools / list_tasks) ─────────────────

  defp resolve_scan_path(%{"scan_path" => path}) when is_binary(path) and path != "", do: Path.expand(path)
  defp resolve_scan_path(_), do: @scan_roots |> List.first() |> Path.expand()

  defp discover_workflow_files(scan_path) do
    ["**/*.yaml", "**/*.yml"]
    |> Enum.flat_map(fn pattern -> Path.wildcard(Path.join(scan_path, pattern)) end)
    |> Enum.filter(&is_simple_agents_workflow?/1)
    |> Enum.take(@max_workflow_files)
  rescue
    _ -> []
  end

  defp is_simple_agents_workflow?(path) do
    case File.read(path) do
      {:ok, content} ->
        String.contains?(content, "version:") and
          (String.contains?(content, "nodes:") or
             String.contains?(content, "type: llm") or
             String.contains?(content, "type: tool"))

      _ ->
        false
    end
  end

  defp enrich_workflow_file(path) do
    stat = File.stat!(path)

    base = %{
      path: path,
      file: Path.basename(path),
      dir: Path.dirname(path) |> Path.relative_to(@default_workspace),
      size_bytes: stat.size,
      modified_at: stat.mtime |> format_mtime()
    }

    case File.read(path) do
      {:ok, content} -> Map.merge(base, extract_workflow_metadata(content))
      _ -> base
    end
  end

  defp extract_workflow_metadata(content) do
    %{
      workflow_name:
        Regex.run(~r/^name:\s+(.+)$/m, content, capture: :all_but_first)
        |> case do
          [n | _] -> String.trim(n)
          _ -> nil
        end,
      version:
        Regex.run(~r/^version:\s+(.+)$/m, content, capture: :all_but_first)
        |> case do
          [v | _] -> String.trim(v)
          _ -> nil
        end,
      node_count: Regex.scan(~r/^\s+-\s+id:/m, content) |> length(),
      llm_nodes: Regex.scan(~r/type:\s+llm/m, content) |> length(),
      tool_nodes: Regex.scan(~r/type:\s+tool/m, content) |> length()
    }
  end

  # ── Workspace Workflow Discovery (structured dirs) ────────────────────────────

  defp discover_workspace_workflows(root) do
    search_dirs = [
      "examples",
      "examples/workflow_email",
      "workers/python",
      "workers/typescript",
      "workers/go"
    ]

    search_dirs
    |> Enum.flat_map(fn dir ->
      abs_dir = Path.join(root, dir)
      discover_yaml_in_dir(abs_dir, dir)
    end)
    |> Enum.sort_by(& &1.file)
  end

  defp discover_yaml_in_dir(abs_dir, rel_dir) do
    case File.ls(abs_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(fn f -> String.ends_with?(f, ".yaml") or String.ends_with?(f, ".yml") end)
        |> Enum.map(fn file ->
          abs_path = Path.join(abs_dir, file)
          stat = File.stat!(abs_path)

          %{
            file: file,
            path: abs_path,
            dir: rel_dir,
            size_bytes: stat.size,
            name: file |> Path.rootname() |> String.replace(~r/[-_]/, " "),
            modified_at: stat.mtime |> format_mtime()
          }
        end)

      {:error, _} ->
        []
    end
  end

  # ── Tool Extraction ──────────────────────────────────────────────────────────

  defp extract_tools_from_workflows(workflow_files, filter) do
    workflow_files
    |> Enum.filter(fn path ->
      filter == "" or String.contains?(String.downcase(Path.basename(path)), String.downcase(filter))
    end)
    |> Enum.flat_map(&extract_tools_from_file/1)
    |> Enum.uniq_by(& &1.tool_name)
  end

  defp extract_tools_from_file(path) do
    case File.read(path) do
      {:ok, content} ->
        Regex.scan(~r/tool:\s+(\S+)/m, content, capture: :all_but_first)
        |> List.flatten()
        |> Enum.map(fn tool_name ->
          %{
            tool_name: String.trim(tool_name),
            source_file: path,
            workflow_name: Path.basename(path, ".yaml") |> String.replace("-", "_")
          }
        end)

      _ ->
        []
    end
  end

  # ── Wildcard Trace Discovery (for list_tasks / get_metrics) ──────────────────

  defp discover_trace_files(scan_path) do
    ["**/*.trace.json", "**/workflow_trace_*.json", "**/trace_*.json"]
    |> Enum.flat_map(fn pattern -> Path.wildcard(Path.join(scan_path, pattern)) end)
    |> Enum.uniq()
    |> Enum.take(@max_trace_files)
  rescue
    _ -> []
  end

  defp load_tasks(trace_files, status_filter, limit) do
    trace_files
    |> Enum.flat_map(&read_task_trace/1)
    |> Enum.filter(fn trace ->
      case status_filter do
        nil -> true
        "active" -> Map.get(trace, :status) == "in_progress"
        "completed" -> Map.get(trace, :status) == "completed"
        "failed" -> Map.get(trace, :status) == "failed"
        _ -> true
      end
    end)
    |> Enum.sort_by(& &1.started_at_unix_ms, :desc)
    |> Enum.take(limit)
  end

  defp read_task_trace(path) do
    with {:ok, content} <- File.read(path),
         {:ok, raw} <- Jason.decode(content),
         %{} = trace <- normalize_trace(raw) do
      [Map.put(trace, :source_file, path)]
    else
      _ -> []
    end
  end

  # ── Workspace Trace Discovery (for trace_summary / provider_stats) ────────────

  defp discover_traces(root, dirs) do
    dirs
    |> Enum.flat_map(fn dir ->
      abs_dir = Path.join(root, dir)

      case File.ls(abs_dir) do
        {:ok, files} ->
          files
          |> Enum.filter(&String.ends_with?(&1, ".json"))
          |> Enum.map(fn file ->
            abs_path = Path.join(abs_dir, file)
            stat = File.stat!(abs_path)

            %{
              file: file,
              path: abs_path,
              dir: dir,
              size_bytes: stat.size,
              mtime: stat.mtime |> format_mtime()
            }
          end)

        {:error, _} ->
          []
      end
    end)
    |> Enum.sort_by(& &1.file)
  end

  defp discover_and_parse_traces(root, dirs) do
    discover_traces(root, dirs)
    |> Enum.map(fn file_meta ->
      case read_json_file(file_meta.path) do
        {:ok, data} -> Map.put(file_meta, :trace, normalize_trace(data))
        {:error, _} -> Map.put(file_meta, :trace, nil)
      end
    end)
    |> Enum.filter(&(not is_nil(&1.trace)))
  end

  # ── Trace Normalization ──────────────────────────────────────────────────────

  defp normalize_trace(data) when is_map(data) do
    metadata = data["metadata"] || %{}
    events = data["events"] || []

    node_enters = Enum.filter(events, &(&1["event"] == "node_enter"))
    node_exits = Enum.filter(events, &(&1["event"] == "node_exit"))
    node_errors = Enum.filter(events, &(&1["event"] == "node_error"))
    terminal = Enum.find(events, &(&1["event"] == "terminal"))

    started_ms = metadata["started_at_unix_ms"] || 0
    finished_ms = metadata["finished_at_unix_ms"]

    duration_ms =
      if is_integer(finished_ms) and is_integer(started_ms) and started_ms > 0 do
        finished_ms - started_ms
      else
        nil
      end

    node_ids = node_enters |> Enum.map(& &1["node_id"]) |> Enum.uniq()

    status = (terminal && terminal["status"]) || "in_progress"

    %{
      trace_id: metadata["trace_id"],
      workflow_name: metadata["workflow_name"],
      workflow_version: metadata["workflow_version"],
      started_at_unix_ms: started_ms,
      finished_at_unix_ms: finished_ms,
      duration_ms: duration_ms,
      status: status,
      event_count: length(events),
      node_count: length(node_ids),
      node_ids: node_ids,
      node_success_count: length(node_exits),
      node_error_count: length(node_errors),
      errors: Enum.map(node_errors, fn e -> %{node_id: e["node_id"], message: e["message"]} end),
      events: Enum.map(events, &normalize_event/1)
    }
  end

  defp normalize_trace(_), do: nil

  defp normalize_event(event) when is_map(event) do
    %{
      seq: event["seq"],
      timestamp_unix_ms: event["timestamp_unix_ms"],
      event: event["event"],
      node_id: event["node_id"],
      message: event["message"],
      status: event["status"]
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp normalize_event(_), do: %{}

  # ── Aggregate Metrics (wildcard scan) ────────────────────────────────────────

  defp compute_aggregate_metrics(traces) do
    total = length(traces)
    completed = Enum.count(traces, fn t -> Map.get(t, :status) == "completed" end)
    failed = Enum.count(traces, fn t -> Map.get(t, :status) == "failed" end)
    active = total - completed - failed

    total_nodes = traces |> Enum.map(& &1[:node_success_count]) |> Enum.reject(&is_nil/1) |> Enum.sum()
    total_errors = traces |> Enum.map(& &1[:node_error_count]) |> Enum.reject(&is_nil/1) |> Enum.sum()

    durations =
      traces
      |> Enum.map(& &1[:duration_ms])
      |> Enum.reject(&is_nil/1)
      |> Enum.reject(&(&1 < 0))

    avg_duration_ms = if durations == [], do: nil, else: Enum.sum(durations) |> div(length(durations))

    success_rate = if total > 0, do: Float.round(completed / total * 100, 1), else: nil

    workflows_by_frequency =
      traces
      |> Enum.map(& &1[:workflow_name])
      |> Enum.reject(&is_nil/1)
      |> Enum.frequencies()
      |> Enum.map(fn {name, count} -> %{workflow_name: name, run_count: count} end)
      |> Enum.sort_by(& &1.run_count, :desc)

    %{
      total_traces: total,
      completed: completed,
      failed: failed,
      active: active,
      total_node_executions: total_nodes,
      total_node_errors: total_errors,
      avg_duration_ms: avg_duration_ms,
      success_rate_pct: success_rate,
      workflows_by_frequency: workflows_by_frequency
    }
  end

  # ── Aggregate Summary (workspace scan) ───────────────────────────────────────

  defp aggregate_trace_summary(parsed_traces) do
    traces = Enum.map(parsed_traces, & &1.trace)
    total = length(traces)
    completed = Enum.count(traces, &(&1.status == "completed"))
    failed = Enum.count(traces, &(&1.status == "failed"))
    in_progress = total - completed - failed

    durations = traces |> Enum.map(& &1.duration_ms) |> Enum.filter(&is_integer/1)

    avg_duration_ms = if durations == [], do: nil, else: Enum.sum(durations) |> div(length(durations))

    total_events = traces |> Enum.map(& &1.event_count) |> Enum.sum()
    total_errors = traces |> Enum.map(& &1.node_error_count) |> Enum.sum()

    unique_workflows = traces |> Enum.map(& &1.workflow_name) |> Enum.filter(& &1) |> Enum.uniq() |> Enum.sort()

    %{
      total_traces: total,
      completed: completed,
      failed: failed,
      in_progress: in_progress,
      success_rate_pct: if(total > 0, do: Float.round(completed / total * 100, 1), else: 0.0),
      avg_duration_ms: avg_duration_ms,
      max_duration_ms: if(durations == [], do: nil, else: Enum.max(durations)),
      min_duration_ms: if(durations == [], do: nil, else: Enum.min(durations)),
      total_events: total_events,
      total_node_errors: total_errors,
      unique_workflows: unique_workflows,
      workflow_count: length(unique_workflows)
    }
  end

  # ── Provider Stats ────────────────────────────────────────────────────────────

  defp build_provider_stats(parsed_traces) do
    parsed_traces
    |> Enum.group_by(fn file_meta ->
      wf = (file_meta.trace && file_meta.trace.workflow_name) || "unknown"
      infer_provider(wf)
    end)
    |> Enum.map(fn {provider, file_metas} ->
      traces = Enum.map(file_metas, & &1.trace)
      total = length(traces)
      completed = Enum.count(traces, &(&1.status == "completed"))
      durations = traces |> Enum.map(& &1.duration_ms) |> Enum.filter(&is_integer/1)

      %{
        provider: provider,
        trace_count: total,
        completed: completed,
        success_rate_pct: if(total > 0, do: Float.round(completed / total * 100, 1), else: 0.0),
        avg_duration_ms: if(durations == [], do: nil, else: Enum.sum(durations) |> div(length(durations))),
        workflows:
          traces
          |> Enum.map(& &1.workflow_name)
          |> Enum.filter(& &1)
          |> Enum.uniq()
          |> Enum.sort()
      }
    end)
    |> Enum.sort_by(& &1.provider)
  end

  defp infer_provider(workflow_name) when is_binary(workflow_name) do
    name = String.downcase(workflow_name)

    cond do
      String.contains?(name, "openai") or String.contains?(name, "gpt") -> "openai"
      String.contains?(name, "anthropic") or String.contains?(name, "claude") -> "anthropic"
      String.contains?(name, "openrouter") -> "openrouter"
      true -> "generic"
    end
  end

  defp infer_provider(_), do: "unknown"

  # ── File Helpers ─────────────────────────────────────────────────────────────

  defp read_json_file(path) do
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, data} -> {:ok, data}
          {:error, reason} -> {:error, {:json_decode, reason}}
        end

      {:error, reason} ->
        {:error, {:file_read, reason}}
    end
  end

  defp format_mtime({{y, mo, d}, {h, mi, s}}) do
    "#{y}-#{pad2(mo)}-#{pad2(d)}T#{pad2(h)}:#{pad2(mi)}:#{pad2(s)}Z"
  rescue
    _ -> "unknown"
  end

  defp pad2(n), do: String.pad_leading(Integer.to_string(n), 2, "0")

  defp parse_integer(nil, default), do: default
  defp parse_integer(val, _) when is_integer(val), do: max(1, min(val, @max_trace_files))

  defp parse_integer(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {n, ""} -> max(1, min(n, @max_trace_files))
      _ -> default
    end
  end

  defp parse_integer(_, default), do: default
end
