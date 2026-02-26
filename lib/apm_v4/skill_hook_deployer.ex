defmodule ApmV4.SkillHookDeployer do
  @moduledoc """
  GenServer that manages skill hook template deployment.

  On init, loads all `.sh` templates from `priv/hook_templates/` into ETS.
  Templates are named `<skill>_<event>.sh` e.g. `upm_session_start.sh`.

  `deploy_hooks/3` writes selected hook scripts to `<project_root>/.claude/hooks/`
  with correct permissions (chmod 755).
  """

  use GenServer
  require Logger

  @table :skill_hook_templates
  @hook_events ~w(session_start pre_tool_use post_tool_use pre_compact post_compact)

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Deploy hook scripts for a given skill to a project root.

  `hooks` can be `:all` or a list of event names like `["session_start", "pre_tool_use"]`.

  Returns `{:ok, %{deployed: [...], skipped: []}}` or `{:error, reason}`.
  """
  @spec deploy_hooks(String.t(), String.t(), :all | [String.t()]) :: {:ok, map()} | {:error, String.t()}
  def deploy_hooks(project_root, skill, hooks \\ :all) do
    GenServer.call(__MODULE__, {:deploy, project_root, skill, hooks})
  end

  @doc "Returns a map of skill => [hook_event] listing all available templates."
  @spec list_templates() :: %{String.t() => [String.t()]}
  def list_templates do
    GenServer.call(__MODULE__, :list_templates)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    load_templates()
    Logger.info("[SkillHookDeployer] initialised — #{:ets.info(@table, :size)} templates loaded")
    {:ok, %{}}
  end

  @impl true
  def handle_call({:deploy, project_root, skill, hooks}, _from, s) do
    hooks_dir = Path.join([project_root, ".claude", "hooks"])

    case File.mkdir_p(hooks_dir) do
      :ok ->
        templates = fetch_templates_for_skill(skill, hooks)

        results =
          Enum.reduce(templates, %{deployed: [], skipped: []}, fn {event, content}, acc ->
            dest = Path.join(hooks_dir, "#{skill}_#{event}.sh")

            case File.write(dest, content) do
              :ok ->
                File.chmod(dest, 0o755)
                %{acc | deployed: acc.deployed ++ ["#{skill}_#{event}.sh"]}

              {:error, reason} ->
                Logger.warning("[SkillHookDeployer] failed to write #{dest}: #{reason}")
                %{acc | skipped: acc.skipped ++ ["#{skill}_#{event}.sh"]}
            end
          end)

        {:reply, {:ok, results}, s}

      {:error, reason} ->
        {:reply, {:error, "Cannot create hooks dir #{hooks_dir}: #{reason}"}, s}
    end
  end

  @impl true
  def handle_call(:list_templates, _from, s) do
    grouped =
      :ets.tab2list(@table)
      |> Enum.map(fn {{skill, event}, _content} -> {skill, event} end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    {:reply, grouped, s}
  end

  # --- Private helpers ---

  defp load_templates do
    dir = templates_dir()

    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".sh"))
        |> Enum.each(fn filename ->
          case parse_template_name(filename) do
            {:ok, skill, event} ->
              content = File.read!(Path.join(dir, filename))
              :ets.insert(@table, {{skill, event}, content})

            :error ->
              Logger.debug("[SkillHookDeployer] skipping unrecognised template: #{filename}")
          end
        end)

      {:error, reason} ->
        Logger.warning("[SkillHookDeployer] template dir #{dir} not accessible: #{reason}")
    end
  end

  defp templates_dir do
    priv =
      case :code.priv_dir(:apm_v4) do
        {:error, _} -> Path.join(File.cwd!(), "priv")
        path -> List.to_string(path)
      end

    Path.join(priv, "hook_templates")
  end

  # Filename convention: <skill>_<event>.sh
  # The event suffix is one of @hook_events.
  defp parse_template_name(filename) do
    base = String.replace_suffix(filename, ".sh", "")

    Enum.find_value(@hook_events, :error, fn event ->
      suffix = "_#{event}"

      if String.ends_with?(base, suffix) do
        skill = String.replace_suffix(base, suffix, "")

        if skill != "" do
          {:ok, skill, event}
        end
      end
    end)
  end

  defp fetch_templates_for_skill(skill, :all) do
    :ets.tab2list(@table)
    |> Enum.filter(fn {{s, _event}, _} -> s == skill end)
    |> Enum.map(fn {{_s, event}, content} -> {event, content} end)
  end

  defp fetch_templates_for_skill(skill, events) when is_list(events) do
    Enum.flat_map(events, fn event ->
      case :ets.lookup(@table, {skill, event}) do
        [{{_s, _e}, content}] -> [{event, content}]
        [] -> []
      end
    end)
  end
end
