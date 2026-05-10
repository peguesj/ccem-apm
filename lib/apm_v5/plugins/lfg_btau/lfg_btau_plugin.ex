defmodule ApmV5.Plugins.LfgBtau.LfgBtauPlugin do
  @moduledoc """
  PluginBehaviour implementation for the LFG BTAU archival sparsebundle plugin.

  Exposes three actions available to the APM action engine:
  - `mount_archive`   — mount the BTAU sparsebundle for the given archive_id
  - `release_archive` — release a lock token returned by mount_archive
  - `mount_status`    — return current mount state

  Scope: `:lfg_btau`
  """

  @behaviour ApmV5.Plugins.PluginBehaviour

  alias ApmV5.Plugins.LfgBtau.MountManager

  @impl true
  def plugin_name, do: "lfg_btau"

  @impl true
  def plugin_description,
    do: "Ref-counted mount/release lifecycle manager for the BTAU archival sparsebundle."

  @impl true
  def plugin_version, do: "1.0.0"

  @impl true
  def list_endpoints do
    [
      %{
        action: "mount_archive",
        description: "Mount the BTAU sparsebundle for the given archive_id.",
        params: %{archive_id: "string"}
      },
      %{
        action: "release_archive",
        description: "Release a lock token previously obtained via mount_archive.",
        params: %{lock_token: "reference"}
      },
      %{
        action: "mount_status",
        description: "Return the current mount state of the BTAU sparsebundle.",
        params: %{}
      }
    ]
  end

  @impl true
  def handle_action("mount_archive", %{"archive_id" => archive_id}, _opts) do
    case MountManager.mount(archive_id) do
      {:ok, info} -> {:ok, info}
      {:error, reason} -> {:error, reason}
    end
  end

  def handle_action("release_archive", %{"lock_token" => token}, _opts) do
    if is_reference(token) do
      MountManager.release(token)
      {:ok, %{released: true}}
    else
      {:ok, %{released: false, reason: "lock_token not serializable over JSON"}}
    end
  end

  def handle_action("mount_status", _params, _opts) do
    {:ok, MountManager.status()}
  end

  def handle_action(action_id, _params, _opts) do
    {:error, {:unknown_action, action_id}}
  end

  ## Optional callbacks

  @impl true
  def plugin_scope, do: :lfg_btau

  @impl true
  def nav_items, do: []

  @impl true
  def dashboard_widgets, do: []

  @impl true
  def supervisor_children, do: [MountManager]
end
