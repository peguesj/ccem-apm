defmodule ApmV5.AgUi.Topics do
  @moduledoc """
  Topic taxonomy mapping AG-UI event types to hierarchical PubSub topics.

  Provides topic_for/1 to convert event types to canonical topic strings,
  matches?/2 for wildcard pattern matching, and all_topics/0 for discovery.

  ## Categories
  - lifecycle: RUN_STARTED, RUN_FINISHED, RUN_ERROR, STEP_STARTED, STEP_FINISHED
  - text: TEXT_MESSAGE_START, TEXT_MESSAGE_CONTENT, TEXT_MESSAGE_END, TEXT_MESSAGE_CHUNK
  - thinking_text: THINKING_TEXT_MESSAGE_START/CONTENT/END
  - tool: TOOL_CALL_START, TOOL_CALL_ARGS, TOOL_CALL_END, TOOL_CALL_CHUNK, TOOL_CALL_RESULT
  - thinking: THINKING_START, THINKING_END
  - state: STATE_SNAPSHOT, STATE_DELTA, MESSAGES_SNAPSHOT
  - activity: ACTIVITY_SNAPSHOT, ACTIVITY_DELTA
  - reasoning: REASONING_START/END/MESSAGE_START/CONTENT/END/CHUNK/ENCRYPTED_VALUE
  - special: RAW, CUSTOM

  ## Acceptance Criteria (DoD):
  - topic_for/1 maps ALL 33 EventType values to hierarchical topic strings
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
    EventType.text_message_chunk() => "text:message_chunk",
    # thinking text
    EventType.thinking_text_message_start() => "thinking_text:message_start",
    EventType.thinking_text_message_content() => "thinking_text:message_content",
    EventType.thinking_text_message_end() => "thinking_text:message_end",
    # tool
    EventType.tool_call_start() => "tool:call_start",
    EventType.tool_call_args() => "tool:call_args",
    EventType.tool_call_end() => "tool:call_end",
    EventType.tool_call_chunk() => "tool:call_chunk",
    EventType.tool_call_result() => "tool:call_result",
    # thinking
    EventType.thinking_start() => "thinking:start",
    EventType.thinking_end() => "thinking:end",
    # state
    EventType.state_snapshot() => "state:snapshot",
    EventType.state_delta() => "state:delta",
    EventType.messages_snapshot() => "state:messages_snapshot",
    # activity
    EventType.activity_snapshot() => "activity:snapshot",
    EventType.activity_delta() => "activity:delta",
    # reasoning
    EventType.reasoning_start() => "reasoning:start",
    EventType.reasoning_message_start() => "reasoning:message_start",
    EventType.reasoning_message_content() => "reasoning:message_content",
    EventType.reasoning_message_end() => "reasoning:message_end",
    EventType.reasoning_message_chunk() => "reasoning:message_chunk",
    EventType.reasoning_end() => "reasoning:end",
    EventType.reasoning_encrypted_value() => "reasoning:encrypted_value",
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

  @doc "Returns all unique categories."
  @spec all_categories() :: [String.t()]
  def all_categories do
    @all_topics |> Enum.map(&category_for/1) |> Enum.uniq() |> Enum.sort()
  end
end
