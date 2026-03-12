defmodule ApmV5.SessionParser do
  @moduledoc """
  Parses Claude Code session JSONL files to extract metrics.

  Ported from the Python APM's `get_agent_output_stats` function.
  Each line in a session JSONL file is a JSON object with fields like
  `type`, `message`, and `timestamp`. This module extracts token usage,
  tool call counts, session duration, and conversation turns.
  """

  require Logger

  @type metrics :: %{
          tokens: %{input: non_neg_integer(), output: non_neg_integer()},
          tools: %{String.t() => non_neg_integer()},
          duration_seconds: non_neg_integer(),
          turns: non_neg_integer()
        }

  @zero_metrics %{
    tokens: %{input: 0, output: 0},
    tools: %{},
    skills: %{},
    duration_seconds: 0,
    turns: 0
  }

  @doc """
  Parses a JSONL session file at the given path and returns extracted metrics.

  Returns a map with:
  - `:tokens` - `%{input: integer, output: integer}` total token counts
  - `:tools` - `%{tool_name => count}` tool usage counts
  - `:duration_seconds` - elapsed seconds from first to last message timestamp
  - `:turns` - number of user messages (conversation turns)

  Handles missing files, empty files, and malformed lines gracefully.
  """
  @spec parse_jsonl(String.t()) :: metrics()
  def parse_jsonl(path) do
    case File.exists?(path) do
      false ->
        @zero_metrics

      true ->
        case File.read(path) do
          {:ok, ""} ->
            @zero_metrics

          {:ok, content} ->
            parse_content(content)

          {:error, reason} ->
            Logger.warning("SessionParser: failed to read #{path}: #{inspect(reason)}")
            @zero_metrics
        end
    end
  end

  defp parse_content(content) do
    lines = String.split(content, "\n", trim: true)

    acc = %{
      input_tokens: 0,
      output_tokens: 0,
      tools: %{},
      skills: %{},
      turns: 0,
      first_timestamp: nil,
      last_timestamp: nil
    }

    result =
      Enum.reduce(lines, acc, fn line, acc ->
        case Jason.decode(line) do
          {:ok, entry} ->
            process_entry(entry, acc)

          {:error, _reason} ->
            Logger.warning("SessionParser: skipping malformed JSONL line")
            acc
        end
      end)

    duration =
      case {result.first_timestamp, result.last_timestamp} do
        {nil, _} -> 0
        {_, nil} -> 0
        {first, last} -> compute_duration(first, last)
      end

    %{
      tokens: %{input: result.input_tokens, output: result.output_tokens},
      tools: result.tools,
      skills: result.skills,
      duration_seconds: duration,
      turns: result.turns
    }
  end

  defp process_entry(entry, acc) do
    timestamp = entry["timestamp"]
    acc = update_timestamps(acc, timestamp)

    message = entry["message"]

    cond do
      not is_map(message) ->
        acc

      message["role"] == "user" ->
        process_user_message(message, acc)

      message["role"] == "assistant" ->
        process_assistant_message(message, acc)

      true ->
        acc
    end
  end

  defp update_timestamps(acc, nil), do: acc

  defp update_timestamps(acc, timestamp) when is_binary(timestamp) do
    first = if acc.first_timestamp == nil, do: timestamp, else: min(acc.first_timestamp, timestamp)
    last = if acc.last_timestamp == nil, do: timestamp, else: max(acc.last_timestamp, timestamp)
    %{acc | first_timestamp: first, last_timestamp: last}
  end

  defp update_timestamps(acc, _), do: acc

  defp process_user_message(message, acc) do
    content = message["content"]

    # Count as a turn only if content is a plain string (actual user input)
    # or a list containing user text (not just tool_result blocks)
    turns_increment =
      cond do
        is_binary(content) and content != "" -> 1
        is_list(content) -> if has_user_text?(content), do: 1, else: 0
        true -> 0
      end

    # Count tool_result blocks in user messages (tool results returned to assistant)
    tool_results =
      if is_list(content) do
        Enum.count(content, fn
          %{"type" => "tool_result"} -> true
          _ -> false
        end)
      else
        0
      end

    acc = %{acc | turns: acc.turns + turns_increment}

    # Tool results in user messages indicate tool calls that completed
    # But we already count tool_use in assistant messages, so we skip counting here
    # to avoid double-counting. The Python version counts both, but the acceptance
    # criteria says "Counts tool_use blocks by tool name" which refers to assistant-side.
    _tool_results = tool_results
    acc
  end

  defp has_user_text?(content) when is_list(content) do
    Enum.any?(content, fn
      %{"type" => "text", "text" => text} when is_binary(text) and text != "" -> true
      _ -> false
    end)
  end

  defp process_assistant_message(message, acc) do
    # Extract token usage
    usage = message["usage"] || %{}
    input = (usage["input_tokens"] || 0) + (usage["cache_creation_input_tokens"] || 0) + (usage["cache_read_input_tokens"] || 0)
    output = usage["output_tokens"] || 0

    acc = %{
      acc
      | input_tokens: acc.input_tokens + input,
        output_tokens: acc.output_tokens + output
    }

    # Count tool_use blocks by tool name
    content = message["content"]

    if is_list(content) do
      Enum.reduce(content, acc, fn
        %{"type" => "tool_use", "name" => "Skill", "input" => %{"skill" => skill_name}}, acc
        when is_binary(skill_name) ->
          tools = acc.tools
                  |> Map.update("Skill", 1, &(&1 + 1))
                  |> Map.update("skill:#{skill_name}", 1, &(&1 + 1))
          skills = Map.update(acc.skills, skill_name, 1, &(&1 + 1))
          %{acc | tools: tools, skills: skills}

        %{"type" => "tool_use", "name" => name}, acc when is_binary(name) ->
          tools = Map.update(acc.tools, name, 1, &(&1 + 1))
          %{acc | tools: tools}

        _, acc ->
          acc
      end)
    else
      acc
    end
  end

  defp compute_duration(first, last) do
    with {:ok, first_dt, _} <- DateTime.from_iso8601(first),
         {:ok, last_dt, _} <- DateTime.from_iso8601(last) do
      DateTime.diff(last_dt, first_dt, :second) |> max(0)
    else
      _ -> 0
    end
  end
end
