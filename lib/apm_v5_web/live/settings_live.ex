defmodule ApmV5Web.SettingsLive do
  @moduledoc """
  Govern — AgentLock Settings (full page).

  Consolidates every AgentLock authorization preference into one surface,
  replacing the previously-dead `toggle_settings_modal` button on
  `AuthorizationLive` (it flipped an assign with no render block).

  Settings managed here:
  - **Approval display mode** — how an `ask`/escalated decision is surfaced:
    `:always_modal` (blocking overlay), `:toast_actions` (corner toaster with
    inline Approve/Deny), `:toast_click` (corner toaster, click to open modal —
    the default; an always-on modal is flow-breaking so it is opt-in).
  - **Risk evaluation mode** — automatic vs manual.
  - **Risk threshold** — 0–100 escalation cutoff.
  - **Decision timeout** — pending-approval TTL seconds.
  - **Redaction mode** — auto / strict / off for secret masking in the audit log.
  - **Policy rules** — view + remove always_allow / always_deny rules.

  Persistence reuses the same `agentlock_settings` block in
  `~/Developer/ccem/apm/apm_config.json` written by `AuthorizationLive`, so the
  two pages stay in sync via the `apm:settings` PubSub topic.
  """

  use ApmV5Web, :live_view

  alias ApmV5.Auth.PolicyRulesStore

  @valid_display_modes [:always_modal, :toast_actions, :toast_click]
  @default_display_mode :toast_click
  @config_path "~/Developer/ccem/apm/apm_config.json"

  # ---------------------------------------------------------------------------
  # Mount
  # ---------------------------------------------------------------------------

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ApmV5.PubSub, "apm:settings")
    end

    settings = load_settings()

    {:ok,
     socket
     |> assign(
       page_title: "AgentLock Settings",
       sidebar_collapsed: false,
       inspector_open: false,
       approval_display_mode: settings.approval_display_mode,
       risk_eval_mode: settings.risk_eval_mode,
       risk_threshold: settings.risk_threshold,
       timeout_seconds: settings.timeout_seconds,
       redaction_mode: settings.redaction_mode,
       policy_rules: safe_list_rules(),
       saved_flash: nil
     )
     |> ApmV5Web.Components.SidebarNav.assign_sidebar_nav_data()}
  end

  # ---------------------------------------------------------------------------
  # handle_info — keep in sync if the other page changes settings
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info({:settings_updated, settings}, socket) do
    {:noreply,
     assign(socket,
       approval_display_mode: safe_mode_atom(settings[:approval_display_mode]),
       risk_eval_mode: to_atom(settings[:risk_eval_mode], :automatic),
       risk_threshold: settings[:risk_threshold] || socket.assigns.risk_threshold,
       timeout_seconds: settings[:timeout_seconds] || socket.assigns.timeout_seconds,
       redaction_mode: to_atom(settings[:redaction_mode], :auto)
     )}
  end

  def handle_info(:clear_flash, socket), do: {:noreply, assign(socket, :saved_flash, nil)}

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ---------------------------------------------------------------------------
  # handle_event
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply, assign(socket, :sidebar_collapsed, !socket.assigns.sidebar_collapsed)}
  end

  @impl true
  def handle_event("set_display_mode", %{"mode" => mode}, socket) do
    socket = assign(socket, :approval_display_mode, safe_mode_atom(mode))
    persist(socket)
    {:noreply, flash_saved(socket)}
  end

  @impl true
  def handle_event("set_risk_eval_mode", %{"mode" => mode}, socket) do
    socket = assign(socket, :risk_eval_mode, to_atom(mode, :automatic))
    persist(socket)
    {:noreply, flash_saved(socket)}
  end

  @impl true
  def handle_event("set_redaction_mode", %{"mode" => mode}, socket) do
    socket = assign(socket, :redaction_mode, to_atom(mode, :auto))
    persist(socket)
    {:noreply, flash_saved(socket)}
  end

  @impl true
  def handle_event("update_risk_threshold", %{"value" => value}, socket) do
    socket = assign(socket, :risk_threshold, safe_int(value, socket.assigns.risk_threshold))
    persist(socket)
    {:noreply, flash_saved(socket)}
  end

  @impl true
  def handle_event("update_timeout", %{"value" => value}, socket) do
    socket = assign(socket, :timeout_seconds, safe_int(value, socket.assigns.timeout_seconds))
    persist(socket)
    {:noreply, flash_saved(socket)}
  end

  @impl true
  def handle_event("remove_rule", %{"tool" => tool_name}, socket) do
    PolicyRulesStore.remove_rule(tool_name)
    {:noreply, assign(socket, :policy_rules, safe_list_rules())}
  end

  @impl true
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <.page_layout sidebar_collapsed={@sidebar_collapsed} inspector_open={@inspector_open}>
      <:sidebar>
        <.sidebar_nav current_path="/govern/settings" />
      </:sidebar>

      <:topbar>
        <.top_bar project_name="CCEM APM" />
      </:topbar>

      <:main>
        <div style="display:flex; align-items:center; justify-content:space-between; margin-bottom:20px;">
          <div style="display:flex; align-items:center; gap:12px;">
            <h1 style="font-size:20px; font-weight:700; color:var(--ccem-fg); margin:0;">
              AgentLock Settings
            </h1>
            <.badge tone="iris">v9.2.0</.badge>
            <%= if @saved_flash do %>
              <.badge tone="success" dot>Saved</.badge>
            <% end %>
          </div>
          <.link navigate="/govern/authorization">
            <.btn variant="ghost" size="sm">&#8592; Back to Authorization</.btn>
          </.link>
        </div>

        <%!-- Approval display behavior --%>
        <.card style="margin-bottom:16px;">
          <p style="font-size:13px; font-weight:600; color:var(--ccem-fg); margin:0 0 4px;">
            Approval surface — Default behavior
          </p>
          <p style="font-size:12px; color:var(--ccem-fg-muted); margin:0 0 14px;">
            How a pending authorization request is shown. An always-on modal
            interrupts your work, so it is opt-in. Keyboard while focused:
            <kbd style="background:var(--ccem-bg-2);border:1px solid var(--ccem-line);border-radius:3px;padding:1px 5px;">&#8629;</kbd>
            approve ·
            <kbd style="background:var(--ccem-bg-2);border:1px solid var(--ccem-line);border-radius:3px;padding:1px 5px;">Esc</kbd>
            /
            <kbd style="background:var(--ccem-bg-2);border:1px solid var(--ccem-line);border-radius:3px;padding:1px 5px;">D</kbd>
            deny.
          </p>
          <div style="display:flex; flex-direction:column; gap:8px;">
            <%= for {mode, label, desc} <- [
              {:toast_click, "Toaster (click to open modal)", "Least interruptive — recommended default"},
              {:toast_actions, "Toaster with options", "Corner toaster with inline Approve / Deny buttons"},
              {:always_modal, "Always show modal", "Blocking overlay every time — flow-breaking"}
            ] do %>
              <button
                type="button"
                phx-click="set_display_mode"
                phx-value-mode={Atom.to_string(mode)}
                style={"display:flex; align-items:flex-start; gap:12px; width:100%; text-align:left; background:#{if @approval_display_mode == mode, do: "var(--ccem-bg-2)", else: "transparent"}; border:1px solid #{if @approval_display_mode == mode, do: "var(--ccem-accent, #7c9eff)", else: "var(--ccem-line)"}; border-radius:8px; padding:12px 14px; cursor:pointer; color:var(--ccem-fg);"}
              >
                <span style={"margin-top:2px; width:16px; height:16px; border-radius:50%; border:2px solid #{if @approval_display_mode == mode, do: "var(--ccem-accent, #7c9eff)", else: "var(--ccem-line)"}; flex-shrink:0; display:flex; align-items:center; justify-content:center;"}>
                  <%= if @approval_display_mode == mode do %>
                    <span style="width:7px; height:7px; border-radius:50%; background:var(--ccem-accent, #7c9eff);"></span>
                  <% end %>
                </span>
                <span style="display:flex; flex-direction:column; gap:3px;">
                  <span style="font-size:13px; font-weight:600;">{label}</span>
                  <span style="font-size:12px; color:var(--ccem-fg-muted);">{desc}</span>
                </span>
              </button>
            <% end %>
          </div>
        </.card>

        <div style="display:grid; grid-template-columns:repeat(2,1fr); gap:16px; margin-bottom:16px;">
          <%!-- Risk evaluation --%>
          <.card>
            <p style="font-size:13px; font-weight:600; color:var(--ccem-fg); margin:0 0 12px;">
              Risk evaluation
            </p>
            <div style="display:flex; gap:8px;">
              <.btn
                variant={if @risk_eval_mode == :automatic, do: "primary", else: "ghost"}
                size="sm"
                phx-click="set_risk_eval_mode"
                phx-value-mode="automatic"
              >
                Automatic
              </.btn>
              <.btn
                variant={if @risk_eval_mode == :manual, do: "primary", else: "ghost"}
                size="sm"
                phx-click="set_risk_eval_mode"
                phx-value-mode="manual"
              >
                Manual
              </.btn>
            </div>
            <div style="margin-top:16px;">
              <label style="font-size:12px; color:var(--ccem-fg-dim); display:block; margin-bottom:6px;">
                Risk threshold: <strong>{@risk_threshold}</strong>
              </label>
              <form phx-change="update_risk_threshold">
                <input
                  type="range"
                  name="value"
                  min="0"
                  max="100"
                  value={@risk_threshold}
                  style="width:100%;"
                />
              </form>
            </div>
          </.card>

          <%!-- Timeout + redaction --%>
          <.card>
            <p style="font-size:13px; font-weight:600; color:var(--ccem-fg); margin:0 0 12px;">
              Decision timeout
            </p>
            <form phx-change="update_timeout">
              <input
                type="number"
                name="value"
                min="5"
                max="120"
                value={@timeout_seconds}
                style="width:100px; padding:6px 8px; background:var(--ccem-bg-2); border:1px solid var(--ccem-line); border-radius:6px; color:var(--ccem-fg);"
              />
              <span style="font-size:12px; color:var(--ccem-fg-muted); margin-left:8px;">
                seconds (pending TTL)
              </span>
            </form>

            <p style="font-size:13px; font-weight:600; color:var(--ccem-fg); margin:18px 0 10px;">
              Audit log redaction
            </p>
            <div style="display:flex; gap:8px;">
              <%= for m <- [:auto, :strict, :off] do %>
                <.btn
                  variant={if @redaction_mode == m, do: "primary", else: "ghost"}
                  size="sm"
                  phx-click="set_redaction_mode"
                  phx-value-mode={Atom.to_string(m)}
                >
                  {m |> Atom.to_string() |> String.capitalize()}
                </.btn>
              <% end %>
            </div>
          </.card>
        </div>

        <%!-- Policy rules --%>
        <.card>
          <div style="display:flex; align-items:center; justify-content:space-between; margin-bottom:12px;">
            <p style="font-size:13px; font-weight:600; color:var(--ccem-fg); margin:0;">
              Policy rules
            </p>
            <.badge tone="neutral">{length(@policy_rules)} active</.badge>
          </div>
          <%= if @policy_rules == [] do %>
            <p style="font-size:12px; color:var(--ccem-fg-muted); margin:0;">
              No always_allow / always_deny rules. Decisions follow risk
              evaluation. (A permissive wildcard rule is intentionally absent —
              correct agent identity propagation is the durable fix, not a
              blanket allow.)
            </p>
          <% else %>
            <div style="display:flex; flex-direction:column; gap:8px;">
              <%= for rule <- @policy_rules do %>
                <div style="display:flex; align-items:center; justify-content:space-between; padding:8px 12px; background:var(--ccem-bg-2); border:1px solid var(--ccem-line); border-radius:6px;">
                  <div style="display:flex; align-items:center; gap:10px;">
                    <span style="font-size:13px; font-family:var(--ccem-font-mono); color:var(--ccem-fg);">
                      {Map.get(rule, :tool) || Map.get(rule, :tool_name) || "—"}
                    </span>
                    <.badge tone={
                      if (Map.get(rule, :action) || Map.get(rule, :decision)) in [:always_allow, "always_allow"],
                        do: "success",
                        else: "error"
                    }>
                      {Map.get(rule, :action) || Map.get(rule, :decision)}
                    </.badge>
                  </div>
                  <.btn
                    variant="ghost"
                    size="xs"
                    phx-click="remove_rule"
                    phx-value-tool={Map.get(rule, :tool) || Map.get(rule, :tool_name)}
                  >
                    Remove
                  </.btn>
                </div>
              <% end %>
            </div>
          <% end %>
        </.card>
      </:main>
    </.page_layout>
    """
  end

  # ---------------------------------------------------------------------------
  # Settings persistence — shared agentlock_settings block in apm_config.json
  # ---------------------------------------------------------------------------

  defp persist(socket) do
    a = socket.assigns

    settings = %{
      risk_eval_mode: a.risk_eval_mode,
      risk_threshold: a.risk_threshold,
      timeout_seconds: a.timeout_seconds,
      redaction_mode: a.redaction_mode,
      approval_display_mode: a.approval_display_mode
    }

    Task.start(fn -> write_settings(settings) end)

    notify_apm(
      "Settings updated",
      "approval=#{a.approval_display_mode} risk=#{a.risk_eval_mode}/#{a.risk_threshold} ttl=#{a.timeout_seconds}s redaction=#{a.redaction_mode}"
    )

    :ok
  end

  defp write_settings(settings) do
    try do
      path = Path.expand(@config_path)

      case File.read(path) do
        {:ok, content} ->
          updated = content |> Jason.decode!() |> Map.put("agentlock_settings", settings)
          File.write!(path, Jason.encode!(updated, pretty: true))
          Phoenix.PubSub.broadcast(ApmV5.PubSub, "apm:settings", {:settings_updated, settings})

        _ ->
          :ok
      end
    rescue
      _ -> :ok
    end
  end

  defp load_settings do
    defaults = %{
      approval_display_mode: @default_display_mode,
      risk_eval_mode: :automatic,
      risk_threshold: 50,
      timeout_seconds: 20,
      redaction_mode: :auto
    }

    try do
      with {:ok, content} <- File.read(Path.expand(@config_path)),
           {:ok, %{"agentlock_settings" => s}} <- Jason.decode(content) do
        %{
          approval_display_mode: safe_mode_atom(s["approval_display_mode"]),
          risk_eval_mode: to_atom(s["risk_eval_mode"], :automatic),
          risk_threshold: s["risk_threshold"] || 50,
          timeout_seconds: s["timeout_seconds"] || 20,
          redaction_mode: to_atom(s["redaction_mode"], :auto)
        }
      else
        _ -> defaults
      end
    rescue
      _ -> defaults
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp flash_saved(socket) do
    Process.send_after(self(), :clear_flash, 1500)
    assign(socket, :saved_flash, true)
  end

  defp safe_mode_atom(mode) when is_binary(mode) do
    case mode do
      "always_modal" -> :always_modal
      "toast_actions" -> :toast_actions
      "toast_click" -> :toast_click
      _ -> @default_display_mode
    end
  end

  defp safe_mode_atom(mode) when is_atom(mode) and mode in @valid_display_modes, do: mode
  defp safe_mode_atom(_), do: @default_display_mode

  defp to_atom(v, _default) when is_atom(v) and not is_nil(v), do: v

  defp to_atom(v, default) when is_binary(v) do
    case v do
      "automatic" -> :automatic
      "manual" -> :manual
      "auto" -> :auto
      "strict" -> :strict
      "off" -> :off
      _ -> default
    end
  end

  defp to_atom(_, default), do: default

  defp safe_int(v, default) do
    case Integer.parse(to_string(v)) do
      {n, _} -> n
      _ -> default
    end
  end

  defp safe_list_rules do
    try do
      PolicyRulesStore.list_rules()
    rescue
      _ -> []
    end
  end

  defp notify_apm(title, message) do
    Task.start(fn ->
      try do
        body =
          Jason.encode!(%{
            type: "info",
            title: title,
            message: message,
            category: "agentlock",
            agent_id: "claude-opus-4-7"
          })

        :httpc.request(
          :post,
          {~c"http://localhost:3032/api/notify", [], ~c"application/json", body},
          [{:timeout, 1500}],
          []
        )
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end)
  end
end
