defmodule ApmV4Web.UpmController do
  @moduledoc """
  REST API controller for UPM module — projects, PM integrations, VCS integrations,
  work items, and sync operations. 22 endpoints total.
  """
  use ApmV4Web, :controller

  alias ApmV4.UPM.{ProjectRegistry, PMIntegrationStore, VCSIntegrationStore, WorkItemStore, SyncEngine}

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
end
