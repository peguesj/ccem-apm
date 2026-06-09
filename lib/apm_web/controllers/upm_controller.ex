defmodule ApmWeb.UpmController do
  @moduledoc """
  REST API controller for UPM module — projects, PM integrations, VCS integrations,
  work items, and sync operations. 22 endpoints total.
  """
  use ApmWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias ApmWeb.Schemas
  alias OpenApiSpex.Schema

  alias Apm.UPM.{
    ProjectRegistry,
    PMIntegrationStore,
    VCSIntegrationStore,
    WorkItemStore,
    SyncEngine
  }

  operation(:list_projects,
    summary: "List UPM projects",
    description: "Returns all registered UPM projects.",
    tags: ["UPM"],
    responses: [ok: {"Project list", "application/json", Schemas.OkResponse}]
  )

  operation(:create_project,
    summary: "Create UPM project",
    description: "Creates or upserts a UPM project.",
    tags: ["UPM"],
    request_body: {"Project payload", "application/json", %Schema{type: :object}, required: true},
    responses: [
      ok: {"Project created", "application/json", Schemas.OkResponse},
      unprocessable_entity: {"Validation error", "application/json", Schemas.ErrorResponse}
    ]
  )

  operation(:scan_projects,
    summary: "Scan and sync UPM projects",
    description: "Scans project directories and syncs discovered projects.",
    tags: ["UPM"],
    responses: [
      ok: {"Scan result", "application/json", Schemas.OkResponse},
      internal_server_error: {"Scan error", "application/json", Schemas.ErrorResponse}
    ]
  )

  operation(:get_project,
    summary: "Get UPM project",
    description: "Returns a single UPM project by ID.",
    tags: ["UPM"],
    parameters: [id: [in: :path, type: :string, required: true, description: "Project ID"]],
    responses: [
      ok: {"Project detail", "application/json", Schemas.OkResponse},
      not_found: {"Not found", "application/json", Schemas.ErrorResponse}
    ]
  )

  operation(:update_project,
    summary: "Update UPM project",
    description: "Updates an existing UPM project.",
    tags: ["UPM"],
    parameters: [id: [in: :path, type: :string, required: true, description: "Project ID"]],
    request_body:
      {"Project update payload", "application/json", %Schema{type: :object}, required: true},
    responses: [
      ok: {"Project updated", "application/json", Schemas.OkResponse},
      unprocessable_entity: {"Validation error", "application/json", Schemas.ErrorResponse}
    ]
  )

  operation(:delete_project,
    summary: "Delete UPM project",
    description: "Removes a UPM project by ID.",
    tags: ["UPM"],
    parameters: [id: [in: :path, type: :string, required: true, description: "Project ID"]],
    responses: [
      ok: {"Deleted", "application/json", Schemas.OkResponse},
      not_found: {"Not found", "application/json", Schemas.ErrorResponse}
    ]
  )

  operation(:list_pm_integrations,
    summary: "List PM integrations",
    description: "Returns all PM integrations, optionally filtered by project.",
    tags: ["UPM"],
    parameters: [
      project_id: [
        in: :query,
        type: :string,
        required: false,
        description: "Filter by project ID"
      ]
    ],
    responses: [ok: {"PM integration list", "application/json", Schemas.OkResponse}]
  )

  operation(:create_pm_integration,
    summary: "Create PM integration",
    description: "Creates or upserts a PM integration.",
    tags: ["UPM"],
    request_body:
      {"PM integration payload", "application/json", %Schema{type: :object}, required: true},
    responses: [
      ok: {"PM integration created", "application/json", Schemas.OkResponse},
      unprocessable_entity: {"Validation error", "application/json", Schemas.ErrorResponse}
    ]
  )

  operation(:get_pm_integration,
    summary: "Get PM integration",
    description: "Returns a single PM integration by ID.",
    tags: ["UPM"],
    parameters: [id: [in: :path, type: :string, required: true, description: "Integration ID"]],
    responses: [
      ok: {"PM integration detail", "application/json", Schemas.OkResponse},
      not_found: {"Not found", "application/json", Schemas.ErrorResponse}
    ]
  )

  operation(:update_pm_integration,
    summary: "Update PM integration",
    description: "Updates an existing PM integration.",
    tags: ["UPM"],
    parameters: [id: [in: :path, type: :string, required: true, description: "Integration ID"]],
    request_body:
      {"PM integration update payload", "application/json", %Schema{type: :object},
       required: true},
    responses: [
      ok: {"PM integration updated", "application/json", Schemas.OkResponse},
      unprocessable_entity: {"Validation error", "application/json", Schemas.ErrorResponse}
    ]
  )

  operation(:delete_pm_integration,
    summary: "Delete PM integration",
    description: "Removes a PM integration by ID.",
    tags: ["UPM"],
    parameters: [id: [in: :path, type: :string, required: true, description: "Integration ID"]],
    responses: [
      ok: {"Deleted", "application/json", Schemas.OkResponse},
      not_found: {"Not found", "application/json", Schemas.ErrorResponse}
    ]
  )

  operation(:test_pm_integration,
    summary: "Test PM integration",
    description: "Tests the connection for a PM integration.",
    tags: ["UPM"],
    parameters: [id: [in: :path, type: :string, required: true, description: "Integration ID"]],
    responses: [
      ok: {"Connection test result", "application/json", Schemas.OkResponse},
      unprocessable_entity: {"Connection failed", "application/json", Schemas.ErrorResponse}
    ]
  )

  operation(:list_vcs_integrations,
    summary: "List VCS integrations",
    description: "Returns all VCS integrations, optionally filtered by project.",
    tags: ["UPM"],
    parameters: [
      project_id: [
        in: :query,
        type: :string,
        required: false,
        description: "Filter by project ID"
      ]
    ],
    responses: [ok: {"VCS integration list", "application/json", Schemas.OkResponse}]
  )

  operation(:create_vcs_integration,
    summary: "Create VCS integration",
    description: "Creates or upserts a VCS integration.",
    tags: ["UPM"],
    request_body:
      {"VCS integration payload", "application/json", %Schema{type: :object}, required: true},
    responses: [
      ok: {"VCS integration created", "application/json", Schemas.OkResponse},
      unprocessable_entity: {"Validation error", "application/json", Schemas.ErrorResponse}
    ]
  )

  operation(:get_vcs_integration,
    summary: "Get VCS integration",
    description: "Returns a single VCS integration by ID.",
    tags: ["UPM"],
    parameters: [id: [in: :path, type: :string, required: true, description: "Integration ID"]],
    responses: [
      ok: {"VCS integration detail", "application/json", Schemas.OkResponse},
      not_found: {"Not found", "application/json", Schemas.ErrorResponse}
    ]
  )

  operation(:update_vcs_integration,
    summary: "Update VCS integration",
    description: "Updates an existing VCS integration.",
    tags: ["UPM"],
    parameters: [id: [in: :path, type: :string, required: true, description: "Integration ID"]],
    request_body:
      {"VCS integration update payload", "application/json", %Schema{type: :object},
       required: true},
    responses: [
      ok: {"VCS integration updated", "application/json", Schemas.OkResponse},
      unprocessable_entity: {"Validation error", "application/json", Schemas.ErrorResponse}
    ]
  )

  operation(:delete_vcs_integration,
    summary: "Delete VCS integration",
    description: "Removes a VCS integration by ID.",
    tags: ["UPM"],
    parameters: [id: [in: :path, type: :string, required: true, description: "Integration ID"]],
    responses: [
      ok: {"Deleted", "application/json", Schemas.OkResponse},
      not_found: {"Not found", "application/json", Schemas.ErrorResponse}
    ]
  )

  operation(:test_vcs_integration,
    summary: "Test VCS integration",
    description: "Tests the connection for a VCS integration.",
    tags: ["UPM"],
    parameters: [id: [in: :path, type: :string, required: true, description: "Integration ID"]],
    responses: [
      ok: {"Connection test result", "application/json", Schemas.OkResponse},
      unprocessable_entity: {"Connection failed", "application/json", Schemas.ErrorResponse}
    ]
  )

  operation(:list_work_items,
    summary: "List work items",
    description: "Returns all work items, optionally filtered by project.",
    tags: ["UPM"],
    parameters: [
      project_id: [
        in: :query,
        type: :string,
        required: false,
        description: "Filter by project ID"
      ]
    ],
    responses: [ok: {"Work item list", "application/json", Schemas.OkResponse}]
  )

  operation(:drift_report,
    summary: "Work item drift report",
    description: "Detects drift between UPM stories and PM system work items.",
    tags: ["UPM"],
    responses: [ok: {"Drift report", "application/json", Schemas.OkResponse}]
  )

  operation(:sync_all,
    summary: "Sync all projects",
    description: "Runs SyncEngine.sync_project/1 for every registered project.",
    tags: ["UPM"],
    responses: [ok: {"Sync results", "application/json", Schemas.OkResponse}]
  )

  operation(:sync_project,
    summary: "Sync single project",
    description: "Runs SyncEngine.sync_project/1 for a single project.",
    tags: ["UPM"],
    parameters: [
      project_id: [in: :path, type: :string, required: true, description: "Project ID"]
    ],
    responses: [
      ok: {"Sync result", "application/json", Schemas.OkResponse},
      internal_server_error: {"Sync error", "application/json", Schemas.ErrorResponse}
    ]
  )

  operation(:sync_status,
    summary: "Sync history / status",
    description: "Returns the most recent 10 sync results and total sync count.",
    tags: ["UPM"],
    responses: [ok: {"Sync history", "application/json", Schemas.OkResponse}]
  )

  operation(:update_story,
    summary: "Update UPM story",
    description:
      "Updates tracking fields (todo_ref, commit_sha, worktree_ref, etc.) for a story.",
    tags: ["UPM"],
    request_body:
      {"Story update payload", "application/json", %Schema{type: :object}, required: true},
    responses: [
      ok: {"Story updated", "application/json", Schemas.OkResponse},
      not_found: {"Session or story not found", "application/json", Schemas.ErrorResponse}
    ]
  )

  operation(:write_manifest,
    summary: "Write formation manifest",
    description: "Persists a formation manifest to the :upm_manifests ETS table.",
    tags: ["UPM"],
    request_body:
      {"Manifest payload", "application/json", %Schema{type: :object}, required: true},
    responses: [ok: {"Manifest written", "application/json", Schemas.OkResponse}]
  )

  # Catch-all for any action not explicitly annotated above.
  def open_api_operation(_action), do: nil

  # ── Projects ──────────────────────────────────────────────────────────────

  def list_projects(conn, _params) do
    projects = ProjectRegistry.list_projects()
    json(conn, %{data: Enum.map(projects, &project_json/1)})
  end

  def create_project(conn, params) do
    case ProjectRegistry.upsert_project(params) do
      {:ok, project} -> json(conn, %{data: project_json(project)})
      {:error, reason} -> conn |> put_status(422) |> json(%{error: inspect(reason)})
    end
  end

  def get_project(conn, %{"id" => id}) do
    case ProjectRegistry.get_project(id) do
      {:ok, project} -> json(conn, %{data: project_json(project)})
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "Project not found"})
    end
  end

  def update_project(conn, %{"id" => id} = params) do
    attrs = Map.put(params, "id", id)

    case ProjectRegistry.upsert_project(attrs) do
      {:ok, project} -> json(conn, %{data: project_json(project)})
      {:error, reason} -> conn |> put_status(422) |> json(%{error: inspect(reason)})
    end
  end

  def delete_project(conn, %{"id" => id}) do
    case ProjectRegistry.delete_project(id) do
      :ok -> json(conn, %{ok: true})
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "Project not found"})
    end
  end

  def scan_projects(conn, _params) do
    case ProjectRegistry.scan_and_sync() do
      {:ok, count} -> json(conn, %{ok: true, synced: count})
      {:error, reason} -> conn |> put_status(500) |> json(%{error: inspect(reason)})
    end
  end

  # ── PM Integrations ────────────────────────────────────────────────────────

  def list_pm_integrations(conn, params) do
    integrations =
      case Map.get(params, "project_id") do
        nil -> PMIntegrationStore.list_integrations()
        project_id -> PMIntegrationStore.list_for_project(project_id)
      end

    json(conn, %{data: Enum.map(integrations, &pm_integration_json/1)})
  end

  def create_pm_integration(conn, params) do
    case PMIntegrationStore.upsert_integration(params) do
      {:ok, integration} -> json(conn, %{data: pm_integration_json(integration)})
      {:error, reason} -> conn |> put_status(422) |> json(%{error: inspect(reason)})
    end
  end

  def get_pm_integration(conn, %{"id" => id}) do
    case PMIntegrationStore.get_integration(id) do
      {:ok, integration} -> json(conn, %{data: pm_integration_json(integration)})
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "Integration not found"})
    end
  end

  def update_pm_integration(conn, %{"id" => id} = params) do
    attrs = Map.put(params, "id", id)

    case PMIntegrationStore.upsert_integration(attrs) do
      {:ok, integration} -> json(conn, %{data: pm_integration_json(integration)})
      {:error, reason} -> conn |> put_status(422) |> json(%{error: inspect(reason)})
    end
  end

  def delete_pm_integration(conn, %{"id" => id}) do
    case PMIntegrationStore.delete_integration(id) do
      :ok -> json(conn, %{ok: true})
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "Integration not found"})
    end
  end

  def test_pm_integration(conn, %{"id" => id}) do
    case PMIntegrationStore.test_connection(id) do
      {:ok, msg} -> json(conn, %{ok: true, message: msg})
      {:error, reason} -> conn |> put_status(422) |> json(%{ok: false, error: reason})
    end
  end

  # ── VCS Integrations ───────────────────────────────────────────────────────

  def list_vcs_integrations(conn, params) do
    integrations =
      case Map.get(params, "project_id") do
        nil -> VCSIntegrationStore.list_integrations()
        project_id -> VCSIntegrationStore.list_for_project(project_id)
      end

    json(conn, %{data: Enum.map(integrations, &vcs_integration_json/1)})
  end

  def create_vcs_integration(conn, params) do
    case VCSIntegrationStore.upsert_integration(params) do
      {:ok, integration} -> json(conn, %{data: vcs_integration_json(integration)})
      {:error, reason} -> conn |> put_status(422) |> json(%{error: inspect(reason)})
    end
  end

  def get_vcs_integration(conn, %{"id" => id}) do
    case VCSIntegrationStore.get_integration(id) do
      {:ok, integration} -> json(conn, %{data: vcs_integration_json(integration)})
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "Integration not found"})
    end
  end

  def update_vcs_integration(conn, %{"id" => id} = params) do
    attrs = Map.put(params, "id", id)

    case VCSIntegrationStore.upsert_integration(attrs) do
      {:ok, integration} -> json(conn, %{data: vcs_integration_json(integration)})
      {:error, reason} -> conn |> put_status(422) |> json(%{error: inspect(reason)})
    end
  end

  def delete_vcs_integration(conn, %{"id" => id}) do
    case VCSIntegrationStore.delete_integration(id) do
      :ok -> json(conn, %{ok: true})
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "Integration not found"})
    end
  end

  def test_vcs_integration(conn, %{"id" => id}) do
    case VCSIntegrationStore.test_connection(id) do
      {:ok, msg} -> json(conn, %{ok: true, message: msg})
      {:error, reason} -> conn |> put_status(422) |> json(%{ok: false, error: reason})
    end
  end

  # ── Work Items ─────────────────────────────────────────────────────────────

  def list_work_items(conn, params) do
    items =
      case Map.get(params, "project_id") do
        nil -> WorkItemStore.list_items()
        project_id -> WorkItemStore.list_for_project(project_id)
      end

    json(conn, %{data: Enum.map(items, &work_item_json/1)})
  end

  def drift_report(conn, _params) do
    summary = WorkItemStore.detect_drift_all()
    json(conn, %{data: summary})
  end

  # ── Sync ───────────────────────────────────────────────────────────────────

  def sync_all(conn, _params) do
    projects = ProjectRegistry.list_projects()

    results =
      Enum.map(projects, fn project ->
        case SyncEngine.sync_project(project.id) do
          {:ok, result} -> %{project_id: project.id, ok: true, synced: result.synced_count}
          {:error, reason} -> %{project_id: project.id, ok: false, error: inspect(reason)}
        end
      end)

    json(conn, %{data: results})
  end

  def sync_project(conn, %{"project_id" => project_id}) do
    case SyncEngine.sync_project(project_id) do
      {:ok, result} -> json(conn, %{data: sync_result_json(result)})
      {:error, reason} -> conn |> put_status(500) |> json(%{error: inspect(reason)})
    end
  end

  def sync_status(conn, _params) do
    history = SyncEngine.get_history()

    json(conn, %{
      data: %{
        last_syncs: Enum.map(Enum.take(history, 10), &sync_result_json/1),
        total_syncs: length(history)
      }
    })
  end

  # ── JSON serializers ───────────────────────────────────────────────────────

  defp project_json(p) do
    %{
      id: p.id,
      name: p.name,
      path: p.path,
      stack: p.stack || [],
      plane_project_id: p.plane_project_id,
      linear_project_id: p.linear_project_id,
      vcs_url: p.vcs_url,
      branch_strategy: p.branch_strategy,
      active_prd_branch: p.active_prd_branch,
      last_seen_at: p.last_seen_at && DateTime.to_iso8601(p.last_seen_at),
      tags: p.tags || []
    }
  end

  defp pm_integration_json(i) do
    %{
      id: i.id,
      project_id: i.project_id,
      platform: i.platform,
      base_url: i.base_url,
      workspace: i.workspace,
      project_key: i.project_key,
      sync_enabled: i.sync_enabled,
      last_sync_at: i.last_sync_at && DateTime.to_iso8601(i.last_sync_at)
    }
  end

  defp vcs_integration_json(i) do
    %{
      id: i.id,
      project_id: i.project_id,
      provider: i.provider,
      repo_url: i.repo_url,
      default_branch: i.default_branch,
      qa_branch: i.qa_branch,
      staging_branch: i.staging_branch,
      prod_branch: i.prod_branch,
      sync_type: i.sync_type,
      resource_group: i.resource_group,
      last_sync_at: i.last_sync_at && DateTime.to_iso8601(i.last_sync_at)
    }
  end

  defp work_item_json(item) do
    %{
      id: item.id,
      project_id: item.project_id,
      pm_integration_id: item.pm_integration_id,
      title: item.title,
      status: item.status,
      priority: item.priority,
      platform_id: item.platform_id,
      platform_key: item.platform_key,
      platform_url: item.platform_url,
      prd_story_id: item.prd_story_id,
      passes: item.passes,
      branch_name: item.branch_name,
      pr_url: item.pr_url,
      sync_status: item.sync_status
    }
  end

  defp sync_result_json(r) do
    %{
      project_id: r.project_id,
      synced_count: r.synced_count,
      drifted_count: r.drifted_count,
      errors: r.errors,
      started_at: r.started_at && DateTime.to_iso8601(r.started_at),
      completed_at: r.completed_at && DateTime.to_iso8601(r.completed_at)
    }
  end

  def update_story(conn, params) do
    session_id = Map.get(params, "session_id", "default")
    story_id = Map.get(params, "story_id")
    attrs = Map.take(params, ["todo_ref", "task_id", "commit_sha", "worktree_ref", "branch_ref"])

    case Apm.UpmStore.update_story(session_id, story_id, attrs) do
      :ok -> json(conn, %{ok: true})
      {:error, reason} -> conn |> put_status(404) |> json(%{ok: false, error: inspect(reason)})
    end
  end

  def write_manifest(conn, params) do
    formation_id = Map.get(params, "formation_id")
    manifest = Map.get(params, "manifest", %{})

    try do
      :ets.new(:upm_manifests, [:named_table, :public, :set])
    rescue
      ArgumentError -> :ok
    end

    :ets.insert(:upm_manifests, {formation_id, manifest, DateTime.utc_now()})
    json(conn, %{ok: true, formation_id: formation_id})
  end
end
