defmodule Apm.Plugins.SkillPluginBridge do
  @moduledoc """
  Extension of `Apm.Plugins.PluginBehaviour` that adds skill-specific conventions
  for plugins that wrap a `~/.claude/skills/<skill>/SKILL.md` workflow.

  A skill-plugin is a thin Elixir adapter that exposes a Claude skill as a
  first-class APM plugin: nav items, actions, LiveView, and dashboard widgets,
  while delegating the workflow logic to the underlying skill (via shell-out,
  HTTP, or in-process handlers).

  ## Usage

      defmodule MyPlugin do
        use Apm.Plugins.SkillPluginBridge

        @impl true
        def skill_name, do: "my-skill"

        @impl true
        def skill_path, do: Path.expand("~/.claude/skills/my-skill/SKILL.md")

        @impl true
        def skill_commands, do: ["plan", "build", "verify"]

        # PluginBehaviour callbacks
        @impl true
        def plugin_name, do: "my_skill"
        @impl true
        def plugin_description, do: "My skill plugin"
        @impl true
        def plugin_version, do: "1.0.0"
        @impl true
        def list_endpoints, do: []
        @impl true
        def handle_action(_action, _params, _opts), do: {:error, :not_implemented}
      end

  The `use` macro auto-implements:
    * `plugin_scope/0` -> `:ccem`
    * `nav_items/0` -> one entry per `skill_commands/0` entry (default nav)
    * `default_enabled?/0` -> `true`

  These defaults can be overridden by the implementing module.
  """

  @typedoc "Subcommand name exposed by the underlying skill."
  @type skill_command :: String.t()

  @doc "The canonical skill name as it appears in `~/.claude/skills/<skill_name>/`."
  @callback skill_name() :: String.t()

  @doc "Absolute path to the skill's `SKILL.md` frontmatter file."
  @callback skill_path() :: String.t()

  @doc """
  Returns the list of subcommand names this skill exposes.
  Each entry typically maps 1:1 onto an APM action returned by `list_endpoints/0`.
  """
  @callback skill_commands() :: [skill_command()]

  @doc """
  Dispatches a skill subcommand with the given params.
  Convention: delegates to the underlying skill logic (in-process, shell-out,
  or HTTP to a companion service).

  Returns `{:ok, result_map}` on success or `{:error, reason}` on failure.
  """
  @callback dispatch_skill_command(command :: skill_command(), params :: map()) ::
              {:ok, map()} | {:error, term()}

  @optional_callbacks [dispatch_skill_command: 2]

  @doc """
  Fire-and-forget helper for dispatching a skill command without blocking the caller.
  Always returns `:ok`. The dispatched task is supervised under `Task.Supervisor`
  when available, otherwise under `Task.start/1`.
  """
  @spec dispatch_async(module(), skill_command(), map()) :: :ok
  def dispatch_async(plugin_module, command, params)
      when is_atom(plugin_module) and is_binary(command) and is_map(params) do
    Task.start(fn ->
      try do
        apply(plugin_module, :dispatch_skill_command, [command, params])
      rescue
        e -> require Logger; Logger.warning("[SkillPluginBridge] dispatch_async failed: #{inspect(e)}")
      end
    end)

    :ok
  end

  @doc """
  Synchronous helper wrapper around `c:dispatch_skill_command/2` with a default
  `{:error, :not_implemented}` fallback when the callback is not exported.
  """
  @spec dispatch_skill_command(module(), skill_command(), map()) ::
          {:ok, map()} | {:error, term()}
  def dispatch_skill_command(plugin_module, command, params)
      when is_atom(plugin_module) and is_binary(command) and is_map(params) do
    if function_exported?(plugin_module, :dispatch_skill_command, 2) do
      apply(plugin_module, :dispatch_skill_command, [command, params])
    else
      {:error, :not_implemented}
    end
  end

  @doc """
  The `use Apm.Plugins.SkillPluginBridge` macro wires up:
    * `@behaviour Apm.Plugins.PluginBehaviour`
    * `@behaviour Apm.Plugins.SkillPluginBridge`
    * default `plugin_scope/0` -> `:ccem`
    * default `nav_items/0` generated from `skill_commands/0`
    * default `default_enabled?/0` -> `true`
  """
  defmacro __using__(_opts) do
    quote do
      @behaviour Apm.Plugins.PluginBehaviour
      @behaviour Apm.Plugins.SkillPluginBridge

      @impl Apm.Plugins.PluginBehaviour
      def plugin_scope, do: :ccem

      @impl Apm.Plugins.PluginBehaviour
      def default_enabled?, do: true

      @impl Apm.Plugins.PluginBehaviour
      def nav_items do
        base = "/plugins/#{plugin_name()}"

        skill_commands()
        |> Enum.map(fn cmd ->
          label = cmd |> to_string() |> String.replace("_", " ") |> titlecase()
          {label, "#{base}/#{cmd}", nil}
        end)
      end

      defp titlecase(str) do
        str
        |> String.split(~r/[\s\-_]+/)
        |> Enum.map(&String.capitalize/1)
        |> Enum.join(" ")
      end

      defoverridable plugin_scope: 0, default_enabled?: 0, nav_items: 0
    end
  end
end
