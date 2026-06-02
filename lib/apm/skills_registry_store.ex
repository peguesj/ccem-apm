defmodule Apm.SkillsRegistryStore do
  @moduledoc """
  GenServer that scans ~/.claude/skills/ and computes health scores per skill.

  Health score breakdown (0-100):
    - Has YAML frontmatter with `name:` and `description:` fields (30%)
    - Description length > 100 chars and not truncated (25%)
    - Has trigger keywords mentioned in description/content (20%)
    - Has `examples/` subdirectory (15%)
    - Has `template.md` file (10%)

  Results are cached in ETS `:skills_registry` and refreshed every 10 minutes.
  """
  use GenServer
  require Logger

  @skills_dir Path.expand("~/.claude/skills")
  @ets_table :skills_registry
  @refresh_interval :timer.minutes(10)

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc "Returns all skills sorted by health_score descending."
  @spec list_skills() :: [map()]
  def list_skills do
    GenServer.call(__MODULE__, :list_skills)
  end

  @doc "Returns `{:ok, skill_map}` or `{:error, :not_found}`."
  @spec get_skill(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_skill(name) do
    GenServer.call(__MODULE__, {:get_skill, name})
  end

  @doc "Returns `{:ok, integer}` or `{:error, :not_found}`."
  @spec health_score(String.t()) :: {:ok, non_neg_integer()} | {:error, :not_found}
  def health_score(name) do
    GenServer.call(__MODULE__, {:health_score, name})
  end

  @doc "Triggers an asynchronous rescan of all skills."
  @spec refresh_all() :: :ok
  def refresh_all do
    GenServer.cast(__MODULE__, :refresh_all)
  end

  # ---------------------------------------------------------------------------
  # Permissive skill list
  # ---------------------------------------------------------------------------

  @doc "Returns skills that bypass AgentLock authorization."
  @spec list_permissive() :: [String.t()]
  def list_permissive do
    GenServer.call(__MODULE__, :list_permissive)
  end

  @doc "Adds a skill name to the permissive list. Returns `:ok`."
  @spec add_permissive(String.t()) :: :ok
  def add_permissive(name) do
    GenServer.call(__MODULE__, {:add_permissive, name})
  end

  @doc "Removes a skill name from the permissive list. Returns `:ok | {:error, :not_found}`."
  @spec remove_permissive(String.t()) :: :ok | {:error, :not_found}
  def remove_permissive(name) do
    GenServer.call(__MODULE__, {:remove_permissive, name})
  end

  @doc "Returns true if the skill is in the permissive list."
  @spec permissive?(String.t()) :: boolean()
  def permissive?(name) do
    GenServer.call(__MODULE__, {:permissive?, name})
  end

  # ---------------------------------------------------------------------------
  # Repository management
  # ---------------------------------------------------------------------------

  @doc "Returns all registered remote skill repositories."
  @spec list_repositories() :: [map()]
  def list_repositories do
    GenServer.call(__MODULE__, :list_repositories)
  end

  @doc "Adds a repository. Returns `{:ok, repo_map}` with auto-generated id."
  @spec add_repository(map()) :: {:ok, map()}
  def add_repository(attrs) do
    GenServer.call(__MODULE__, {:add_repository, attrs})
  end

  @doc "Removes a repository by id. Returns `:ok | {:error, :not_found}`."
  @spec remove_repository(String.t()) :: :ok | {:error, :not_found}
  def remove_repository(id) do
    GenServer.call(__MODULE__, {:remove_repository, id})
  end

  @doc "Triggers an async sync of a repository. Returns `:ok | {:error, :not_found}`."
  @spec sync_repository(String.t()) :: :ok | {:error, :not_found}
  def sync_repository(id) do
    GenServer.call(__MODULE__, {:sync_repository, id})
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @default_permissive ~w(apm apm-auth ccem ccem-apm)

  @mcp_market_repo %{
    id: "mcp-market",
    name: "MCP Market",
    url: "https://www.aitmpl.com/skills",
    type: "http",
    added_at: nil,
    last_synced: nil
  }

  @impl true
  def init(_) do
    :ets.new(@ets_table, [:named_table, :public, :set, read_concurrency: true])
    send(self(), :scan)

    initial_repos = %{@mcp_market_repo.id => Map.put(@mcp_market_repo, :added_at, DateTime.utc_now() |> DateTime.to_iso8601())}

    {:ok, %{
      last_scanned: nil,
      permissive: MapSet.new(@default_permissive),
      repositories: initial_repos
    }}
  end

  @impl true
  def handle_info(:scan, state) do
    Task.start(fn -> do_scan() end)
    Process.send_after(self(), :scan, @refresh_interval)
    {:noreply, %{state | last_scanned: DateTime.utc_now()}}
  end

  @impl true
  def handle_call(:list_skills, _from, state) do
    skills =
      @ets_table
      |> :ets.tab2list()
      |> Enum.map(fn {_k, v} -> v end)
      |> Enum.sort_by(& &1.health_score, :desc)

    {:reply, skills, state}
  end

  @impl true
  def handle_call({:get_skill, name}, _from, state) do
    result =
      case :ets.lookup(@ets_table, name) do
        [{_k, v}] -> {:ok, v}
        [] -> {:error, :not_found}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:health_score, name}, _from, state) do
    result =
      case :ets.lookup(@ets_table, name) do
        [{_k, v}] -> {:ok, v.health_score}
        [] -> {:error, :not_found}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call(:list_permissive, _from, state) do
    {:reply, MapSet.to_list(state.permissive), state}
  end

  @impl true
  def handle_call({:add_permissive, name}, _from, state) do
    {:reply, :ok, %{state | permissive: MapSet.put(state.permissive, name)}}
  end

  @impl true
  def handle_call({:remove_permissive, name}, _from, state) do
    if MapSet.member?(state.permissive, name) do
      {:reply, :ok, %{state | permissive: MapSet.delete(state.permissive, name)}}
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:permissive?, name}, _from, state) do
    {:reply, MapSet.member?(state.permissive, name), state}
  end

  @impl true
  def handle_call(:list_repositories, _from, state) do
    {:reply, Map.values(state.repositories), state}
  end

  @impl true
  def handle_call({:add_repository, attrs}, _from, state) do
    id = attrs[:id] || attrs["id"] || "repo-#{System.unique_integer([:positive])}"
    repo = Map.merge(%{id: id, added_at: DateTime.utc_now() |> DateTime.to_iso8601(), last_synced: nil}, attrs)
    {:reply, {:ok, repo}, %{state | repositories: Map.put(state.repositories, id, repo)}}
  end

  @impl true
  def handle_call({:remove_repository, id}, _from, state) do
    if Map.has_key?(state.repositories, id) do
      {:reply, :ok, %{state | repositories: Map.delete(state.repositories, id)}}
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:sync_repository, id}, _from, state) do
    case Map.fetch(state.repositories, id) do
      {:ok, repo} ->
        Task.start(fn -> do_repository_sync(repo) end)
        synced = Map.put(repo, :last_synced, DateTime.utc_now() |> DateTime.to_iso8601())
        {:reply, :ok, %{state | repositories: Map.put(state.repositories, id, synced)}}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_cast(:refresh_all, state) do
    do_scan()
    {:noreply, %{state | last_scanned: DateTime.utc_now()}}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp do_scan do
    Logger.info("[SkillsRegistryStore] Scanning #{@skills_dir}")

    if File.dir?(@skills_dir) do
      @skills_dir
      |> File.ls!()
      |> Enum.filter(fn name -> File.dir?(Path.join(@skills_dir, name)) end)
      |> Enum.each(fn skill_name ->
        skill_data = analyze_skill(skill_name)
        :ets.insert(@ets_table, {skill_name, skill_data})
      end)
    end
  end

  defp analyze_skill(name) do
    skill_dir = Path.join(@skills_dir, name)
    skill_md = Path.join(skill_dir, "SKILL.md")
    content = if File.exists?(skill_md), do: File.read!(skill_md), else: ""

    frontmatter = parse_frontmatter(content)
    has_frontmatter = frontmatter != %{}
    has_name = Map.has_key?(frontmatter, "name")
    has_description_field = Map.has_key?(frontmatter, "description")
    description = frontmatter["description"] || ""
    desc_length = String.length(description)

    desc_quality =
      cond do
        desc_length > 100 -> "good"
        desc_length > 0 -> "truncated"
        true -> "missing"
      end

    trigger_count = count_triggers(description, content)
    has_examples = File.dir?(Path.join(skill_dir, "examples"))
    has_template = File.exists?(Path.join(skill_dir, "template.md"))

    # Content-based section detection inside SKILL.md
    content_lower = String.downcase(content)
    has_templates_section = has_template or String.contains?(content_lower, "## template")
    has_examples_section = has_examples or String.contains?(content_lower, "## example")

    health_score =
      compute_health(
        has_frontmatter and has_name and has_description_field,
        desc_quality,
        trigger_count,
        has_examples,
        has_template
      )

    auth_gate = compute_auth_gate(name, content)

    %{
      name: name,
      description: description,
      health_score: health_score,
      has_frontmatter: has_frontmatter,
      description_quality: desc_quality,
      trigger_count: trigger_count,
      has_examples: has_examples,
      has_template: has_template,
      has_templates_section: has_templates_section,
      has_examples_section: has_examples_section,
      last_modified: last_modified_iso(skill_dir),
      file_count: count_files(skill_dir),
      raw_frontmatter: frontmatter,
      auth_gated: auth_gate.auth_gated,
      auth_missing_tools: auth_gate.auth_missing_tools
    }
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

  defp count_triggers(description, content) do
    combined = String.downcase(description <> "\n" <> content)

    ~w(trigger use\ when invoke keywords when\ to\ use)
    |> Enum.count(fn kw -> String.contains?(combined, kw) end)
  end

  defp count_files(dir) do
    case File.ls(dir) do
      {:ok, files} -> length(files)
      _ -> 0
    end
  end

  defp last_modified_iso(dir) do
    case File.stat(dir, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} ->
        mtime
        |> DateTime.from_unix!()
        |> DateTime.to_iso8601()

      _ ->
        nil
    end
  end

  # Checks whether high-risk tools used by this skill are covered by AgentLock hooks.
  # "auth_gated" = the pre_tool hook exists AND the skill doesn't reference ungated tools.
  @agentlock_hook Path.expand("~/Developer/ccem/apm/hooks/agentlock_pre_tool.sh")
  @gatable_tools ~w(Write Edit Bash MultiEdit NotebookEdit Task)

  defp compute_auth_gate(_name, content) do
    hook_present = File.exists?(@agentlock_hook)

    referenced_tools =
      Enum.filter(@gatable_tools, fn tool ->
        Regex.match?(~r/\b#{tool}\b/, content)
      end)

    missing_tools =
      if hook_present do
        []
      else
        referenced_tools
      end

    %{
      auth_gated: hook_present and referenced_tools != [],
      auth_missing_tools: missing_tools
    }
  end

  defp do_repository_sync(repo) do
    Logger.info("[SkillsRegistryStore] Syncing repository: #{repo.id} (#{repo.url})")
    # HTTP fetch is intentionally deferred — this is a fire-and-forget placeholder.
    # A full sync implementation would fetch a skills manifest from repo.url,
    # write SKILL.md files to @skills_dir/repo.id/, and call do_scan/0.
    :ok
  end

  defp compute_health(has_full_frontmatter, desc_quality, trigger_count, has_examples, has_template) do
    score = 0
    score = if has_full_frontmatter, do: score + 30, else: score

    score =
      case desc_quality do
        "good" -> score + 25
        "truncated" -> score + 10
        _ -> score
      end

    score = score + min(trigger_count * 7, 20)
    score = if has_examples, do: score + 15, else: score
    score = if has_template, do: score + 10, else: score
    min(score, 100)
  end
end
