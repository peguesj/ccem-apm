defmodule Apm.Auth.ApprovalQueue do
  @moduledoc """
  Debouncing queue for approval requests. Collects incoming entries over a
  200ms window, then broadcasts a single `{:approval_batch, entries}` message
  via PubSub. This replaces per-request notification spam with grouped bursts.
  """
  use GenServer
  require Logger

  @debounce_ms 200

  # ── Public API ───────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec enqueue(map()) :: :ok
  def enqueue(entry) do
    GenServer.cast(__MODULE__, {:enqueue, entry})
  end

  # ── GenServer callbacks ──────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    {:ok, %{buffer: [], timer_ref: nil}}
  end

  @impl true
  def handle_cast({:enqueue, entry}, state) do
    # Cancel existing debounce timer if any
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)

    timer_ref = Process.send_after(self(), :flush, @debounce_ms)
    {:noreply, %{state | buffer: [entry | state.buffer], timer_ref: timer_ref}}
  end

  @impl true
  def handle_info(:flush, state) do
    entries = Enum.reverse(state.buffer)

    if entries != [] do
      Logger.debug("[ApprovalQueue] Flushing batch of #{length(entries)} approval requests")

      Phoenix.PubSub.broadcast(
        Apm.PubSub,
        "agentlock:pending",
        {:approval_batch, entries}
      )
    end

    {:noreply, %{state | buffer: [], timer_ref: nil}}
  end
end
