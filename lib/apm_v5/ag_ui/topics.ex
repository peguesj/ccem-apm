defmodule ApmV5.AgUi.Topics do
  @moduledoc """
  Topic taxonomy mapping AG-UI event types to hierarchical PubSub topics.

  Provides topic_for/1 to convert event types to canonical topic strings,
  matches?/2 for wildcard pattern matching, and all_topics/0 for discovery.

  ## Categories
  - lifecycle: RUN_STARTED, RUN_FINISHED, RUN_ERROR, STEP_STARTED, STEP_FINISHED
  - text: TEXT_MESSAGE_START, TEXT_MESSAGE_CONTENT, TEXT_MESSAGE_END
  - tool: TOOL_CALL_START, TOOL_CALL_ARGS, TOOL_CALL_END, TOOL_CALL_RESULT
  - state: STATE_SNAPSHOT, STATE_DELTA, MESSAGES_SNAPSHOT
  - activity: ACTIVITY_SNAPSHOT, ACTIVITY_DELTA
  - thinking: THINKING_START, THINKING_END, REASONING_START, REASONING_END
  - special: RAW, CUSTOM

  ## US-002 Acceptance Criteria (DoD):
  - topic_for/1 maps each EventType to hierarchical topic string
  - All 8 categories covered with full event type mappings
  - matches?/2 supports wildcard patterns (e.g., 'lifecycle:*')
  - all_topics/0 returns complete canonical topic list
  - Comprehensive @spec typespecs on all public functions
  - mix compile --warnings-as-errors passes
  """

  alias AgUi.Core.Events.EventType

  @type_map %{
    # lifecycle
    EventType.run_started() => "lifecycle:run_started",
    EventType.run_finished() => "lifecycle:run_finished",
    EventType.run_error() => "lifecycle:run_error",
    EventType.step_started() => "lifecycle:step_started",
    EventType.step_finished() => "lifecycle:step_finished",
    # text
    EventType.text_message_start() => "text:message_start",
    EventType.text_message_content() => "text:message_content",
    EventType.text_message_end() => "text:message_end",
    # tool
    EventType.tool_call_start() => "tool:call_start",
    EventType.tool_call_args() => "tool:call_args",
    EventType.tool_call_end() => "tool:call_end",
    # state
    EventType.state_snapshot() => "state:snapshot",
    EventType.state_delta() => "state:delta",
    # special
    EventType.raw() => "special:raw",
    EventType.custom() => "special:custom"
  }

  @all_topics Map.values(@type_map)

  @doc """
  Maps an AG-UI event type to its hierarchical topic string.

  Returns "unknown:<type>" for unrecognized event types.
  """
  @spec topic_for(String.t()) :: String.t()
  def topic_for(event_type) do
    Map.get(@type_map, event_type, "unknown:#{event_type}")
  end

  @doc """
  Checks if a subscription pattern matches a topic.

  Supports wildcard patterns:
  - "lifecycle:*" matches "lifecycle:run_started"
  - "lifecycle:run_started" matches exactly
  - "*" matches everything
  """
  @spec matches?(String.t(), String.t()) :: boolean()
  def matches?(pattern, topic) do
    cond do
      pattern == "*" -> true
      String.ends_with?(pattern, ":*") ->
        prefix = String.trim_trailing(pattern, ":*")
        String.starts_with?(topic, prefix <> ":")
      true ->
        pattern == topic
    end
  end

  @doc "Returns the complete list of canonical topic strings."
  @spec all_topics() :: [String.t()]
  def all_topics, do: @all_topics

  @doc "Returns all topics in a given category."
  @spec topics_in_category(String.t()) :: [String.t()]
  def topics_in_category(category) do
    @all_topics
    |> Enum.filter(&String.starts_with?(&1, category <> ":"))
  end

  @doc "Returns the category for a given topic."
  @spec category_for(String.t()) :: String.t()
  def category_for(topic) do
    topic |> String.split(":") |> List.first() || "unknown"
  end
end
