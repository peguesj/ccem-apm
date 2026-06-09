defmodule Apm.Plugins.Security.SecurityGuidancePlugin do
  @moduledoc """
  APM Plugin adapter for the `security-guidance` Claude Code plugin.

  This is a first-class CCEM security plugin that surfaces metadata about the
  security-guidance hook (coverage, pattern counts, last-triggered stats) in the
  APM dashboard and provides an action-based API for querying hook health.

  ## Scope
  This plugin uses `plugin_scope/0 -> :security`, which registers it in the
  `:security` category of the APM plugin registry.

  ## Actions
  - `hook_status`       — Returns hook installation state, covered tool types, and pattern counts
  - `scan_history`      — Reads recent entries from the security hook debug log
  - `covered_tools`     — Lists all native Claude Code tool types covered by the hook
  - `pattern_summary`   — Returns a breakdown of pattern categories and counts per tool type

  ## Hook coverage (as of v1.1.0)
  | Tool type    | Coverage   | Severity levels        |
  |--------------|------------|------------------------|
  | Edit         | patterns   | block                  |
  | Write        | patterns   | block                  |
  | MultiEdit    | patterns   | block                  |
  | Bash         | patterns   | critical-block/advisory|
  | WebFetch     | SSRF rules | block/advisory         |
  | WebSearch    | SSRF rules | advisory               |
  | Agent        | injection  | advisory               |
  | Skill        | injection  | advisory               |
  """

  @behaviour Apm.Plugins.PluginBehaviour

  require Logger

  @plugin_version "1.1.0"

  @hook_install_paths [
    "~/.claude/plugins/cache/claude-code-plugins/security-guidance/1.0.0/hooks",
    "~/.claude/plugins/cache/claude-plugins-official/security-guidance/1.0.0/hooks",
    "~/.claude/plugins/cache/claude-plugins-official/security-guidance/104d39be10b7/hooks",
    "~/.claude/plugins/cache/claude-plugins-official/security-guidance/unknown/hooks"
  ]

  @covered_tools [
    %{
      tool: "Edit",
      coverage: :patterns,
      severity: [:block],
      description: "File path and content pattern scanning"
    },
    %{
      tool: "Write",
      coverage: :patterns,
      severity: [:block],
      description: "File path and content pattern scanning"
    },
    %{
      tool: "MultiEdit",
      coverage: :patterns,
      severity: [:block],
      description: "Multi-edit new_string content scanning"
    },
    %{
      tool: "Bash",
      coverage: :command_patterns,
      severity: [:block, :advisory],
      description: "Shell command injection, eval, curl-pipe-shell, rm -rf / detection"
    },
    %{
      tool: "WebFetch",
      coverage: :ssrf_rules,
      severity: [:block, :advisory],
      description: "SSRF target detection: IMDS, private ranges, dangerous URL schemes"
    },
    %{
      tool: "WebSearch",
      coverage: :ssrf_rules,
      severity: [:advisory],
      description: "URL-like query SSRF pattern detection"
    },
    %{
      tool: "Agent",
      coverage: :prompt_injection,
      severity: [:advisory],
      description: "Prompt injection pattern detection in agent prompt field"
    },
    %{
      tool: "Skill",
      coverage: :prompt_injection,
      severity: [:advisory],
      description: "Prompt injection pattern detection in skill args field"
    }
  ]

  @pattern_summary %{
    "edit_write_multiEdit" => %{
      category: "File content security patterns",
      count: 9,
      examples: ["github_actions_workflow", "eval_injection", "child_process_exec"]
    },
    "bash_critical" => %{
      category: "Bash critical-block patterns",
      count: 8,
      examples: ["curl-pipe-shell", "eval-subshell", "rm-rf-root", "base64-decode-pipe-exec"]
    },
    "bash_advisory" => %{
      category: "Bash advisory patterns",
      count: 8,
      examples: ["sudo-usage", "python-c-exec", "write-to-etc"]
    },
    "ssrf_block" => %{
      category: "SSRF block patterns (WebFetch/WebSearch)",
      count: 7,
      examples: ["aws-imds", "gcp-metadata", "file-scheme", "gopher-scheme"]
    },
    "ssrf_advisory" => %{
      category: "SSRF advisory patterns (WebFetch/WebSearch)",
      count: 5,
      examples: ["localhost", "rfc1918-10", "rfc1918-172", "rfc1918-192"]
    },
    "prompt_injection" => %{
      category: "Prompt injection patterns (Agent/Skill)",
      count: 9,
      examples: ["ignore previous instructions", "jailbreak", "DAN mode", "Unicode overrides"]
    }
  }

  @debug_log_path "/tmp/security-warnings-log.txt"

  # ---------------------------------------------------------------------------
  # PluginBehaviour callbacks
  # ---------------------------------------------------------------------------

  @impl true
  @spec plugin_name() :: String.t()
  def plugin_name, do: "security_guidance"

  @impl true
  @spec plugin_description() :: String.t()
  def plugin_description,
    do:
      "Security guidance hook — surfaces coverage metadata and scan history for the security-guidance Claude Code plugin"

  @impl true
  @spec plugin_version() :: String.t()
  def plugin_version, do: @plugin_version

  @impl true
  @spec plugin_scope() :: :security
  def plugin_scope, do: :security

  @impl true
  @spec list_endpoints() :: [map()]
  def list_endpoints do
    [
      %{
        action: "hook_status",
        description: "Returns hook installation state, covered tool types, and pattern counts",
        params: %{}
      },
      %{
        action: "scan_history",
        description: "Reads recent entries from the security hook debug log",
        params: %{lines: "integer (optional, default 50)"}
      },
      %{
        action: "covered_tools",
        description: "Lists all native Claude Code tool types covered by the security hook",
        params: %{}
      },
      %{
        action: "pattern_summary",
        description: "Returns a breakdown of pattern categories and counts per tool type",
        params: %{}
      }
    ]
  end

  @impl true
  @spec handle_action(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def handle_action("hook_status", _params, _opts) do
    installed_paths =
      @hook_install_paths
      |> Enum.map(fn raw_path ->
        path = Path.expand(raw_path)
        hook_file = Path.join(path, "security_reminder_hook.py")
        hooks_json = Path.join(path, "hooks.json")

        %{
          path: path,
          hook_script_exists: File.exists?(hook_file),
          hooks_json_exists: File.exists?(hooks_json),
          matcher: read_matcher(hooks_json)
        }
      end)

    active_count = Enum.count(installed_paths, & &1.hook_script_exists)

    {:ok,
     %{
       plugin_version: @plugin_version,
       installed_copies: length(installed_paths),
       active_copies: active_count,
       covered_tool_count: length(@covered_tools),
       install_paths: installed_paths,
       debug_log_exists: File.exists?(@debug_log_path),
       debug_log_path: @debug_log_path
     }}
  end

  def handle_action("scan_history", params, _opts) do
    lines_requested = Map.get(params, "lines", 50)
    lines_requested = if is_integer(lines_requested), do: lines_requested, else: 50

    case File.read(@debug_log_path) do
      {:ok, content} ->
        lines =
          content
          |> String.split("\n", trim: true)
          |> Enum.take(-lines_requested)

        {:ok,
         %{
           log_path: @debug_log_path,
           total_lines: length(String.split(content, "\n", trim: true)),
           returned_lines: length(lines),
           entries: lines
         }}

      {:error, :enoent} ->
        {:ok, %{log_path: @debug_log_path, total_lines: 0, returned_lines: 0, entries: []}}

      {:error, reason} ->
        {:error, {:log_read_failed, reason}}
    end
  end

  def handle_action("covered_tools", _params, _opts) do
    {:ok,
     %{
       covered_tools: @covered_tools,
       count: length(@covered_tools),
       uncovered_tools: ["Read", "Glob", "Task"],
       uncovered_rationale:
         "Read/Glob have low direct-execution risk; Task sub-agent constraints are handled at the agent level"
     }}
  end

  def handle_action("pattern_summary", _params, _opts) do
    total_patterns =
      @pattern_summary
      |> Map.values()
      |> Enum.reduce(0, fn %{count: c}, acc -> acc + c end)

    {:ok,
     %{
       categories: @pattern_summary,
       total_pattern_count: total_patterns,
       plugin_version: @plugin_version
     }}
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

  @impl true
  @spec nav_items() :: [{String.t(), String.t(), String.t() | nil}]
  def nav_items do
    [
      {"Status", "/plugins/security_guidance/status", "hero-shield-check"},
      {"Covered Tools", "/plugins/security_guidance/covered_tools", "hero-wrench-screwdriver"},
      {"Scan History", "/plugins/security_guidance/scan_history", "hero-document-text"}
    ]
  end

  @impl true
  @spec settings_path() :: String.t() | nil
  def settings_path, do: nil

  @impl true
  @spec plugin_live_module() :: module() | nil
  def plugin_live_module, do: nil

  @impl true
  @spec plugin_integrations() :: [module()]
  def plugin_integrations, do: []

  @impl true
  @spec dashboard_widgets() :: [map()]
  def dashboard_widgets do
    [
      %{
        id: "security_hook_status",
        name: "Security Hook Status",
        category: :plugin,
        source_module: __MODULE__,
        refresh_interval: 300_000,
        min_width: 3,
        min_height: 2,
        config_schema: %{},
        plugin: "security_guidance",
        version: @plugin_version,
        description: "Shows security hook installation state and pattern coverage counts"
      }
    ]
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  @spec read_matcher(String.t()) :: String.t() | nil
  defp read_matcher(hooks_json_path) do
    with true <- File.exists?(hooks_json_path),
         {:ok, content} <- File.read(hooks_json_path),
         {:ok, parsed} <- Jason.decode(content),
         hooks when is_list(hooks) <- get_in(parsed, ["hooks", "PreToolUse"]),
         [%{"matcher" => matcher} | _] <- hooks do
      matcher
    else
      _ -> nil
    end
  end
end
