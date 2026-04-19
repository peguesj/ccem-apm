defmodule ApmV5.Plugins.SkillDrift.SkillDriftPlugin do
  @moduledoc """
  APM Plugin that detects stale references (drift) in SKILL.md files.

  Scans `~/.claude/skills/` for SKILL.md files and checks for:
  - Wrong APM port references (anything other than localhost:3032)
  - Stale version strings not matching the current app version
  - Dead endpoint references (API paths not in the router)
  - Stale hook version headers

  ## Scope
  Uses `plugin_scope/0 -> :apm` (APM-native operations plugin).

  ## Actions
  - `skill_drift_scan`   — Scan all SKILL.md files and return raw findings
  - `skill_drift_report` — Structured report grouped by severity
  - `skill_drift_fix`    — Auto-fix simple drift (port numbers, version strings)
  """

  @behaviour ApmV5.Plugins.PluginBehaviour

  require Logger

  @plugin_version "1.0.0"
  @skills_base_path "~/.claude/skills"
  @correct_port "3032"
  @wrong_port_pattern ~r/localhost:(\d{4})/
  @version_pattern ~r/v(\d+\.\d+\.\d+)/
  @hook_version_pattern ~r/hook_version[:\s]+["']?v?(\d+)/i
  @endpoint_pattern ~r{(?:GET|POST|PUT|PATCH|DELETE)\s+(/api/[^\s\)\"\']+)}

  # ---------------------------------------------------------------------------
  # PluginBehaviour callbacks
  # ---------------------------------------------------------------------------

  @impl true
  @spec plugin_name() :: String.t()
  def plugin_name, do: "skill_drift"

  @impl true
  @spec plugin_description() :: String.t()
  def plugin_description,
    do: "Skill Drift Detector — scans SKILL.md files for stale port, version, endpoint, and hook references"

  @impl true
  @spec plugin_version() :: String.t()
  def plugin_version, do: @plugin_version

  @impl true
  @spec plugin_scope() :: :apm
  def plugin_scope, do: :apm

  @impl true
  @spec list_endpoints() :: [map()]
  def list_endpoints do
    [
      %{
        action: "skill_drift_scan",
        description: "Scan all SKILL.md files for drift patterns",
        params: %{skills_path: "string (optional, default ~/.claude/skills)"}
      },
      %{
        action: "skill_drift_report",
        description: "Structured drift report grouped by severity (critical/warning/info)",
        params: %{skills_path: "string (optional)"}
      },
      %{
        action: "skill_drift_fix",
        description: "Auto-fix simple drift issues (port numbers, version strings)",
        params: %{skills_path: "string (optional)", dry_run: "boolean (optional, default false)"}
      }
    ]
  end

  @impl true
  @spec handle_action(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def handle_action("skill_drift_scan", params, _opts) do
    skills_path = resolve_skills_path(params)
    current_version = current_app_version()
    router_paths = known_router_paths()

    findings =
      skills_path
      |> list_skill_files()
      |> Enum.flat_map(fn file ->
        scan_file(file, current_version, router_paths)
      end)

    scanned_count =
      skills_path
      |> list_skill_files()
      |> length()

    {:ok,
     %{
       scanned_files: scanned_count,
       total_findings: length(findings),
       findings: findings,
       current_version: current_version,
       skills_path: skills_path
     }}
  end

  def handle_action("skill_drift_report", params, _opts) do
    skills_path = resolve_skills_path(params)
    current_version = current_app_version()
    router_paths = known_router_paths()

    findings =
      skills_path
      |> list_skill_files()
      |> Enum.flat_map(fn file ->
        scan_file(file, current_version, router_paths)
      end)

    grouped = group_by_severity(findings)

    scanned_count =
      skills_path
      |> list_skill_files()
      |> length()

    clean_count = scanned_count - length(Enum.uniq_by(findings, & &1.file))

    {:ok,
     %{
       summary: %{
         scanned: scanned_count,
         clean: clean_count,
         critical: length(Map.get(grouped, :critical, [])),
         warning: length(Map.get(grouped, :warning, [])),
         info: length(Map.get(grouped, :info, []))
       },
       findings_by_severity: grouped,
       current_version: current_version
     }}
  end

  def handle_action("skill_drift_fix", params, _opts) do
    skills_path = resolve_skills_path(params)
    dry_run = Map.get(params, "dry_run", false)
    current_version = current_app_version()
    router_paths = known_router_paths()

    files = list_skill_files(skills_path)

    fix_results =
      Enum.flat_map(files, fn file ->
        findings = scan_file(file, current_version, router_paths)
        fixable = Enum.filter(findings, &(&1.fixable))

        if fixable != [] and not dry_run do
          apply_fixes(file, fixable, current_version)
        else
          Enum.map(fixable, fn f ->
            %{file: f.file, drift_type: f.drift_type, fixed: false, dry_run: dry_run}
          end)
        end
      end)

    {:ok,
     %{
       dry_run: dry_run,
       fixes_applied: Enum.count(fix_results, & &1.fixed),
       fixes_available: length(fix_results),
       details: fix_results
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
      {"Drift Scan", "/skill-drift", "hero-magnifying-glass"},
      {"Drift Report", "/skill-drift/report", "hero-document-chart-bar"}
    ]
  end

  @impl true
  @spec settings_path() :: String.t() | nil
  def settings_path, do: nil

  @impl true
  @spec plugin_live_module() :: module() | nil
  def plugin_live_module, do: ApmV5Web.SkillDriftLive

  @impl true
  @spec plugin_integrations() :: [module()]
  def plugin_integrations, do: []

  @impl true
  @spec dashboard_widgets() :: [map()]
  def dashboard_widgets do
    [
      %{
        id: "skill_drift_summary",
        name: "Skill Drift",
        category: :plugin,
        source_module: __MODULE__,
        refresh_interval: 300_000,
        min_width: 3,
        min_height: 2,
        config_schema: %{},
        default_config: %{},
        plugin: "skill_drift",
        version: @plugin_version,
        description: "Shows skill drift summary — clean, warning, and critical counts",
        editable: false,
        pinnable: false,
        supported_scopes: ["global"],
        display_order: 14
      }
    ]
  end

  # ---------------------------------------------------------------------------
  # Public helpers (used by LiveView and controller)
  # ---------------------------------------------------------------------------

  @doc "Run a scan and return findings. Convenience for LiveView/controller use."
  @spec run_scan(String.t() | nil) :: map()
  def run_scan(skills_path \\ nil) do
    params = if skills_path, do: %{"skills_path" => skills_path}, else: %{}
    {:ok, result} = handle_action("skill_drift_scan", params, [])
    result
  end

  @doc "Run a report and return grouped findings."
  @spec run_report(String.t() | nil) :: map()
  def run_report(skills_path \\ nil) do
    params = if skills_path, do: %{"skills_path" => skills_path}, else: %{}
    {:ok, result} = handle_action("skill_drift_report", params, [])
    result
  end

  @doc "Returns the current app version string."
  @spec current_app_version() :: String.t()
  def current_app_version do
    case Application.spec(:apm_v5, :vsn) do
      nil -> "0.0.0"
      vsn when is_list(vsn) -> to_string(vsn)
      vsn -> to_string(vsn)
    end
  end

  @doc "List all known router paths from the application."
  @spec known_router_paths() :: [String.t()]
  def known_router_paths do
    try do
      ApmV5Web.Router.__routes__()
      |> Enum.map(& &1.path)
      |> Enum.uniq()
    rescue
      _ -> []
    end
  end

  # ---------------------------------------------------------------------------
  # Private — scanning
  # ---------------------------------------------------------------------------

  @spec resolve_skills_path(map()) :: String.t()
  defp resolve_skills_path(params) do
    params
    |> Map.get("skills_path", @skills_base_path)
    |> Path.expand()
  end

  @spec list_skill_files(String.t()) :: [String.t()]
  defp list_skill_files(base_path) do
    pattern = Path.join([base_path, "**", "SKILL.md"])

    pattern
    |> Path.wildcard()
    |> Enum.sort()
  end

  @spec scan_file(String.t(), String.t(), [String.t()]) :: [map()]
  defp scan_file(file, current_version, router_paths) do
    case File.read(file) do
      {:ok, content} ->
        skill_name = extract_skill_name(file)

        port_findings = check_ports(file, skill_name, content)
        version_findings = check_versions(file, skill_name, content, current_version)
        endpoint_findings = check_endpoints(file, skill_name, content, router_paths)
        hook_findings = check_hook_versions(file, skill_name, content)

        port_findings ++ version_findings ++ endpoint_findings ++ hook_findings

      {:error, reason} ->
        Logger.warning("[SkillDrift] Cannot read #{file}: #{inspect(reason)}")
        []
    end
  end

  @spec extract_skill_name(String.t()) :: String.t()
  defp extract_skill_name(file) do
    file
    |> Path.dirname()
    |> Path.basename()
  end

  @spec check_ports(String.t(), String.t(), String.t()) :: [map()]
  defp check_ports(file, skill_name, content) do
    @wrong_port_pattern
    |> Regex.scan(content, return: :index)
    |> Enum.flat_map(fn [{start, len}, {port_start, port_len}] ->
      port = String.slice(content, port_start, port_len)

      if port != @correct_port and is_apm_port_reference?(content, start, len) do
        line_num = line_number_at(content, start)

        [
          %{
            file: file,
            skill_name: skill_name,
            drift_type: :wrong_port,
            severity: :critical,
            line: line_num,
            found: "localhost:#{port}",
            expected: "localhost:#{@correct_port}",
            fixable: true,
            message: "APM port reference should be #{@correct_port}, found #{port}"
          }
        ]
      else
        []
      end
    end)
  end

  @spec is_apm_port_reference?(String.t(), non_neg_integer(), non_neg_integer()) :: boolean()
  defp is_apm_port_reference?(content, start, _len) do
    # Check surrounding context for APM-related terms
    context_start = max(0, start - 100)
    context = String.slice(content, context_start, 200)
    context_lower = String.downcase(context)

    String.contains?(context_lower, "apm") or
      String.contains?(context_lower, "api/") or
      String.contains?(context_lower, "localhost:")
  end

  @spec check_versions(String.t(), String.t(), String.t(), String.t()) :: [map()]
  defp check_versions(file, skill_name, content, current_version) do
    @version_pattern
    |> Regex.scan(content, return: :index)
    |> Enum.flat_map(fn [{start, len}, {ver_start, ver_len}] ->
      found_version = String.slice(content, ver_start, ver_len)

      if found_version != current_version and looks_like_apm_version?(content, start, len) do
        line_num = line_number_at(content, start)

        [
          %{
            file: file,
            skill_name: skill_name,
            drift_type: :stale_version,
            severity: :warning,
            line: line_num,
            found: "v#{found_version}",
            expected: "v#{current_version}",
            fixable: true,
            message: "Version reference v#{found_version} does not match current v#{current_version}"
          }
        ]
      else
        []
      end
    end)
  end

  @spec looks_like_apm_version?(String.t(), non_neg_integer(), non_neg_integer()) :: boolean()
  defp looks_like_apm_version?(content, start, _len) do
    context_start = max(0, start - 80)
    context = String.slice(content, context_start, 160)
    context_lower = String.downcase(context)

    String.contains?(context_lower, "apm") or
      String.contains?(context_lower, "ccem") or
      String.contains?(context_lower, "version") or
      String.contains?(context_lower, "hook")
  end

  @spec check_endpoints(String.t(), String.t(), String.t(), [String.t()]) :: [map()]
  defp check_endpoints(file, skill_name, content, router_paths) do
    @endpoint_pattern
    |> Regex.scan(content)
    |> Enum.flat_map(fn [_full, api_path] ->
      # Normalize: strip trailing punctuation and params
      normalized = normalize_api_path(api_path)

      if router_paths != [] and not path_exists_in_router?(normalized, router_paths) do
        line_num = find_line_containing(content, api_path)

        [
          %{
            file: file,
            skill_name: skill_name,
            drift_type: :dead_endpoint,
            severity: :warning,
            line: line_num,
            found: api_path,
            expected: "valid router path",
            fixable: false,
            message: "Endpoint #{api_path} not found in router"
          }
        ]
      else
        []
      end
    end)
  end

  @spec check_hook_versions(String.t(), String.t(), String.t()) :: [map()]
  defp check_hook_versions(file, skill_name, content) do
    @hook_version_pattern
    |> Regex.scan(content, return: :index)
    |> Enum.flat_map(fn [{start, _len}, {ver_start, ver_len}] ->
      found_hook_ver = String.slice(content, ver_start, ver_len)
      current_hook_ver = "9"

      if found_hook_ver != current_hook_ver do
        line_num = line_number_at(content, start)

        [
          %{
            file: file,
            skill_name: skill_name,
            drift_type: :stale_hook_version,
            severity: :info,
            line: line_num,
            found: "v#{found_hook_ver}",
            expected: "v#{current_hook_ver}",
            fixable: false,
            message: "Hook version v#{found_hook_ver} does not match current v#{current_hook_ver}"
          }
        ]
      else
        []
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Private — fixing
  # ---------------------------------------------------------------------------

  @spec apply_fixes(String.t(), [map()], String.t()) :: [map()]
  defp apply_fixes(file, fixable_findings, current_version) do
    case File.read(file) do
      {:ok, content} ->
        {new_content, applied} =
          Enum.reduce(fixable_findings, {content, []}, fn finding, {acc_content, acc_applied} ->
            case finding.drift_type do
              :wrong_port ->
                fixed =
                  String.replace(acc_content, "localhost:#{extract_port(finding.found)}", "localhost:#{@correct_port}")

                {fixed,
                 [%{file: file, drift_type: :wrong_port, fixed: true, dry_run: false} | acc_applied]}

              :stale_version ->
                old_ver = extract_version(finding.found)
                fixed = String.replace(acc_content, "v#{old_ver}", "v#{current_version}")

                {fixed,
                 [%{file: file, drift_type: :stale_version, fixed: true, dry_run: false} | acc_applied]}

              _ ->
                {acc_content, acc_applied}
            end
          end)

        if new_content != content do
          File.write!(file, new_content)
        end

        applied

      {:error, _reason} ->
        Enum.map(fixable_findings, fn f ->
          %{file: f.file, drift_type: f.drift_type, fixed: false, dry_run: false}
        end)
    end
  end

  # ---------------------------------------------------------------------------
  # Private — utilities
  # ---------------------------------------------------------------------------

  @spec line_number_at(String.t(), non_neg_integer()) :: pos_integer()
  defp line_number_at(content, byte_offset) do
    content
    |> String.slice(0, byte_offset)
    |> String.split("\n")
    |> length()
  end

  @spec find_line_containing(String.t(), String.t()) :: pos_integer()
  defp find_line_containing(content, needle) do
    content
    |> String.split("\n")
    |> Enum.find_index(&String.contains?(&1, needle))
    |> case do
      nil -> 0
      idx -> idx + 1
    end
  end

  @spec normalize_api_path(String.t()) :: String.t()
  defp normalize_api_path(path) do
    path
    |> String.replace(~r/[,\.\)\]\}\>]$/, "")
    |> String.replace(~r/:[\w]+/, ":id")
  end

  @spec path_exists_in_router?(String.t(), [String.t()]) :: boolean()
  defp path_exists_in_router?(normalized_path, router_paths) do
    Enum.any?(router_paths, fn rp ->
      normalized_rp = String.replace(rp, ~r/:[\w]+/, ":id")
      normalized_rp == normalized_path
    end)
  end

  @spec group_by_severity([map()]) :: %{critical: [map()], warning: [map()], info: [map()]}
  defp group_by_severity(findings) do
    findings
    |> Enum.group_by(& &1.severity)
    |> Map.put_new(:critical, [])
    |> Map.put_new(:warning, [])
    |> Map.put_new(:info, [])
  end

  @spec extract_port(String.t()) :: String.t()
  defp extract_port("localhost:" <> port), do: port
  defp extract_port(other), do: other

  @spec extract_version(String.t()) :: String.t()
  defp extract_version("v" <> ver), do: ver
  defp extract_version(ver), do: ver
end
