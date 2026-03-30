defmodule ApmV5.Plugins.SimpleAgents.SimpleAgentsPlugin do
  @moduledoc """
  APM Plugin for SimpleAgents — a Rust-first LLM framework.

  SimpleAgents (github.com/CraftsMan-Labs/SimpleAgents) provides a unified
  client, provider adapters (OpenAI/Anthropic/OpenRouter), routing, caching,
  healing/coercion, and workflow execution with trace observability.

  This plugin reads the local SimpleAgents workspace to surface:
    - Workspace metadata and crate inventory
    - Workflow trace files from configured trace directories
    - Provider statistics aggregated from trace events
    - Parity fixture contract status

  Actions:
    - "workspace_info"    — crate list, version, root path
    - "list_traces"       — discover trace JSON files under trace_dirs
    - "get_trace"         — parse and return a single trace file
    - "trace_summary"     — aggregate stats across all discovered traces
    - "provider_stats"    — token/request metrics from traces grouped by provider
    - "list_workflows"    — discover YAML workflow definitions
    - "parity_status"     — parse parity-fixtures binding contracts

  Configuration (all optional, sensible defaults):
    - `workspace_root`  — path to the SimpleAgents repo (defaults to ~/Developer/SimpleAgents)
    - `trace_dirs`      — list of subdirs to scan for *.json trace files
  """

  @behaviour ApmV5.Plugins.PluginBehaviour

  @default_workspace Path.expand("~/Developer/SimpleAgents")

  @default_trace_dirs [
    "examples/workflow_email/traces",
    "crates/simple-agents-workflow/tests/fixtures"
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

  # ── PluginBehaviour ──────────────────────────────────────────────────────────

  @impl true
  @spec plugin_name() :: String.t()
  def plugin_name, do: "simple_agents"

  @impl true
  @spec plugin_description() :: String.t()
  def plugin_description,
    do: "SimpleAgents — Rust LLM framework monitor: workspace info, workflow traces, provider stats, parity contracts"

  @impl true
  @spec plugin_version() :: String.t()
  def plugin_version, do: "1.0.0"

  @impl true
  @spec list_endpoints() :: [map()]
  def list_endpoints do
    [
      %{
        action: "workspace_info",
        description: "Workspace metadata: root path, workspace version, crate inventory",
        params: %{workspace_root: "string (optional)"}
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
        description: "Parse and return a single trace file by path",
        params: %{path: "string (required — absolute or relative to workspace_root)"}
      },
      %{
        action: "trace_summary",
        description: "Aggregate stats across all discovered traces (counts, durations, error rates)",
        params: %{
          workspace_root: "string (optional)",
          trace_dirs: "list of strings (optional)"
        }
      },
      %{
        action: "provider_stats",
        description: "Token and request metrics from traces, grouped by provider hint from workflow name",
        params: %{
          workspace_root: "string (optional)",
          trace_dirs: "list of strings (optional)"
        }
      },
      %{
        action: "list_workflows",
        description: "Discover YAML workflow definition files in the workspace",
        params: %{workspace_root: "string (optional)"}
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

  def handle_action("get_trace", %{"path" => path}, _opts) do
    abs_path =
      if Path.type(path) == :absolute do
        path
      else
        Path.join(@default_workspace, path)
      end

    case read_json_file(abs_path) do
      {:ok, data} ->
        {:ok, %{path: abs_path, trace: normalize_trace(data)}}

      {:error, reason} ->
        {:error, {:read_failed, abs_path, reason}}
    end
  end

  def handle_action("get_trace", _params, _opts) do
    {:error, {:missing_param, "path is required"}}
  end

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

  def handle_action("list_workflows", params, _opts) do
    root = workspace_root(params)
    workflows = discover_workflows(root)

    {:ok,
     %{
       workspace_root: root,
       workflows: workflows,
       count: length(workflows)
     }}
  end

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
                %{
                  file: file,
                  path: path,
                  keys: if(is_map(data), do: Map.keys(data), else: []),
                  status: "parsed"
                }

              {:error, _} ->
                %{file: file, path: path, keys: [], status: "parse_error"}
            end
          end)

        {:ok,
         %{
           fixtures_dir: fixtures_dir,
           contracts: contracts,
           count: length(contracts)
         }}

      {:error, :enoent} ->
        {:ok, %{fixtures_dir: fixtures_dir, contracts: [], count: 0, note: "parity-fixtures directory not found"}}

      {:error, reason} ->
        {:error, {:filesystem_error, reason}}
    end
  end

  def handle_action(action, _params, _opts) do
    {:error, {:unknown_action, action}}
  end

  # ── Private helpers ──────────────────────────────────────────────────────────

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
          version = read_crate_version(cargo_path)
          src_files = count_rust_files(Path.join(crate_path, "src"))

          %{
            name: crate,
            path: crate_path,
            version: version,
            src_files: src_files,
            is_known: Enum.member?(@crate_names, crate)
          }
        end)
        |> Enum.sort_by(& &1.name)

      {:error, _} ->
        # Fall back to known crate list
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
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".rs"))
        |> length()

      {:error, _} ->
        0
    end
  end

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
    trace_files = discover_traces(root, dirs)

    Enum.map(trace_files, fn file_meta ->
      case read_json_file(file_meta.path) do
        {:ok, data} -> Map.put(file_meta, :trace, normalize_trace(data))
        {:error, _} -> Map.put(file_meta, :trace, nil)
      end
    end)
    |> Enum.filter(&(not is_nil(&1.trace)))
  end

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
      if is_integer(finished_ms) and is_integer(started_ms) do
        finished_ms - started_ms
      else
        nil
      end

    node_ids =
      node_enters
      |> Enum.map(& &1["node_id"])
      |> Enum.uniq()

    %{
      trace_id: metadata["trace_id"],
      workflow_name: metadata["workflow_name"],
      workflow_version: metadata["workflow_version"],
      started_at_unix_ms: started_ms,
      finished_at_unix_ms: finished_ms,
      duration_ms: duration_ms,
      status: (terminal && terminal["status"]) || "in_progress",
      event_count: length(events),
      node_count: length(node_ids),
      node_ids: node_ids,
      node_success_count: length(node_exits),
      node_error_count: length(node_errors),
      errors: Enum.map(node_errors, fn e -> %{node_id: e["node_id"], message: e["message"]} end)
    }
  end

  defp normalize_trace(_), do: nil

  defp aggregate_trace_summary(parsed_traces) do
    traces = Enum.map(parsed_traces, & &1.trace)

    total = length(traces)
    completed = Enum.count(traces, &(&1.status == "completed"))
    failed = Enum.count(traces, &(&1.status == "failed"))
    in_progress = total - completed - failed

    durations =
      traces
      |> Enum.map(& &1.duration_ms)
      |> Enum.filter(&is_integer/1)

    avg_duration_ms =
      if length(durations) > 0 do
        Enum.sum(durations) |> div(length(durations))
      else
        nil
      end

    max_duration_ms = if length(durations) > 0, do: Enum.max(durations), else: nil
    min_duration_ms = if length(durations) > 0, do: Enum.min(durations), else: nil

    total_events = traces |> Enum.map(& &1.event_count) |> Enum.sum()
    total_errors = traces |> Enum.map(& &1.node_error_count) |> Enum.sum()

    workflow_names =
      traces
      |> Enum.map(& &1.workflow_name)
      |> Enum.filter(& &1)
      |> Enum.uniq()
      |> Enum.sort()

    %{
      total_traces: total,
      completed: completed,
      failed: failed,
      in_progress: in_progress,
      success_rate_pct: if(total > 0, do: Float.round(completed / total * 100, 1), else: 0.0),
      avg_duration_ms: avg_duration_ms,
      max_duration_ms: max_duration_ms,
      min_duration_ms: min_duration_ms,
      total_events: total_events,
      total_node_errors: total_errors,
      unique_workflows: workflow_names,
      workflow_count: length(workflow_names)
    }
  end

  defp build_provider_stats(parsed_traces) do
    # Infer provider from workflow name (e.g. "email-chat-with-openai" -> "openai")
    # Since traces don't embed provider directly, we group by workflow_name prefix
    parsed_traces
    |> Enum.group_by(fn file_meta ->
      wf = (file_meta.trace && file_meta.trace.workflow_name) || "unknown"
      infer_provider(wf)
    end)
    |> Enum.map(fn {provider, file_metas} ->
      traces = Enum.map(file_metas, & &1.trace)
      total = length(traces)
      completed = Enum.count(traces, &(&1.status == "completed"))

      durations =
        traces
        |> Enum.map(& &1.duration_ms)
        |> Enum.filter(&is_integer/1)

      %{
        provider: provider,
        trace_count: total,
        completed: completed,
        success_rate_pct: if(total > 0, do: Float.round(completed / total * 100, 1), else: 0.0),
        avg_duration_ms:
          if(length(durations) > 0,
            do: Enum.sum(durations) |> div(length(durations)),
            else: nil
          ),
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

  defp discover_workflows(root) do
    # Scan common workflow locations
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
            name: file |> Path.rootname() |> String.replace(~r/[-_]/, " ")
          }
        end)

      {:error, _} ->
        []
    end
  end

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
end
