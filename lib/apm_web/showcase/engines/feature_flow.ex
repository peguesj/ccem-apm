defmodule ApmWeb.Showcase.Engines.FeatureFlow do
  @moduledoc """
  Feature-flow showcase engine.

  Consumes layered-graph JSON posted by the `/feature-flow` skill v2 client
  (see ~/.claude/skills/feature-flow/SKILL.md D2) and renders it as a
  project-scoped APM page.

  ## Render strategy

  v1 iframes the consumer's standalone server (which hosts the React canvas)
  rather than bundling the React asset into APM. This keeps APM lean and
  decouples APM releases from the consumer's canvas evolution. The iframe
  src is supplied by the consumer in the ingested payload via the
  `"render_iframe_src"` field; if absent, the engine falls back to a
  textual JSON dump for debugging.

  ## Ingest payload shape

  Minimal contract enforced by `ingest/2`:

      {
        "project_name": "string (required, matched against active APM project)",
        "graph":         {... layered graph JSON ...},
        "render_iframe_src": "http://127.0.0.1:<port>/...",   # optional
        "version":       "string (optional, e.g. v2)",
        "generated_at":  "ISO8601 string (optional)"
      }

  Additional keys are preserved verbatim. The engine does not interpret the
  graph; that is the consumer's renderer's job.
  """

  @behaviour ApmWeb.Showcase.Engine

  use Phoenix.Component

  alias ApmWeb.Showcase.PayloadStore

  @id "feature-flow"

  @impl true
  def id, do: @id

  @impl true
  def project_scope, do: :strict

  @impl true
  def supports_post?, do: true

  @impl true
  def fetch(project_name, _params) when is_binary(project_name) do
    case PayloadStore.get(@id, project_name) do
      {:ok, record} -> {:ok, record.payload}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @impl true
  def ingest(project_name, payload) when is_binary(project_name) and is_map(payload) do
    with {:ok, normalized} <- validate(project_name, payload) do
      PayloadStore.put(@id, project_name, normalized)
      {:ok, normalized}
    end
  end

  @impl true
  def render_payload(payload, assigns) do
    assigns =
      assigns
      |> Map.put(:iframe_src, Map.get(payload, "render_iframe_src"))
      |> Map.put(:project_name, Map.get(payload, "project_name", ""))
      |> Map.put(:version, Map.get(payload, "version", ""))
      |> Map.put(:generated_at, Map.get(payload, "generated_at", ""))
      |> Map.put(:graph_json, Map.get(payload, "graph", %{}))

    render_template(assigns)
  end

  # --- Internals ---

  defp validate(active_project, payload) do
    cond do
      not is_map(payload) ->
        {:error, :payload_not_a_map}

      not is_binary(Map.get(payload, "project_name")) ->
        {:error, :missing_project_name}

      Map.get(payload, "project_name") != active_project ->
        {:error, :project_scope_mismatch}

      not is_map(Map.get(payload, "graph")) ->
        {:error, :missing_graph}

      true ->
        {:ok, payload}
    end
  end

  defp render_template(assigns) do
    ~H"""
    <div class="showcase-engine showcase-engine--feature-flow">
      <header class="showcase-engine__header">
        <h2>Feature Flow</h2>
        <dl class="showcase-engine__meta">
          <div>
            <dt>Project</dt>
            <dd>{@project_name}</dd>
          </div>
          <%= if @version != "" do %>
            <div>
              <dt>Version</dt>
              <dd>{@version}</dd>
            </div>
          <% end %>
          <%= if @generated_at != "" do %>
            <div>
              <dt>Generated</dt>
              <dd>{@generated_at}</dd>
            </div>
          <% end %>
        </dl>
      </header>

      <%= if is_binary(@iframe_src) and @iframe_src != "" do %>
        <iframe
          src={@iframe_src}
          class="showcase-engine__iframe"
          style="width:100%;height:80vh;border:0;"
          sandbox="allow-scripts allow-same-origin allow-forms"
          title="Feature Flow canvas">
        </iframe>
      <% else %>
        <section class="showcase-engine__fallback">
          <p>
            No <code>render_iframe_src</code> in the ingested payload. Showing raw graph JSON.
          </p>
          <pre><code>{Jason.encode!(@graph_json, pretty: true)}</code></pre>
        </section>
      <% end %>
    </div>
    """
  end
end
