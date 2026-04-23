defmodule ApmV5.Plugins.Worktree.WorktreePlugin do
  @moduledoc """
  APM Plugin for git worktree lifecycle management.

  Bridges the existing `ApmV5.WorktreeStore` GenServer into the plugin
  framework, exposing actions for listing, filtering, health checking,
  and syncing worktrees against `git worktree list --porcelain`.

  ## Actions

  | Action          | Description                                        |
  |-----------------|----------------------------------------------------|
  | `list`          | All tracked worktrees with optional project filter  |
  | `get`           | Single worktree by id                               |
  | `sync`          | Reconcile ETS against live `git worktree list`      |
  | `health_check`  | WorktreeStore process liveness + ETS stats          |
  | `by_formation`  | Worktrees grouped by formation_id                   |
  """

  @behaviour ApmV5.Plugins.PluginBehaviour

  alias ApmV5.WorktreeStore

  require Logger

  @plugin_version "1.0.0"

  @impl true
  @spec plugin_name() :: String.t()
  def plugin_name, do: "worktree"

  @impl true
  @spec plugin_description() :: String.t()
  def plugin_description,
    do: "Git worktree lifecycle — tracking, sync, formation linking, and bidirectional management"

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
        action: "list",
        description: "List tracked worktrees with optional project filter",
        params: %{project: "string (optional)"}
      },
      %{
        action: "get",
        description: "Get single worktree by id",
        params: %{id: "string (required)"}
      },
      %{
        action: "sync",
        description: "Reconcile ETS against live git worktree list; registers missing, prunes ghosts",
        params: %{project_root: "string (optional, defaults to cwd)"}
      },
      %{
        action: "health_check",
        description: "WorktreeStore process liveness and ETS table stats",
        params: %{}
      },
      %{
        action: "by_formation",
        description: "Worktrees grouped by formation_id",
        params: %{}
      }
    ]
  end

  @impl true
  @spec handle_action(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}

  def handle_action("list", params, _opts) do
    project = Map.get(params, "project") || Map.get(params, :project)

    worktrees =
      if is_binary(project),
        do: WorktreeStore.list_by_project(project),
        else: WorktreeStore.list()

    {:ok, %{worktrees: worktrees, count: length(worktrees)}}
  end

  def handle_action("get", params, _opts) do
    id = Map.get(params, "id") || Map.get(params, :id)

    if is_binary(id) do
      case WorktreeStore.get(id) do
        {:ok, wt} -> {:ok, %{worktree: wt}}
        {:error, :not_found} -> {:error, {:not_found, id}}
      end
    else
      {:error, {:invalid_params, "id must be a string"}}
    end
  end

  def handle_action("sync", params, _opts) do
    project_root = Map.get(params, "project_root") || Map.get(params, :project_root)
    root = if is_binary(project_root), do: project_root, else: File.cwd!()

    case sync_git_worktrees(root) do
      {:ok, summary} -> {:ok, summary}
      {:error, reason} -> {:error, reason}
    end
  end

  def handle_action("health_check", _params, _opts) do
    alive = Process.whereis(WorktreeStore) != nil

    ets_info =
      if :ets.whereis(:worktree_store) != :undefined do
        %{size: :ets.info(:worktree_store, :size), memory: :ets.info(:worktree_store, :memory)}
      else
        %{size: 0, memory: 0}
      end

    {:ok, %{alive: alive, ets: ets_info}}
  end

  def handle_action("by_formation", _params, _opts) do
    grouped =
      WorktreeStore.list()
      |> Enum.group_by(fn wt -> Map.get(wt, :formation_id) || "unlinked" end)

    {:ok, %{formations: grouped, formation_count: map_size(grouped)}}
  end

  def handle_action(action, _params, _opts) do
    {:error, {:unknown_action, action}}
  end

  # ── Optional callbacks ───────────────────────────────────────────────────────

  @impl true
  @spec supervisor_children() :: [Supervisor.child_spec()]
  def supervisor_children, do: []

  @impl true
  @spec nav_items() :: [{String.t(), String.t(), String.t() | nil}]
  def nav_items do
    [{"Worktrees", "/plugins/worktree", "hero-squares-2x2"}]
  end

  @impl true
  @spec dashboard_widgets() :: [map()]
  def dashboard_widgets do
    [
      %{
        id: "worktree_status",
        name: "Worktree Status",
        category: :plugin,
        source_module: __MODULE__,
        refresh_interval: 30_000,
        min_width: 3,
        min_height: 2,
        config_schema: %{},
        plugin: "worktree",
        version: @plugin_version,
        description: "Active worktrees with branch and formation links"
      }
    ]
  end

  @impl true
  @spec default_enabled?() :: boolean()
  def default_enabled?, do: true

  # ── Sync logic ───────────────────────────────────────────────────────────────

  defp sync_git_worktrees(root) do
    case System.cmd("git", ["worktree", "list", "--porcelain"], cd: root, stderr_to_stdout: true) do
      {output, 0} ->
        live_worktrees = parse_porcelain(output, root)
        tracked = WorktreeStore.list()
        tracked_paths = MapSet.new(tracked, & &1.path)

        # Register new worktrees found in git but not in ETS
        registered =
          live_worktrees
          |> Enum.reject(fn wt -> MapSet.member?(tracked_paths, wt.path) end)
          |> Enum.map(fn wt ->
            {:ok, meta} = WorktreeStore.register(wt)
            meta.worktree_id
          end)

        # Prune tracked worktrees no longer in git
        live_paths = MapSet.new(live_worktrees, & &1.path)

        pruned =
          tracked
          |> Enum.reject(fn wt -> MapSet.member?(live_paths, wt.path) end)
          |> Enum.map(fn wt ->
            WorktreeStore.prune(wt.worktree_id)
            wt.worktree_id
          end)

        {:ok,
         %{
           registered: registered,
           pruned: pruned,
           total: length(live_worktrees),
           registered_count: length(registered),
           pruned_count: length(pruned)
         }}

      {error, _code} ->
        {:error, {:git_error, error}}
    end
  end

  defp parse_porcelain(output, _root) do
    output
    |> String.split("\n\n", trim: true)
    |> Enum.map(&parse_worktree_block/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_worktree_block(block) do
    lines = String.split(block, "\n", trim: true)

    attrs =
      Enum.reduce(lines, %{}, fn line, acc ->
        case String.split(line, " ", parts: 2) do
          ["worktree", path] -> Map.put(acc, :path, path)
          ["HEAD", _sha] -> acc
          ["branch", ref] -> Map.put(acc, :branch, ref |> String.replace("refs/heads/", ""))
          ["detached"] -> Map.put(acc, :branch, "detached")
          ["bare"] -> Map.put(acc, :branch, "bare")
          _ -> acc
        end
      end)

    if Map.has_key?(attrs, :path) and Map.has_key?(attrs, :branch) do
      attrs
    else
      nil
    end
  end
end
