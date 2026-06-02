defmodule ApmWeb.ProvenanceLive do
  @moduledoc """
  LiveView for the Provenance intelligence page at `/intelligence/provenance`.

  ## Tabs

  - **Artifact Attestations** — table of ETS ring buffer attestations with
    agent_id, file_path, sha256_short, tool_name, timestamp, and valid/invalid
    signature badge. PubSub-driven live update on `"apm:artifacts"` topic.

  - **Lineage Graph** — D3.js visualization of `wasDerivedFrom` edges from
    `LineageTracker`. Filter by agent_id. Renders nodes and directed edges via
    the existing `FormationGraph`-style D3 lazy-load pattern.

  - **PROV Bundle** — The Turtle/JSON-LD bundle from `ProvExporter` for the
    currently-selected formation. Copy button (via JS `navigator.clipboard`).

  ## Real-time updates

  - Subscribes to `"apm:artifacts"` PubSub topic for attestation inserts.
  - 30-second periodic `:tick` for general refresh of all data.

  ## DRTW

  Reuses existing `FormationGraph` hook (D3.js already registered in `app.js`).
  New `ProvenanceLineageGraph` JS hook added for the lineage DAG tab.
  """

  use ApmWeb, :live_view

  require Logger

  alias Apm.Provenance.{ArtifactAttestation, ProvExporter, LineageTracker}
  alias Apm.Identity.KeyStore

  @pubsub_topic "apm:artifacts"
  @tick_interval_ms 30_000

  # ── Mount ──────────────────────────────────────────────────────────────────

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Apm.PubSub, @pubsub_topic)
      Process.send_after(self(), :tick, @tick_interval_ms)
    end

    formations = list_known_formations()
    selected_formation = List.first(formations)

    attestations = load_attestations()
    lineage = load_lineage(nil)
    bundle_text = load_bundle(selected_formation)

    socket =
      socket
      |> assign(:page_title, "Provenance")
      |> assign(:tab, :attestations)
      |> assign(:sidebar_collapsed, false)
      |> assign(:inspector_open, false)
      # attestations tab
      |> assign(:attestations, attestations)
      |> assign(:attestation_count, length(attestations))
      # lineage tab
      |> assign(:lineage_agent_filter, "")
      |> assign(:lineage, lineage)
      # bundle tab
      |> assign(:formations, formations)
      |> assign(:selected_formation, selected_formation)
      |> assign(:bundle_text, bundle_text)
      # shared
      |> assign(:notification_count, 0)
      |> assign(:skill_count, 0)
      |> ApmWeb.Components.SidebarNav.assign_sidebar_nav_data()

    {:ok, socket}
  end

  # ── Events ─────────────────────────────────────────────────────────────────

  @impl true
  def handle_event("switch_tab", %{"tab" => tab_str}, socket) do
    tab = String.to_existing_atom(tab_str)
    {:noreply, assign(socket, :tab, tab)}
  rescue
    ArgumentError -> {:noreply, socket}
  end

  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply, assign(socket, sidebar_collapsed: !socket.assigns.sidebar_collapsed)}
  end

  def handle_event("filter_lineage", %{"agent_id" => agent_id}, socket) do
    filter = String.trim(agent_id)
    agent_filter = if filter == "", do: nil, else: filter
    lineage = load_lineage(agent_filter)

    {:noreply,
     socket
     |> assign(:lineage_agent_filter, filter)
     |> assign(:lineage, lineage)}
  end

  def handle_event("select_formation", %{"formation_id" => fid}, socket) do
    bundle_text = load_bundle(fid)

    {:noreply,
     socket
     |> assign(:selected_formation, fid)
     |> assign(:bundle_text, bundle_text)}
  end

  def handle_event("copy_bundle", _params, socket) do
    # Delegate clipboard write to JS via push_event
    {:noreply, push_event(socket, "copy_to_clipboard", %{text: socket.assigns.bundle_text})}
  end

  def handle_event("refresh_attestations", _params, socket) do
    attestations = load_attestations()
    {:noreply, assign(socket, attestations: attestations, attestation_count: length(attestations))}
  end

  # ── PubSub ─────────────────────────────────────────────────────────────────

  @impl true
  def handle_info({:artifact_added, _attestation}, socket) do
    attestations = load_attestations()

    {:noreply,
     assign(socket,
       attestations: attestations,
       attestation_count: length(attestations)
     )}
  end

  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @tick_interval_ms)
    attestations = load_attestations()
    lineage = load_lineage(nonempty(socket.assigns.lineage_agent_filter))

    {:noreply,
     socket
     |> assign(:attestations, attestations)
     |> assign(:attestation_count, length(attestations))
     |> assign(:lineage, lineage)}
  end

  # Gracefully handle unexpected PubSub messages
  def handle_info(_msg, socket), do: {:noreply, socket}

  # ── Render ─────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <.page_layout sidebar_collapsed={@sidebar_collapsed} inspector_open={@inspector_open}>
      <:sidebar>
        <.sidebar_nav current_path="/intelligence/provenance" />
      </:sidebar>
      <:topbar>
        <.top_bar project_name="CCEM APM" />
      </:topbar>
      <:main>
        <div style="display:flex;flex-direction:column;height:100%;overflow:hidden;">
          <%!-- Header --%>
          <div style="padding:1.5rem 1.5rem 0;">
            <div style="display:flex;align-items:center;justify-content:space-between;">
              <div>
                <h1 style="font-size:1.5rem;font-weight:700;color:var(--ccem-text-primary);">
                  Provenance
                </h1>
                <p style="font-size:0.875rem;color:var(--ccem-text-muted);margin-top:0.25rem;">
                  Artifact attestations, lineage graph, and W3C PROV bundles
                </p>
              </div>
              <div style="display:flex;gap:0.5rem;align-items:center;">
                <.badge tone="neutral">{@attestation_count} attestations</.badge>
                <span style="font-size:0.75rem;color:var(--ccem-text-muted);">
                  Live — refreshes every 30s
                </span>
              </div>
            </div>
          </div>

          <%!-- Tab bar --%>
          <div style="padding:0 1.5rem;margin-top:1rem;border-bottom:1px solid var(--ccem-border);display:flex;gap:0.25rem;flex-shrink:0;">
            <%= for {tab_key, tab_label} <- [attestations: "Artifact Attestations", lineage: "Lineage Graph", bundle: "PROV Bundle"] do %>
              <button
                phx-click="switch_tab"
                phx-value-tab={tab_key}
                style={"padding:0.5rem 0.75rem;font-size:0.875rem;font-weight:500;border-bottom:2px solid #{if @tab == tab_key, do: "var(--ccem-accent)", else: "transparent"};color:#{if @tab == tab_key, do: "var(--ccem-accent)", else: "var(--ccem-text-muted)"};background:none;cursor:pointer;white-space:nowrap;border-top:none;border-left:none;border-right:none;"}
              >
                {tab_label}
              </button>
            <% end %>
          </div>

          <%!-- Tab content --%>
          <div style="flex:1;overflow-y:auto;padding:1.5rem;">

            <%!-- Attestations tab --%>
            <div :if={@tab == :attestations}>
              <div style="display:flex;justify-content:flex-end;margin-bottom:0.75rem;">
                <.btn variant="ghost" size="sm" phx-click="refresh_attestations">
                  Refresh
                </.btn>
              </div>
              <%= if @attestations == [] do %>
                <div style="text-align:center;padding:3rem;color:var(--ccem-text-muted);font-size:0.875rem;">
                  No artifact attestations recorded yet. Write/Edit tool calls will appear here.
                </div>
              <% else %>
                <div style="overflow-x:auto;">
                  <table style="width:100%;border-collapse:collapse;font-size:0.8125rem;">
                    <thead>
                      <tr style="border-bottom:1px solid var(--ccem-border);">
                        <%= for col <- ["Agent", "File", "SHA256", "Tool", "Timestamp", "Valid"] do %>
                          <th style="text-align:left;padding:0.5rem 0.75rem;font-weight:600;color:var(--ccem-text-muted);font-size:0.75rem;text-transform:uppercase;letter-spacing:0.05em;">
                            {col}
                          </th>
                        <% end %>
                      </tr>
                    </thead>
                    <tbody>
                      <%= for attest <- @attestations do %>
                        <tr style="border-bottom:1px solid var(--ccem-border);hover:background:var(--ccem-surface-hover);">
                          <td style="padding:0.5rem 0.75rem;font-family:var(--ccem-font-mono);font-size:0.75rem;color:var(--ccem-text-secondary);">
                            {attest.agent_id || "—"}
                          </td>
                          <td style="padding:0.5rem 0.75rem;font-family:var(--ccem-font-mono);font-size:0.75rem;max-width:16rem;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;color:var(--ccem-text-primary);">
                            {file_path(attest)}
                          </td>
                          <td style="padding:0.5rem 0.75rem;font-family:var(--ccem-font-mono);font-size:0.75rem;color:var(--ccem-text-muted);">
                            {sha256_short(attest)}
                          </td>
                          <td style="padding:0.5rem 0.75rem;">
                            <.badge tone="neutral" style="font-size:0.7rem;">{attest.tool_name || "—"}</.badge>
                          </td>
                          <td style="padding:0.5rem 0.75rem;font-family:var(--ccem-font-mono);font-size:0.75rem;color:var(--ccem-text-muted);">
                            {format_timestamp(attest.timestamp)}
                          </td>
                          <td style="padding:0.5rem 0.75rem;">
                            <.badge tone={if sig_valid?(attest), do: "success", else: "error"}>
                              {if sig_valid?(attest), do: "valid", else: "invalid"}
                            </.badge>
                          </td>
                        </tr>
                      <% end %>
                    </tbody>
                  </table>
                </div>
              <% end %>
            </div>

            <%!-- Lineage Graph tab --%>
            <div :if={@tab == :lineage}>
              <div style="display:flex;align-items:center;gap:0.75rem;margin-bottom:1rem;">
                <span style="font-size:0.875rem;color:var(--ccem-text-muted);">Filter by agent:</span>
                <.ds_input
                  type="text"
                  name="agent_id"
                  value={@lineage_agent_filter}
                  placeholder="agent-id (blank = all)"
                  phx-change="filter_lineage"
                  phx-debounce="400"
                />
              </div>

              <%= if @lineage.nodes == [] do %>
                <div style="text-align:center;padding:3rem;color:var(--ccem-text-muted);font-size:0.875rem;">
                  No lineage edges recorded yet. wasDerivedFrom edges appear when tool outputs are consumed.
                </div>
              <% else %>
                <div style="background:var(--ccem-bg-secondary);border:1px solid var(--ccem-border);border-radius:0.5rem;padding:0.5rem;">
                  <div style="font-size:0.75rem;color:var(--ccem-text-muted);margin-bottom:0.5rem;padding:0 0.5rem;">
                    {@lineage.nodes |> length()} nodes · {Map.get(@lineage, :edges, []) |> length()} edges
                  </div>
                  <%!-- D3 lineage graph container — updated via push_event --%>
                  <div
                    id="provenance-lineage-graph"
                    phx-hook="ProvenanceLineageGraph"
                    data-nodes={Jason.encode!(@lineage.nodes)}
                    data-edges={Jason.encode!(Map.get(@lineage, :edges, []))}
                    style="width:100%;height:420px;overflow:hidden;"
                  >
                  </div>
                </div>
              <% end %>
            </div>

            <%!-- PROV Bundle tab --%>
            <div :if={@tab == :bundle}>
              <div style="display:flex;align-items:center;gap:0.75rem;margin-bottom:1rem;">
                <span style="font-size:0.875rem;color:var(--ccem-text-muted);">Formation:</span>
                <select
                  phx-change="select_formation"
                  name="formation_id"
                  style="font-size:0.875rem;padding:0.25rem 0.5rem;border:1px solid var(--ccem-border);border-radius:0.25rem;background:var(--ccem-bg-secondary);color:var(--ccem-text-primary);"
                >
                  <option value="">— all known formations —</option>
                  <%= for fid <- @formations do %>
                    <option value={fid} selected={@selected_formation == fid}>{fid}</option>
                  <% end %>
                </select>
                <.btn variant="secondary" size="sm" phx-click="copy_bundle">
                  Copy
                </.btn>
              </div>

              <div style="position:relative;">
                <textarea
                  readonly
                  style="width:100%;min-height:420px;padding:1rem;font-family:var(--ccem-font-mono);font-size:0.75rem;color:var(--ccem-text-primary);background:var(--ccem-bg-secondary);border:1px solid var(--ccem-border);border-radius:0.5rem;resize:vertical;outline:none;"
                  id="prov-bundle-textarea"
                ><%= @bundle_text %></textarea>
              </div>

              <div style="margin-top:0.5rem;font-size:0.75rem;color:var(--ccem-text-muted);">
                W3C PROV-JSONLD bundle — generated by <code>Apm.Provenance.ProvExporter</code>
              </div>
            </div>

          </div>
        </div>
      </:main>
    </.page_layout>
    """
  end

  # ── Private helpers ─────────────────────────────────────────────────────────

  @spec load_attestations() :: [ArtifactAttestation.t()]
  defp load_attestations do
    table = :apm_artifact_attestations

    if :ets.whereis(table) != :undefined do
      :ets.tab2list(table)
      |> Enum.map(fn {_idx, attest} -> attest end)
      |> Enum.sort_by(& &1.timestamp, {:desc, Date})
      |> Enum.take(200)
    else
      []
    end
  rescue
    _ -> []
  end

  @spec load_lineage(String.t() | nil) :: map()
  defp load_lineage(agent_filter) do
    if Code.ensure_loaded?(LineageTracker) and
         function_exported?(LineageTracker, :lineage_for_agent, 1) and
         is_binary(agent_filter) and agent_filter != "" do
      apply(LineageTracker, :lineage_for_agent, [agent_filter])
    else
      # Full graph: collect all nodes and edges
      try do
        if Code.ensure_loaded?(LineageTracker) and
             function_exported?(LineageTracker, :all_lineage, 0) do
          apply(LineageTracker, :all_lineage, [])
        else
          %{nodes: [], edges: []}
        end
      rescue
        _ -> %{nodes: [], edges: []}
      catch
        :exit, _ -> %{nodes: [], edges: []}
      end
    end
  rescue
    _ -> %{nodes: [], edges: []}
  end

  @spec load_bundle(String.t() | nil) :: String.t()
  defp load_bundle(nil), do: "{}"
  defp load_bundle(""), do: "{}"

  defp load_bundle(formation_id) do
    bundle_map = ProvExporter.build_bundle(formation_id, format: :jsonld)
    Jason.encode!(bundle_map, pretty: true)
  rescue
    _ -> "{}"
  end

  @spec list_known_formations() :: [String.t()]
  defp list_known_formations do
    table = :apm_agents

    if :ets.whereis(table) != :undefined do
      :ets.tab2list(table)
      |> Enum.map(fn {_id, agent} -> Map.get(agent, :formation_id) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()
    else
      []
    end
  rescue
    _ -> []
  end

  # Render helpers

  defp file_path(%ArtifactAttestation{subject: [%{name: name} | _]}), do: name
  defp file_path(%ArtifactAttestation{subject: [h | _]}) when is_map(h), do: Map.get(h, :name) || Map.get(h, "name") || "—"
  defp file_path(_), do: "—"

  defp sha256_short(%ArtifactAttestation{subject: [%{sha256: sha} | _]}) when is_binary(sha) do
    String.slice(sha, 0, 12) <> "…"
  end
  defp sha256_short(%ArtifactAttestation{subject: [h | _]}) when is_map(h) do
    sha = Map.get(h, :sha256) || Map.get(h, "sha256") || ""
    String.slice(sha, 0, 12) <> "…"
  end
  defp sha256_short(_), do: "—"

  defp format_timestamp(nil), do: "—"
  defp format_timestamp(ts) when is_binary(ts), do: String.slice(ts, 0, 19) |> String.replace("T", " ")
  defp format_timestamp(_), do: "—"

  defp sig_valid?(%ArtifactAttestation{signature: sig} = attest) when is_binary(sig) and byte_size(sig) == 64 do
    payload = ArtifactAttestation.signing_payload(attest)

    try do
      pub = KeyStore.public_key()
      if is_binary(pub), do: KeyStore.verify(payload, sig, pub), else: false
    rescue
      _ -> false
    catch
      :exit, _ -> false
    end
  end

  defp sig_valid?(_), do: false

  defp nonempty(""), do: nil
  defp nonempty(s) when is_binary(s), do: s
  defp nonempty(_), do: nil
end
