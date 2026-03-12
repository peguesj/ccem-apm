defmodule ApmV4Web.Components.ScopeBreadcrumb do
  @moduledoc """
  Breadcrumb bar showing current scope path:
  All > Project > Formation > Squadron > Agent

  Clicking re-scopes chat and controls. Updates on node click in formation graph.
  """

  use Phoenix.Component

  attr :scope, :string, default: "global"
  attr :scope_path, :list, default: []

  def breadcrumb(assigns) do
    assigns = assign_new(assigns, :parsed_path, fn -> parse_scope(assigns.scope) end)

    ~H"""
    <nav class="px-2 py-1 bg-base-300/30 border-b border-base-300" aria-label="Scope navigation">
      <ol class="flex items-center gap-0.5 text-[11px]">
        <%!-- Root: All --%>
        <li>
          <button
            phx-click="scope:set"
            phx-value-scope="global"
            class={["hover:text-primary transition-colors", if(@scope == "global", do: "text-primary font-semibold", else: "text-base-content/50")]}
          >
            All
          </button>
        </li>

        <%= for {segment, idx} <- Enum.with_index(@parsed_path) do %>
          <li class="flex items-center gap-0.5">
            <span class="text-base-content/20">/</span>
            <button
              phx-click="scope:set"
              phx-value-scope={segment.scope}
              class={[
                "hover:text-primary transition-colors truncate max-w-[80px]",
                if(idx == length(@parsed_path) - 1, do: "text-primary font-semibold", else: "text-base-content/60")
              ]}
              title={segment.label}
            >
              <span class={["mr-0.5", scope_icon_class(segment.type)]}></span>
              {segment.label}
            </button>
          </li>
        <% end %>
      </ol>
    </nav>
    """
  end

  @doc "Parse a scope string into a breadcrumb path."
  @spec parse_scope(String.t()) :: [map()]
  def parse_scope("global"), do: []
  def parse_scope("all"), do: []

  def parse_scope("project:" <> project) do
    [%{type: :project, label: project, scope: "project:#{project}"}]
  end

  def parse_scope("formation:" <> formation_id) do
    [%{type: :formation, label: short_id(formation_id), scope: "formation:#{formation_id}"}]
  end

  def parse_scope("squadron:" <> squadron_id) do
    # Try to extract formation from squadron ID convention (fmt-xxx-alpha)
    parts = String.split(squadron_id, "-")
    formation_scope = if length(parts) >= 3, do: Enum.take(parts, 3) |> Enum.join("-"), else: nil

    path = if formation_scope do
      [%{type: :formation, label: short_id(formation_scope), scope: "formation:#{formation_scope}"}]
    else
      []
    end

    path ++ [%{type: :squadron, label: short_id(squadron_id), scope: "squadron:#{squadron_id}"}]
  end

  def parse_scope("agent:" <> agent_id) do
    [%{type: :agent, label: short_id(agent_id), scope: "agent:#{agent_id}"}]
  end

  def parse_scope(other), do: [%{type: :custom, label: other, scope: other}]

  defp short_id(id) when byte_size(id) > 12, do: String.slice(id, 0, 12) <> "..."
  defp short_id(id), do: id

  defp scope_icon_class(:project), do: "text-info"
  defp scope_icon_class(:formation), do: "text-warning"
  defp scope_icon_class(:squadron), do: "text-secondary"
  defp scope_icon_class(:agent), do: "text-success"
  defp scope_icon_class(_), do: ""
end
