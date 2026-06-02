defmodule Apm.Plugins.Pm.PmPlugin do
  @moduledoc """
  Platform-agnostic PM plugin exposing the `/pm` skill as a unified PM adapter.

  Resolves the active PM adapter via a 4-step chain:

    1. explicit `--pm` flag / `"pm"` param
    2. project CLAUDE.md `## PM` declaration
    3. `pm-config.json` file in the project root
    4. global `active_pm` in `~/.claude/pm-config.json`

  Delegates resolved operations to the appropriate adapter (Plane via the
  existing `Apm.PlaneClient`, Linear/Jira stubs return `:not_implemented`).
  """

  use Apm.Plugins.SkillPluginBridge

  @skill_commands ~w(resolve_adapter list_issues get_issue update_state list_projects board_state)

  @supported_adapters %{
    "plane" => Apm.PlaneClient,
    "linear" => nil,
    "jira" => nil
  }

  # ── SkillPluginBridge ────────────────────────────────────────────────────────

  @impl Apm.Plugins.SkillPluginBridge
  def skill_name, do: "pm"

  @impl Apm.Plugins.SkillPluginBridge
  def skill_path, do: Path.expand("~/.claude/skills/pm/SKILL.md")

  @impl Apm.Plugins.SkillPluginBridge
  def skill_commands, do: @skill_commands

  @impl Apm.Plugins.SkillPluginBridge
  def dispatch_skill_command(command, params),
    do: handle_action(command, params, [])

  # ── PluginBehaviour ──────────────────────────────────────────────────────────

  @impl Apm.Plugins.PluginBehaviour
  def plugin_name, do: "pm"

  @impl Apm.Plugins.PluginBehaviour
  def plugin_description,
    do: "Platform-agnostic PM adapter — Plane / Linear / Jira resolution chain"

  @impl Apm.Plugins.PluginBehaviour
  def plugin_version, do: "1.0.0"

  @impl Apm.Plugins.PluginBehaviour
  def list_endpoints do
    [
      %{action: "resolve_adapter", description: "Resolve active PM adapter for a project", params: %{project_root: "string (optional)", pm: "string (optional override)"}},
      %{action: "list_issues",     description: "List issues via the resolved adapter",     params: %{project_id: "string (optional)"}},
      %{action: "get_issue",       description: "Get a single issue via resolved adapter",  params: %{issue_id: "string (required)"}},
      %{action: "update_state",    description: "Update issue state",                       params: %{issue_id: "string (required)", state: "string (required)"}},
      %{action: "list_projects",   description: "List PM projects via resolved adapter",    params: %{}},
      %{action: "board_state",     description: "Kanban board via resolved adapter",        params: %{project_id: "string (optional)"}}
    ]
  end

  @impl Apm.Plugins.PluginBehaviour
  def nav_items do
    base = "/plugins/pm"
    [
      {"Board",           "#{base}/board",    "hero-view-columns"},
      {"Resolver Status", "#{base}/resolver", "hero-arrows-right-left"},
      {"Config",          "#{base}/config",   "hero-cog-6-tooth"}
    ]
  end

  @impl Apm.Plugins.PluginBehaviour
  def plugin_live_module, do: nil

  @impl Apm.Plugins.PluginBehaviour
  def handle_action("resolve_adapter", params, _opts) do
    case resolve_adapter(params) do
      {:ok, adapter_name, adapter_module, source} ->
        {:ok, %{adapter: adapter_name, module: inspect(adapter_module), source: source}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def handle_action("list_issues", params, _opts) do
    with_adapter(params, fn
      "plane", _mod -> Apm.Plugins.Plane.PlanePlugin.handle_action("list_issues", params, [])
      other, _ -> {:error, {:not_implemented, other}}
    end)
  end

  def handle_action("get_issue", %{"issue_id" => _} = params, _opts) do
    with_adapter(params, fn
      "plane", _mod -> Apm.Plugins.Plane.PlanePlugin.handle_action("get_issue", params, [])
      other, _ -> {:error, {:not_implemented, other}}
    end)
  end

  def handle_action("get_issue", _params, _opts),
    do: {:error, {:missing_param, "issue_id is required"}}

  def handle_action("update_state", %{"issue_id" => _, "state" => _} = params, _opts) do
    with_adapter(params, fn adapter, _mod ->
      {:error, {:not_implemented, "update_state not yet implemented for #{adapter}"}}
    end)
  end

  def handle_action("update_state", _params, _opts),
    do: {:error, {:missing_param, "issue_id and state are required"}}

  def handle_action("list_projects", params, _opts) do
    with_adapter(params, fn
      "plane", _mod -> Apm.Plugins.Plane.PlanePlugin.handle_action("list_projects", params, [])
      other, _ -> {:error, {:not_implemented, other}}
    end)
  end

  def handle_action("board_state", params, _opts) do
    with_adapter(params, fn
      "plane", _mod -> Apm.Plugins.Plane.PlanePlugin.handle_action("board_state", params, [])
      other, _ -> {:error, {:not_implemented, other}}
    end)
  end

  def handle_action(action, _params, _opts),
    do: {:error, {:unknown_action, action}}

  # ── Adapter Resolution (4-step chain) ────────────────────────────────────────

  @doc """
  Resolve the PM adapter using the 4-step chain.
  Returns `{:ok, adapter_name, module, source}` or `{:error, reason}`.
  """
  @spec resolve_adapter(map()) :: {:ok, String.t(), module(), atom()} | {:error, term()}
  def resolve_adapter(params \\ %{}) do
    project_root = Map.get(params, "project_root", File.cwd!())

    cond do
      # Step 1: explicit --pm / "pm" param
      adapter = Map.get(params, "pm") ->
        materialize(adapter, :explicit_param)

      # Step 2: project CLAUDE.md declaration
      adapter = read_claude_md_pm(project_root) ->
        materialize(adapter, :project_claude_md)

      # Step 3: pm-config.json in project root
      adapter = read_project_pm_config(project_root) ->
        materialize(adapter, :project_pm_config)

      # Step 4: global ~/.claude/pm-config.json active_pm
      adapter = read_global_active_pm() ->
        materialize(adapter, :global_active_pm)

      true ->
        # Sensible default: plane
        materialize("plane", :default)
    end
  end

  defp materialize(adapter, source) when is_binary(adapter) do
    adapter_key = String.downcase(adapter)

    case Map.fetch(@supported_adapters, adapter_key) do
      {:ok, module} -> {:ok, adapter_key, module, source}
      :error -> {:error, {:unsupported_adapter, adapter_key}}
    end
  end

  defp with_adapter(params, fun) do
    case resolve_adapter(params) do
      {:ok, adapter, module, _source} -> fun.(adapter, module)
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_claude_md_pm(project_root) do
    path = Path.join(project_root, "CLAUDE.md")

    with true <- File.exists?(path),
         {:ok, body} <- File.read(path),
         [_, adapter | _] <- Regex.run(~r/##\s*PM\s*\n[^\n]*?(plane|linear|jira)/is, body) do
      String.downcase(adapter)
    else
      _ -> nil
    end
  end

  defp read_project_pm_config(project_root) do
    path = Path.join(project_root, "pm-config.json")

    with true <- File.exists?(path),
         {:ok, body} <- File.read(path),
         {:ok, %{"active_pm" => pm}} <- Jason.decode(body) do
      pm
    else
      _ -> nil
    end
  end

  defp read_global_active_pm do
    path = Path.expand("~/.claude/pm-config.json")

    with true <- File.exists?(path),
         {:ok, body} <- File.read(path),
         {:ok, %{"active_pm" => pm}} <- Jason.decode(body) do
      pm
    else
      _ -> nil
    end
  end
end
