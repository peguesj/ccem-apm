defmodule ApmV5.AgUi.A2A.Patterns do
  @moduledoc """
  A2A coordination patterns built on top of Envelope + Router.

  ## US-034 Acceptance Criteria (DoD):
  - request_reply/3: sends envelope, awaits response with matching correlation_id
  - broadcast/2: sends to :broadcast address
  - fan_out/3: sends to list of targets, collects results
  - Timeout handling for request_reply (default 30s)
  - mix compile --warnings-as-errors passes
  """

  alias ApmV5.AgUi.A2A.Router
  alias ApmV5.AgUi.EventBus

  @default_timeout 30_000

  @doc """
  Send a request and await a reply with matching correlation_id.

  Returns `{:ok, reply_envelope}` or `{:error, :timeout}`.
  """
  @spec request_reply(map(), String.t(), keyword()) :: {:ok, map()} | {:error, :timeout}
  def request_reply(attrs, from_agent_id, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    correlation_id = ApmV5.Correlation.generate()

    envelope_attrs =
      Map.merge(attrs, %{
        from_agent_id: from_agent_id,
        correlation_id: correlation_id,
        message_type: attrs[:message_type] || "request"
      })

    # Subscribe to replies on our agent's channel
    topic = "a2a:#{from_agent_id}"
    EventBus.subscribe(topic)

    case Router.send(envelope_attrs) do
      {:ok, _id} ->
        result = await_reply(correlation_id, timeout)
        EventBus.unsubscribe()
        result

      {:error, reason} ->
        EventBus.unsubscribe()
        {:error, reason}
    end
  end

  @doc """
  Broadcast a message to all registered agents.
  """
  @spec broadcast(map(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def broadcast(attrs, from_agent_id) do
    envelope_attrs =
      Map.merge(attrs, %{
        from_agent_id: from_agent_id,
        to: :broadcast,
        message_type: attrs[:message_type] || "broadcast"
      })

    Router.send(envelope_attrs)
  end

  @doc """
  Fan out a message to multiple specific agents and collect delivery confirmation.

  Returns `{:ok, %{sent: count, message_id: id}}`.
  """
  @spec fan_out(map(), String.t(), [String.t()]) ::
          {:ok, %{sent: non_neg_integer(), results: [map()]}}
          | {:error, term()}
  def fan_out(attrs, from_agent_id, target_agent_ids) when is_list(target_agent_ids) do
    results =
      Enum.map(target_agent_ids, fn agent_id ->
        envelope_attrs =
          Map.merge(attrs, %{
            from_agent_id: from_agent_id,
            to: {:agent, agent_id},
            message_type: attrs[:message_type] || "fan_out"
          })

        case Router.send(envelope_attrs) do
          {:ok, id} -> %{agent_id: agent_id, status: :delivered, message_id: id}
          {:error, reason} -> %{agent_id: agent_id, status: :failed, reason: reason}
        end
      end)

    sent_count = Enum.count(results, &(&1.status == :delivered))
    {:ok, %{sent: sent_count, results: results}}
  end

  # -- Private ----------------------------------------------------------------

  defp await_reply(correlation_id, timeout) do
    receive do
      {:event_bus, _topic, %{value: %{correlation_id: ^correlation_id}} = event} ->
        {:ok, event.value}

      {:event_bus, _topic, %{value: %{"correlation_id" => ^correlation_id}} = event} ->
        {:ok, event.value}
    after
      timeout -> {:error, :timeout}
    end
  end
end
