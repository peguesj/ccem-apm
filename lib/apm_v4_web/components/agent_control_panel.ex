defmodule ApmV4Web.Components.AgentControlPanel do
  @moduledoc """
  Control bar above chat in inspector with Connect/Disconnect/Restart buttons.
  Formation-level controls. Calls POST /api/v2/agents/:id/control.
  Status indicator via PubSub. Confirmation for destructive actions.
  """

  use Phoenix.Component

  attr :selected_agent, :any, default: nil
  attr :agent_status, :string, default: "unknown"

  def control_bar(assigns) do
    ~H"""
    <div :if={@selected_agent} class="px-2 py-1.5 bg-base-300/70 border-b border-base-300 flex items-center gap-1.5">
      <%!-- Status indicator --%>
      <div class="flex items-center gap-1 mr-auto">
        <span class={[
          "w-2 h-2 rounded-full",
          status_dot_class(@agent_status)
        ]}></span>
        <span class="text-[10px] text-base-content/50">{@agent_status}</span>
      </div>

      <%!-- Control buttons --%>
      <button
        :if={@agent_status in ["offline", "idle", "error"]}
        phx-click="agent:control"
        phx-value-action="connect"
        phx-value-id={@selected_agent.id}
        class="btn btn-xs btn-success btn-outline gap-0.5"
        title="Connect agent"
      >
        <svg xmlns="http://www.w3.org/2000/svg" class="h-3 w-3" viewBox="0 0 20 20" fill="currentColor">
          <path fill-rule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zM9.555 7.168A1 1 0 008 8v4a1 1 0 001.555.832l3-2a1 1 0 000-1.664l-3-2z" clip-rule="evenodd" />
        </svg>
        Connect
      </button>

      <button
        :if={@agent_status == "active"}
        phx-click="agent:control"
        phx-value-action="disconnect"
        phx-value-id={@selected_agent.id}
        class="btn btn-xs btn-warning btn-outline gap-0.5"
        data-confirm="Disconnect this agent?"
        title="Disconnect agent"
      >
        <svg xmlns="http://www.w3.org/2000/svg" class="h-3 w-3" viewBox="0 0 20 20" fill="currentColor">
          <path fill-rule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zM8 7a1 1 0 00-1 1v4a1 1 0 001 1h4a1 1 0 001-1V8a1 1 0 00-1-1H8z" clip-rule="evenodd" />
        </svg>
        Disconnect
      </button>

      <button
        phx-click="agent:control"
        phx-value-action="restart"
        phx-value-id={@selected_agent.id}
        class="btn btn-xs btn-info btn-outline gap-0.5"
        data-confirm="Restart this agent?"
        title="Restart agent"
      >
        <svg xmlns="http://www.w3.org/2000/svg" class="h-3 w-3" viewBox="0 0 20 20" fill="currentColor">
          <path fill-rule="evenodd" d="M4 2a1 1 0 011 1v2.101a7.002 7.002 0 0111.601 2.566 1 1 0 11-1.885.666A5.002 5.002 0 005.999 7H9a1 1 0 010 2H4a1 1 0 01-1-1V3a1 1 0 011-1zm.008 9.057a1 1 0 011.276.61A5.002 5.002 0 0014.001 13H11a1 1 0 110-2h5a1 1 0 011 1v5a1 1 0 11-2 0v-2.101a7.002 7.002 0 01-11.601-2.566 1 1 0 01.61-1.276z" clip-rule="evenodd" />
        </svg>
        Restart
      </button>

      <%!-- Formation-level controls --%>
      <div :if={@selected_agent[:formation_id]} class="dropdown dropdown-end">
        <button tabindex="0" class="btn btn-xs btn-ghost gap-0.5">
          <svg xmlns="http://www.w3.org/2000/svg" class="h-3 w-3" viewBox="0 0 20 20" fill="currentColor">
            <path d="M6 10a2 2 0 11-4 0 2 2 0 014 0zM12 10a2 2 0 11-4 0 2 2 0 014 0zM16 12a2 2 0 100-4 2 2 0 000 4z" />
          </svg>
        </button>
        <ul tabindex="0" class="dropdown-content z-10 menu p-1 shadow bg-base-200 rounded-lg w-40 text-xs">
          <li>
            <button
              phx-click="formation:control"
              phx-value-action="restart"
              phx-value-id={@selected_agent[:formation_id]}
              data-confirm="Restart entire formation?"
            >
              Restart Formation
            </button>
          </li>
          <li>
            <button
              phx-click="formation:control"
              phx-value-action="stop"
              phx-value-id={@selected_agent[:formation_id]}
              data-confirm="Cancel entire formation?"
              class="text-error"
            >
              Cancel Formation
            </button>
          </li>
        </ul>
      </div>
    </div>
    """
  end

  defp status_dot_class("active"), do: "bg-success animate-pulse"
  defp status_dot_class("idle"), do: "bg-warning"
  defp status_dot_class("error"), do: "bg-error"
  defp status_dot_class("offline"), do: "bg-base-content/20"
  defp status_dot_class(_), do: "bg-base-content/20"
end
