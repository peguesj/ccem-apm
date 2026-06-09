defmodule ApmWeb.Showcase.Components.EngineChrome do
  @moduledoc """
  Shared chrome (header, project breadcrumb) wrapped around any showcase
  engine's rendered payload. Engines render their domain UI inside the
  inner block.

  Kept intentionally minimal in v1 — APM's global sidebar/topbar already
  wrap LiveViews mounted under `:main_app`; this chrome only adds the
  per-engine breadcrumb so the user knows which engine is mounted and
  which project it is scoped to.
  """

  use Phoenix.Component

  attr :engine_id, :string, required: true
  attr :active_project, :string, default: ""
  attr :status, :atom, default: :ok, values: [:ok, :not_found, :error, :scope_mismatch]
  attr :status_detail, :string, default: ""
  slot :inner_block

  def engine_chrome(assigns) do
    ~H"""
    <div class="showcase-engine-chrome">
      <nav class="showcase-engine-chrome__breadcrumb" aria-label="Breadcrumb">
        <ol>
          <li><a href="/">APM</a></li>
          <li><a href="/showcase">Showcase</a></li>
          <li aria-current="page">{@engine_id}</li>
        </ol>
      </nav>

      <div class="showcase-engine-chrome__status" data-status={@status}>
        <span>Project:</span>
        <strong>{if @active_project == "", do: "(none)", else: @active_project}</strong>
        <%= if @status != :ok do %>
          <span class="showcase-engine-chrome__status-detail">{@status_detail}</span>
        <% end %>
      </div>

      <main class="showcase-engine-chrome__body">
        {render_slot(@inner_block)}
      </main>
    </div>
    """
  end
end
