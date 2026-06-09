defmodule Apm.Plugins.Builder.BuilderEngine do
  @moduledoc """
  GenServer managing Builder wizard sessions.

  Sessions are stored in ETS. Async work (analyze, generate) is triggered via
  `send(self(), ...)` to keep the GenServer responsive. PubSub broadcasts on
  every state change so BuilderLive can update in real time.
  """

  use GenServer
  require Logger

  alias Apm.Plugins.Builder.BuilderSession
  alias Apm.Plugins.Builder.RepositoryAnalyzer

  @table :builder_sessions
  @pubsub_topic "builder:sessions"

  # ── Public API ───────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec start_session() :: {:ok, String.t()}
  def start_session do
    GenServer.call(__MODULE__, :start_session)
  end

  @spec get_session(String.t()) :: {:ok, BuilderSession.t()} | {:error, :not_found}
  def get_session(id) do
    case :ets.lookup(@table, id) do
      [{^id, session}] -> {:ok, session}
      [] -> {:error, :not_found}
    end
  end

  @spec update_session(String.t(), map()) :: {:ok, BuilderSession.t()} | {:error, :not_found}
  def update_session(id, attrs) do
    GenServer.call(__MODULE__, {:update_session, id, attrs})
  end

  @spec analyze_source(String.t()) :: :ok | {:error, :not_found}
  def analyze_source(id) do
    GenServer.call(__MODULE__, {:trigger_async, id, :analyze})
  end

  @spec generate_preview(String.t()) :: :ok | {:error, :not_found}
  def generate_preview(id) do
    GenServer.call(__MODULE__, {:trigger_async, id, :generate})
  end

  @spec write_files(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def write_files(id) do
    GenServer.call(__MODULE__, {:write_files, id}, 30_000)
  end

  # ── GenServer Callbacks ───────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call(:start_session, _from, state) do
    id = generate_id()
    session = BuilderSession.new(id)
    :ets.insert(@table, {id, session})
    {:reply, {:ok, id}, state}
  end

  def handle_call({:update_session, id, attrs}, _from, state) do
    case :ets.lookup(@table, id) do
      [{^id, session}] ->
        updated =
          Enum.reduce(attrs, session, fn {k, v}, acc ->
            key = if is_binary(k), do: String.to_existing_atom(k), else: k
            Map.put(acc, key, v)
          end)

        :ets.insert(@table, {id, updated})
        broadcast(updated)
        {:reply, {:ok, updated}, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:trigger_async, id, action}, _from, state) do
    case :ets.lookup(@table, id) do
      [{^id, _}] ->
        send(self(), {action, id})
        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:write_files, id}, _from, state) do
    result =
      case :ets.lookup(@table, id) do
        [{^id, session}] -> do_write_files(session)
        [] -> {:error, :not_found}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_info({:analyze, id}, state) do
    with [{^id, session}] <- :ets.lookup(@table, id),
         session <- set_status(id, session, :analyzing) do
      Task.start(fn ->
        case RepositoryAnalyzer.analyze(session.source || "") do
          {:ok, analyzed} ->
            GenServer.call(
              __MODULE__,
              {:update_session, id, %{analyzed: analyzed, status: :analyzed}}
            )

          {:error, reason} ->
            Logger.warning("[BuilderEngine] analyze failed for #{id}: #{inspect(reason)}")
            GenServer.call(__MODULE__, {:update_session, id, %{status: :error, error: reason}})
        end
      end)
    end

    {:noreply, state}
  end

  def handle_info({:generate, id}, state) do
    with [{^id, session}] <- :ets.lookup(@table, id),
         session <- set_status(id, session, :generating) do
      Task.start(fn ->
        plugin_code = generate_plugin_code(session)
        skill_md = generate_skill_md(session)

        GenServer.call(__MODULE__, {
          :update_session,
          id,
          %{generated_plugin_code: plugin_code, generated_skill_md: skill_md, status: :preview}
        })
      end)
    end

    {:noreply, state}
  end

  # ── Private ──────────────────────────────────────────────────────────────────

  defp set_status(id, session, status) do
    updated = %{session | status: status}
    :ets.insert(@table, {id, updated})
    broadcast(updated)
    updated
  end

  defp broadcast(session) do
    Phoenix.PubSub.broadcast(Apm.PubSub, @pubsub_topic, {:builder_session_updated, session})
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp slug(session) do
    (session.name || "plugin")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end

  defp generate_plugin_code(session) do
    s = slug(session)
    mod = Macro.camelize(s)
    desc = session.description || session.analyzed[:description_hint] || "#{session.name} plugin"
    lang = session.analyzed[:language] || :unknown

    lang_note = if lang != :unknown, do: " (#{lang} source)", else: ""

    """
    defmodule Apm.Plugins.#{mod}.#{mod}Plugin do
      @moduledoc \"\"\"
      CCEM APM plugin for #{session.name}#{lang_note}.

      #{desc}
      \"\"\"

      @behaviour Apm.Plugins.PluginBehaviour

      @plugin_version "1.0.0"

      @impl true
      def plugin_name, do: "#{s}"

      @impl true
      def plugin_description, do: "#{desc}"

      @impl true
      def plugin_version, do: @plugin_version

      @impl true
      def plugin_scope, do: :ccem

      @impl true
      def list_endpoints do
        [
          %{action: "health", description: "Plugin health check", params: %{}}
        ]
      end

      @impl true
      def handle_action("health", _params, _opts) do
        {:ok, %{status: "ok", plugin: "#{s}", version: @plugin_version}}
      end

      def handle_action(action, _params, _opts) do
        {:error, {:unknown_action, action}}
      end
    end
    """
  end

  defp generate_skill_md(session) do
    s = slug(session)
    name = session.name || s
    desc = session.description || session.analyzed[:description_hint] || "#{name} skill"
    caps = session.capabilities || session.analyzed[:capabilities] || []

    _triggers = [s | Enum.map(caps, &to_string/1)] |> Enum.join(", ")

    """
    ---
    name: #{s}
    description: #{desc}
    version: 1.0.0
    triggers:
      - #{s}
    category: plugin
    tier: experimental
    ---

    # #{name}

    #{desc}

    ## Capabilities

    #{Enum.map(caps, fn c -> "- #{c}" end) |> Enum.join("\n")}

    ## Usage

    ```
    /#{s}
    ```

    ## APM Integration

    This plugin is registered in CCEM APM at `/plugins/#{s}`.
    """
  end

  defp do_write_files(session) do
    s = slug(session)
    _mod = Macro.camelize(s)

    apm_root = Path.expand(".")
    plugin_dir = Path.join([apm_root, "lib", "apm", "plugins", s])
    plugin_path = Path.join(plugin_dir, "#{s}_plugin.ex")

    skill_dir = Path.expand("~/.claude/skills/#{s}")
    skill_path = Path.join(skill_dir, "SKILL.md")

    with :ok <- File.mkdir_p(plugin_dir),
         :ok <- File.write(plugin_path, session.generated_plugin_code || ""),
         :ok <- File.mkdir_p(skill_dir),
         :ok <- File.write(skill_path, session.generated_skill_md || "") do
      {:ok, [plugin_path, skill_path]}
    end
  end
end
