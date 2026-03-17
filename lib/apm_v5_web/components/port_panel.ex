defmodule ApmV5Web.Components.PortPanel do
  @moduledoc """
  Port Manager panel component for DashboardLive.

  Extracted from DashboardLive (US-R14) as a reusable Phoenix functional component.
  Renders the Ports tab content: clash alerts, remediation suggestions, per-project
  port listings with active/inactive indicators, server type badges, and config file counts.

  Requires the parent LiveView to handle the `scan_ports` and `get_remediation` events.
  """

  use Phoenix.Component

  import ApmV5Web.CoreComponents, only: [icon: 1]

  attr :port_clashes, :list, required: true, doc: "List of port clash maps"
  attr :port_remediation, :any, default: nil, doc: "Optional remediation suggestion map"
  attr :project_configs, :map, required: true, doc: "Map of project_name => port config"

  @doc "Renders the Port Manager panel (Ports tab body)."
  def port_manager(assigns) do
    ~H"""
    <div :if={true} class="space-y-3">
      <div class="flex items-center justify-between">
        <h3 class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
          Port Manager
        </h3>
        <button phx-click="scan_ports" class="btn btn-xs btn-ghost text-primary">
          <.icon name="hero-arrow-path" class="size-3" /> Scan
        </button>
      </div>

      <%!-- Clash alerts --%>
      <div :if={@port_clashes != []} class="space-y-1">
        <div class="text-[10px] uppercase tracking-wider text-error/70 font-semibold">Clashes</div>
        <div :for={clash <- @port_clashes} class="p-2 rounded bg-error/10 border border-error/20 text-xs">
          <div class="flex items-center gap-2 mb-1">
            <span class="font-mono font-bold text-error">:{clash.port}</span>
            <span class="text-base-content/50">{Enum.join(clash.projects, " + ")}</span>
          </div>
          <button phx-click="get_remediation" phx-value-port={clash.port}
            class="text-[10px] text-primary hover:underline">
            Suggest fix
          </button>
        </div>
      </div>

      <%!-- Remediation suggestion --%>
      <div :if={@port_remediation} class="p-2 rounded bg-info/10 border border-info/20 text-xs space-y-1">
        <div class="font-semibold text-info">Remediation for :{@port_remediation.port}</div>
        <div class="text-base-content/60">{@port_remediation.recommendation}</div>
        <div :if={@port_remediation.alternatives != []} class="flex gap-1 mt-1">
          <span class="text-[10px] text-base-content/40">Available:</span>
          <span :for={alt <- @port_remediation.alternatives} class="badge badge-xs badge-ghost font-mono">{alt}</span>
        </div>
      </div>

      <%!-- Project configs --%>
      <div :for={{name, config} <- Enum.sort_by(@project_configs, fn {n, _} -> n end)} class="space-y-1">
        <div class="flex items-center justify-between">
          <span class="text-xs font-semibold text-base-content/80">{name}</span>
          <span class={["badge badge-xs", stack_badge(config.stack)]}>{config.stack}</span>
        </div>
        <div class="p-2 rounded bg-base-300 text-[10px] space-y-1">
          <div class="text-base-content/40 font-mono truncate" title={config.root}>
            {Path.basename(config.root)}
          </div>
          <%!-- Ports --%>
          <div :for={port_info <- config.ports} class="space-y-0.5">
            <div class="flex items-center gap-2">
              <span class={["w-1.5 h-1.5 rounded-full", if(port_info[:active], do: "bg-success", else: "bg-base-content/20")]}></span>
              <span class="font-mono font-bold">:{port_info.port}</span>
              <span class={["badge badge-xs", ns_badge(port_info.namespace)]}>{port_info.namespace}</span>
              <span :if={port_info[:server_type] && port_info[:server_type] != :unknown}
                class={["badge badge-xs", server_type_badge(port_info[:server_type])]}>
                {port_info[:server_type]}
              </span>
              <span class="text-base-content/30 ml-auto">{port_info.file}</span>
            </div>
            <div :if={port_info[:active]} class="pl-4 text-[9px] text-base-content/30 space-y-0.5">
              <div :if={port_info[:cwd]} class="font-mono truncate" title={port_info[:cwd]}>
                cwd: {port_info[:cwd]}
              </div>
              <div :if={port_info[:full_command]} class="font-mono truncate" title={port_info[:full_command]}>
                cmd: {port_info[:full_command]}
              </div>
              <div :if={port_info[:pid]} class="font-mono">
                pid: {port_info[:pid]}
              </div>
            </div>
          </div>
          <div :if={config.ports == []} class="text-base-content/30">No ports detected</div>
          <%!-- Config files --%>
          <details class="mt-1">
            <summary class="text-base-content/30 cursor-pointer hover:text-base-content/50">
              {length(config.config_files)} config files
            </summary>
            <div class="mt-1 space-y-0.5 pl-2">
              <div :for={f <- config.config_files} class="text-base-content/40 font-mono">{f}</div>
            </div>
          </details>
        </div>
      </div>

      <div :if={@project_configs == %{}} class="text-xs text-base-content/40 py-4 text-center">
        No projects detected. Check ~/Developer/ccem/apm/sessions/
      </div>
    </div>
    """
  end

  # ============================
  # Private Badge Helpers
  # ============================

  @spec stack_badge(atom() | any()) :: String.t()
  defp stack_badge(:elixir), do: "badge-accent"
  defp stack_badge(:nextjs), do: "badge-info"
  defp stack_badge(:node), do: "badge-success"
  defp stack_badge(:python), do: "badge-warning"
  defp stack_badge(_), do: "badge-ghost"

  @spec ns_badge(atom() | any()) :: String.t()
  defp ns_badge(:web), do: "badge-info"
  defp ns_badge(:api), do: "badge-accent"
  defp ns_badge(:service), do: "badge-warning"
  defp ns_badge(:tool), do: "badge-success"
  defp ns_badge(_), do: "badge-ghost"

  @spec server_type_badge(atom() | any()) :: String.t()
  defp server_type_badge(:phoenix), do: "badge-accent"
  defp server_type_badge(:elixir), do: "badge-accent"
  defp server_type_badge(:nextjs), do: "badge-info"
  defp server_type_badge(:vite), do: "badge-primary"
  defp server_type_badge(:node), do: "badge-success"
  defp server_type_badge(:python_web), do: "badge-warning"
  defp server_type_badge(:postgres), do: "badge-secondary"
  defp server_type_badge(:redis), do: "badge-error"
  defp server_type_badge(_), do: "badge-ghost"
end
