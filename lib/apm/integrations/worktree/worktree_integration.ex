defmodule Apm.Integrations.Worktree.WorktreeIntegration do
  @moduledoc """
  Bidirectional worktree integration — bridges git CLI operations with APM tracking.

  This integration enables APM to both **observe** worktree state (inbound from
  hooks/CLI) and **command** worktree operations (outbound create/prune via git).

  ## Bidirectional flow

  | Direction | Event / Action          | Description                             |
  |-----------|-------------------------|-----------------------------------------|
  | Inbound   | `worktree_registered`   | Hook/CLI reports new worktree created   |
  | Inbound   | `worktree_pruned`       | Hook/CLI reports worktree removed       |
  | Inbound   | `worktree_linked`       | Session or formation linked to worktree |
  | Outbound  | `create_worktree`       | APM commands git to create a worktree   |
  | Outbound  | `prune_worktree`        | APM commands git to remove a worktree   |
  | Query     | `list_worktrees`        | Queries WorktreeStore ETS               |
  """

  @behaviour Apm.Integrations.IntegrationBehaviour

  alias Apm.WorktreeStore

  require Logger

  @impl true
  def integration_name, do: "worktree"
  @impl true
  def integration_description,
    do: "Bidirectional git worktree management — observe and command worktree lifecycle"

  @impl true
  def integration_version, do: "1.0.0"
  @impl true
  def protocol, do: :custom
  @impl true
  def required_plugin, do: :worktree
  @impl true
  def target_native_feature, do: :worktree_store

  @impl true
  def connect(_config) do
    alive = Process.whereis(WorktreeStore) != nil
    if alive, do: {:ok, %{store: :connected}}, else: {:error, :store_not_running}
  end

  @impl true
  def disconnect, do: :ok

  @impl true
  def status do
    if Process.whereis(WorktreeStore) != nil, do: :connected, else: :disconnected
  end

  @impl true
  def list_endpoints do
    [
      %{action: "list_worktrees", description: "List all tracked worktrees"},
      %{action: "create_worktree", description: "Create a git worktree and register in APM"},
      %{action: "prune_worktree", description: "Remove a git worktree and deregister from APM"},
      %{action: "link_session", description: "Link a worktree to a Claude Code session"},
      %{action: "link_formation", description: "Link a worktree to a formation"}
    ]
  end

  # ── Inbound events (hooks/CLI → APM) ──────────────────────────────────────

  @impl true
  def handle_event("worktree_registered", payload, _opts) do
    WorktreeStore.register(payload)
  end

  def handle_event("worktree_pruned", %{"worktree_id" => id}, _opts) do
    case WorktreeStore.prune(id) do
      :ok -> {:ok, %{pruned: id}}
      {:error, reason} -> {:error, reason}
    end
  end

  def handle_event("worktree_linked", %{"worktree_id" => id} = payload, _opts) do
    attrs =
      payload
      |> Map.take(["parent_session_id", "formation_id"])
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    WorktreeStore.update(id, attrs)
  end

  # ── Outbound commands (APM → git CLI) ──────────────────────────────────────

  def handle_event("create_worktree", payload, _opts) do
    branch = Map.get(payload, "branch") || Map.get(payload, :branch)
    base = Map.get(payload, "base_branch") || Map.get(payload, :base_branch, "main")

    project_root =
      Map.get(payload, "project_root") || Map.get(payload, :project_root, File.cwd!())

    worktree_path = Path.join([project_root, ".claude", "worktrees", branch])

    case System.cmd("git", ["worktree", "add", worktree_path, "-b", branch, base],
           cd: project_root,
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        WorktreeStore.register(%{
          branch: branch,
          base_branch: base,
          path: worktree_path,
          project: Map.get(payload, "project") || Map.get(payload, :project),
          parent_session_id: Map.get(payload, "session_id") || Map.get(payload, :session_id),
          formation_id: Map.get(payload, "formation_id") || Map.get(payload, :formation_id),
          status: :active
        })

      {error, _code} ->
        {:error, {:git_error, error}}
    end
  end

  def handle_event("prune_worktree", payload, _opts) do
    id = Map.get(payload, "worktree_id") || Map.get(payload, :worktree_id)

    case WorktreeStore.get(id) do
      {:ok, wt} ->
        project_root =
          Map.get(payload, "project_root") || Map.get(payload, :project_root, File.cwd!())

        case System.cmd("git", ["worktree", "remove", wt.path, "--force"],
               cd: project_root,
               stderr_to_stdout: true
             ) do
          {_output, 0} ->
            WorktreeStore.prune(id)
            {:ok, %{pruned: id, path: wt.path}}

          {error, _code} ->
            {:error, {:git_error, error}}
        end

      {:error, :not_found} ->
        {:error, {:not_found, id}}
    end
  end

  def handle_event("list_worktrees", _payload, _opts) do
    {:ok, %{worktrees: WorktreeStore.list()}}
  end

  def handle_event("link_session", %{"worktree_id" => id, "session_id" => sid}, _opts) do
    WorktreeStore.update(id, %{parent_session_id: sid})
  end

  def handle_event("link_formation", %{"worktree_id" => id, "formation_id" => fid}, _opts) do
    WorktreeStore.update(id, %{formation_id: fid})
  end

  def handle_event(event, _payload, _opts), do: {:error, {:unknown_event, event}}

  @impl true
  def supervisor_children, do: []
end
