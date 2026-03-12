defmodule ApmV5Web.A2ALive do
  @moduledoc """
  A2A messaging monitor LiveView at /a2a.

  ## US-035 Acceptance Criteria (DoD):
  - Route at /a2a shows A2A dashboard
  - Real-time message feed via EventBus subscription
  - Queue depth per agent
  - Router statistics (sent/delivered/expired)
  - Message history with correlation tracking
  - Send test message form
  - mix compile --warnings-as-errors passes
  """

  use ApmV5Web, :live_view

  alias ApmV5.AgUi.A2A.Router
  alias ApmV5.AgUi.EventBus

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      EventBus.subscribe("a2a:*")
      EventBus.subscribe("special:custom")
      :timer.send_interval(5_000, self(), :refresh)
    end

    {:ok,
     socket
     |> assign(:page_title, "A2A Messaging")
     |> assign(:stats, safe_stats())
     |> assign(:recent_messages, [])
     |> assign(:send_form, %{"to_agent" => "", "from_agent" => "", "message_type" => "ping", "payload" => "{}"})}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, assign(socket, :stats, safe_stats())}
  end

  def handle_info({:event_bus, _topic, event}, socket) do
    recent = Enum.take([event | socket.assigns.recent_messages], 50)

    {:noreply,
     socket
     |> assign(:recent_messages, recent)
     |> assign(:stats, safe_stats())}
  end

  @impl true
  def handle_event("send_test", params, socket) do
    payload =
      case Jason.decode(params["payload"] || "{}") do
        {:ok, p} -> p
        _ -> %{}
      end

    attrs = %{
      from_agent_id: params["from_agent"],
      to: {:agent, params["to_agent"]},
      message_type: params["message_type"] || "test",
      payload: payload
    }

    case Router.send(attrs) do
      {:ok, _id} ->
        {:noreply, put_flash(socket, :info, "Message sent")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Send failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-6 space-y-6">
      <div class="flex items-center justify-between">
        <h1 class="text-2xl font-bold text-base-content">A2A Messaging</h1>
        <div class="badge badge-primary badge-lg">Agent-to-Agent</div>
      </div>

      <%!-- Stats Cards --%>
      <div class="grid grid-cols-1 md:grid-cols-4 gap-4">
        <div class="stat bg-base-200 rounded-box">
          <div class="stat-title">Sent</div>
          <div class="stat-value text-primary"><%= @stats[:sent_count] || 0 %></div>
        </div>
        <div class="stat bg-base-200 rounded-box">
          <div class="stat-title">Delivered</div>
          <div class="stat-value text-success"><%= @stats[:delivered_count] || 0 %></div>
        </div>
        <div class="stat bg-base-200 rounded-box">
          <div class="stat-title">Expired</div>
          <div class="stat-value text-warning"><%= @stats[:expired_count] || 0 %></div>
        </div>
        <div class="stat bg-base-200 rounded-box">
          <div class="stat-title">Queues</div>
          <div class="stat-value text-info"><%= map_size(@stats[:queue_depths] || %{}) %></div>
        </div>
      </div>

      <%!-- Queue Depths --%>
      <div class="card bg-base-200 shadow-sm">
        <div class="card-body">
          <h2 class="card-title">Queue Depths</h2>
          <%= if map_size(@stats[:queue_depths] || %{}) > 0 do %>
            <div class="overflow-x-auto">
              <table class="table table-sm">
                <thead>
                  <tr>
                    <th>Agent ID</th>
                    <th>Pending Messages</th>
                  </tr>
                </thead>
                <tbody>
                  <%= for {agent_id, depth} <- @stats[:queue_depths] || %{} do %>
                    <tr>
                      <td class="font-mono text-sm"><%= agent_id %></td>
                      <td><span class="badge badge-ghost"><%= depth %></span></td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          <% else %>
            <p class="text-base-content/50">No active queues</p>
          <% end %>
        </div>
      </div>

      <%!-- Send Test Message --%>
      <div class="card bg-base-200 shadow-sm">
        <div class="card-body">
          <h2 class="card-title">Send Test Message</h2>
          <form phx-submit="send_test" class="grid grid-cols-1 md:grid-cols-2 gap-4">
            <div class="form-control">
              <label class="label"><span class="label-text">From Agent ID</span></label>
              <input type="text" name="from_agent" value={@send_form["from_agent"]}
                     class="input input-bordered input-sm" placeholder="agent-001" />
            </div>
            <div class="form-control">
              <label class="label"><span class="label-text">To Agent ID</span></label>
              <input type="text" name="to_agent" value={@send_form["to_agent"]}
                     class="input input-bordered input-sm" placeholder="agent-002" />
            </div>
            <div class="form-control">
              <label class="label"><span class="label-text">Message Type</span></label>
              <input type="text" name="message_type" value={@send_form["message_type"]}
                     class="input input-bordered input-sm" placeholder="ping" />
            </div>
            <div class="form-control">
              <label class="label"><span class="label-text">Payload (JSON)</span></label>
              <input type="text" name="payload" value={@send_form["payload"]}
                     class="input input-bordered input-sm" placeholder="{}" />
            </div>
            <div class="col-span-full">
              <button type="submit" class="btn btn-primary btn-sm">Send Message</button>
            </div>
          </form>
        </div>
      </div>

      <%!-- Recent Messages Feed --%>
      <div class="card bg-base-200 shadow-sm">
        <div class="card-body">
          <h2 class="card-title">Recent Messages (<%= length(@recent_messages) %>)</h2>
          <div class="space-y-2 max-h-96 overflow-y-auto">
            <%= for msg <- @recent_messages do %>
              <div class="bg-base-100 rounded-lg p-3 text-sm">
                <div class="flex items-center gap-2 mb-1">
                  <span class="badge badge-xs badge-primary"><%= msg[:name] || msg[:type] || "a2a" %></span>
                  <span class="text-base-content/50 font-mono text-xs">
                    <%= if msg[:value][:id], do: String.slice(msg[:value][:id] || "", 0..7), else: "—" %>
                  </span>
                </div>
                <pre class="text-xs overflow-x-auto"><%= Jason.encode!(msg[:value] || msg, pretty: true) %></pre>
              </div>
            <% end %>
            <%= if @recent_messages == [] do %>
              <p class="text-base-content/50">No messages yet. Send a test message or wait for agent activity.</p>
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp safe_stats do
    try do
      Router.stats()
    rescue
      _ -> %{sent_count: 0, delivered_count: 0, expired_count: 0, queue_depths: %{}}
    end
  end
end
