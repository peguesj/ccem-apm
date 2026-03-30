defmodule ApmV5.Plugins.ClaudeCode.ClaudeCodePlugin do
  @moduledoc """
  APM Plugin for Claude Code environment discovery.

  Scans the local Claude Code installation to discover:
  - MCP server configurations from settings.json
  - Hook definitions (PreToolUse, PostToolUse, etc.)
  - Active session metadata
  - Installed skills and commands

  This is a READ-ONLY discovery plugin. No mutations.

  ## Actions

  - `discover_settings`     - Parse ~/.claude/settings.json global config
  - `discover_mcp_servers`  - Extract mcpServers block from settings
  - `discover_hooks`        - Extract hook definitions from settings
  - `session_info`          - Read active session metadata
  - `discover_skills`       - Scan ~/.claude/skills/ directory
  """

  @behaviour ApmV5.Plugins.PluginBehaviour

  require Logger

  @claude_home System.get_env("HOME") |> Path.join(".claude")

  # -- PluginBehaviour callbacks -----------------------------------------------

  @impl true
  @spec plugin_name() :: String.t()
  def plugin_name, do: "claude_code"

  @impl true
  @spec plugin_description() :: String.t()
  def plugin_description,
    do: "Claude Code environment discovery — MCP servers, hooks, skills, sessions"

  @impl true
  @spec plugin_version() :: String.t()
  def plugin_version, do: "1.0.0"

  @impl true
  @spec list_endpoints() :: [map()]
  def list_endpoints do
    [
      %{action: "discover_settings", description: "Parse global settings.json", params: %{}},
      %{action: "discover_mcp_servers", description: "Extract MCP server configs", params: %{}},
      %{action: "discover_hooks", description: "Extract hook definitions", params: %{}},
      %{action: "session_info", description: "Read active session metadata", params: %{}},
      %{action: "discover_skills", description: "Scan installed skills directory", params: %{}}
    ]
  end

  @impl true
  @spec handle_action(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def handle_action("discover_settings", _params, _opts) do
    case read_settings_json() do
      {:ok, settings} ->
        {:ok, %{
          settings: sanitize_settings(settings),
          path: resolve_settings_path(),
          discovered_at: DateTime.utc_now() |> DateTime.to_iso8601()
        }}

      {:error, reason} ->
        {:error, {:settings_read_failed, reason}}
    end
  end

  def handle_action("discover_mcp_servers", _params, _opts) do
    case read_settings_json() do
      {:ok, settings} ->
        servers = Map.get(settings, "mcpServers", %{})

        parsed =
          Enum.map(servers, fn {name, config} ->
            %{
              name: name,
              command: Map.get(config, "command", "unknown"),
              args: Map.get(config, "args", []),
              env_keys: config |> Map.get("env", %{}) |> Map.keys(),
              type: infer_server_type(config)
            }
          end)

        {:ok, %{mcp_servers: parsed, count: length(parsed)}}

      {:error, reason} ->
        {:error, {:settings_read_failed, reason}}
    end
  end

  def handle_action("discover_hooks", _params, _opts) do
    case read_settings_json() do
      {:ok, settings} ->
        hooks = Map.get(settings, "hooks", %{})

        parsed =
          Enum.flat_map(hooks, fn {event_type, hook_list} ->
            hook_list
            |> List.wrap()
            |> Enum.map(fn hook ->
              %{
                event: event_type,
                type: Map.get(hook, "type", "command"),
                command: Map.get(hook, "command", Map.get(hook, "url", "unknown")),
                timeout: Map.get(hook, "timeout", 60_000)
              }
            end)
          end)

        {:ok, %{hooks: parsed, count: length(parsed)}}

      {:error, reason} ->
        {:error, {:settings_read_failed, reason}}
    end
  end

  def handle_action("session_info", _params, _opts) do
    sessions_dir = Path.join([System.get_env("HOME"), "Developer", "ccem", "apm", "sessions"])

    sessions =
      case File.ls(sessions_dir) do
        {:ok, files} ->
          files
          |> Enum.filter(&String.ends_with?(&1, ".json"))
          |> Enum.map(fn file ->
            path = Path.join(sessions_dir, file)

            case File.read(path) do
              {:ok, content} ->
                case Jason.decode(content) do
                  {:ok, data} -> Map.put(data, "file", file)
                  _ -> %{"file" => file, "error" => "parse_failed"}
                end

              _ ->
                %{"file" => file, "error" => "read_failed"}
            end
          end)

        {:error, _} ->
          []
      end

    {:ok, %{sessions: sessions, count: length(sessions)}}
  end

  def handle_action("discover_skills", _params, _opts) do
    skills_dir = Path.join(@claude_home, "skills")

    skills =
      case File.ls(skills_dir) do
        {:ok, entries} ->
          entries
          |> Enum.filter(fn entry ->
            Path.join(skills_dir, entry) |> File.dir?()
          end)
          |> Enum.map(fn dir ->
            skill_file = Path.join([skills_dir, dir, "SKILL.md"])
            has_skill = File.exists?(skill_file)

            %{
              name: dir,
              has_skill_md: has_skill,
              path: Path.join(skills_dir, dir)
            }
          end)

        {:error, _} ->
          []
      end

    {:ok, %{skills: skills, count: length(skills)}}
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
    [{"Discovery", "/plugins/claude-code", "hero-magnifying-glass"}]
  end

  @impl true
  @spec plugin_live_module() :: module() | nil
  def plugin_live_module, do: ApmV5Web.ClaudeCodeDiscoveryLive

  # -- Private helpers ---------------------------------------------------------

  defp resolve_settings_path do
    # Check project-level first, then user-level
    project_settings = Path.join([System.get_env("HOME"), "Developer", "ccem", ".claude", "settings.json"])
    user_settings = Path.join(@claude_home, "settings.json")

    cond do
      File.exists?(project_settings) -> project_settings
      File.exists?(user_settings) -> user_settings
      true -> user_settings
    end
  end

  defp read_settings_json do
    path = resolve_settings_path()

    case File.read(path) do
      {:ok, content} -> Jason.decode(content)
      {:error, reason} -> {:error, reason}
    end
  end

  defp sanitize_settings(settings) do
    # Remove sensitive values (API keys, tokens) from settings before returning
    settings
    |> Map.drop(["apiKey", "apiKeys", "credentials", "tokens"])
    |> Map.update("mcpServers", %{}, fn servers ->
      Map.new(servers, fn {name, config} ->
        sanitized = Map.update(config, "env", %{}, fn env ->
          Map.new(env, fn {k, _v} -> {k, "<redacted>"} end)
        end)
        {name, sanitized}
      end)
    end)
  end

  defp infer_server_type(config) do
    command = Map.get(config, "command", "")

    cond do
      String.contains?(command, "npx") -> "npm"
      String.contains?(command, "python") -> "python"
      String.contains?(command, "docker") -> "docker"
      String.contains?(command, "uvx") -> "uv"
      true -> "binary"
    end
  end
end
