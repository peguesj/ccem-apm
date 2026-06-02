defmodule ApmWeb.Hooks.PendingCountHook do
  @moduledoc """
  Shared on_mount hook that wires the live pending-decision count into every
  LiveView's assigns as `@pending_count`.

  Subscribes to the `agentlock:pending` PubSub topic on connect. Each broadcast
  increments/decrements the count so the PageShell bell badge stays in sync
  across all sections without each LiveView needing its own subscription.

  Usage in router.ex live_session:
    on_mount: [{ApmWeb.Hooks.PendingCountHook, :default}]
  """

  import Phoenix.LiveView
  import Phoenix.Component, only: [assign: 2]

  @pubsub_topic "agentlock:pending"

  def on_mount(:default, _params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Apm.PubSub, @pubsub_topic)
    end

    count = fetch_pending_count()

    socket =
      socket
      |> assign(pending_count: count)
      |> attach_hook(:pending_count_updater, :handle_info, &handle_pending_info/2)

    {:cont, socket}
  end

  defp handle_pending_info({:agentlock_pending, _payload}, socket) do
    {:halt, assign(socket, pending_count: fetch_pending_count())}
  end

  defp handle_pending_info({:approval_pending, _payload}, socket) do
    {:halt, assign(socket, pending_count: fetch_pending_count())}
  end

  defp handle_pending_info({:approval_decided, _payload}, socket) do
    {:halt, assign(socket, pending_count: fetch_pending_count())}
  end

  defp handle_pending_info(_msg, socket), do: {:cont, socket}

  defp fetch_pending_count do
    try do
      Apm.Decisions.pending(%{}) |> length()
    rescue
      _ -> 0
    catch
      _, _ -> 0
    end
  end
end
