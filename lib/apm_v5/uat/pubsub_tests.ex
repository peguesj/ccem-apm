defmodule ApmV5.Uat.PubSubTests do
  @moduledoc """
  UAT test suite for PubSub topics and Phoenix Channel modules.

  PubSub tests (PS-001 .. PS-016): subscribe to each topic, broadcast a
  tagged test message, and assert receipt within 500 ms.

  Channel tests (CH-001 .. CH-003): verify channel modules are loaded and
  export `join/3`.
  """

  @behaviour ApmV5.Uat.TestSuite

  # --- Behaviour Callbacks ---

  @impl true
  def category, do: :pubsub

  @impl true
  def count, do: length(pubsub_topics()) + length(channel_modules())

  @impl true
  def run do
    pubsub_results = Enum.map(pubsub_topics(), fn {id, topic} -> test_pubsub(id, topic) end)
    channel_results = Enum.map(channel_modules(), fn {id, mod, topic} -> test_channel(id, mod, topic) end)
    pubsub_results ++ channel_results
  end

  # --- Test Catalogs ---

  defp pubsub_topics do
    [
      {"PS-001", "apm:agents"},
      {"PS-002", "apm:notifications"},
      {"PS-003", "apm:config"},
      {"PS-004", "apm:tasks"},
      {"PS-005", "apm:commands"},
      {"PS-006", "apm:metrics"},
      {"PS-007", "apm:alerts"},
      {"PS-008", "apm:slo"},
      {"PS-009", "apm:upm"},
      {"PS-010", "apm:workflows"},
      {"PS-011", "apm:verify"},
      {"PS-012", "apm:environments"},
      {"PS-013", "apm:conversations"},
      {"PS-014", "ag_ui:events"},
      {"PS-015", "intake:events"},
      {"PS-016", "dashboard:updates"}
    ]
  end

  defp channel_modules do
    [
      {"CH-001", ApmV5Web.AgentChannel, "agent:*"},
      {"CH-002", ApmV5Web.MetricsChannel, "metrics:live"},
      {"CH-003", ApmV5Web.AlertsChannel, "alerts:feed"}
    ]
  end

  # --- PubSub Test ---

  defp test_pubsub(id, topic) do
    start = System.monotonic_time(:millisecond)
    ref = make_ref()

    try do
      Phoenix.PubSub.subscribe(ApmV5.PubSub, topic)
      Phoenix.PubSub.broadcast(ApmV5.PubSub, topic, {:uat_ping, ref})

      receive do
        {:uat_ping, ^ref} ->
          Phoenix.PubSub.unsubscribe(ApmV5.PubSub, topic)
          result(:pass, id, topic, start, "Topic delivers messages")
      after
        500 ->
          Phoenix.PubSub.unsubscribe(ApmV5.PubSub, topic)
          result(:fail, id, topic, start, "No delivery within 500ms")
      end
    rescue
      e ->
        result(:fail, id, topic, start, "Error: #{Exception.message(e)}")
    end
  end

  # --- Channel Test ---

  defp test_channel(id, module, topic) do
    start = System.monotonic_time(:millisecond)

    try do
      if Code.ensure_loaded?(module) and function_exported?(module, :join, 3) do
        result(:pass, id, "#{inspect(module)} (#{topic})", start, "Module loaded, join/3 exported")
      else
        result(:fail, id, "#{inspect(module)} (#{topic})", start, "Module not loaded or join/3 missing")
      end
    rescue
      e ->
        result(:fail, id, "#{inspect(module)} (#{topic})", start, "Error: #{Exception.message(e)}")
    end
  end

  # --- Result Builder ---

  defp result(status, id, name, start, message) do
    elapsed = System.monotonic_time(:millisecond) - start
    category = if String.starts_with?(id, "CH-"), do: :channel, else: :pubsub

    %{
      id: id,
      category: category,
      name: name,
      status: status,
      duration_ms: elapsed,
      message: message,
      tested_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end
end
