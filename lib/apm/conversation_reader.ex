defmodule Apm.ConversationReader do
  @moduledoc """
  GenServer that reads and parses `.jsonl` conversation files from `~/.claude/projects/`.

  Provides on-demand reading of conversation messages, tool calls, and session
  correlation. Lightweight — reads files on demand without caching entire conversations.
  Tracks file offsets for efficient live-tail polling.
  """
  use GenServer
  require Logger

  @type message :: %{
          type: String.t(),
          role: String.t() | nil,
          content: String.t() | nil,
          timestamp: String.t() | nil,
          session_id: String.t() | nil,
          agent_id: String.t() | nil,
          cwd: String.t() | nil,
          tool_calls: [map()],
          tool_results: [map()],
          usage: map() | nil,
          raw_type: String.t()
        }

  # ── Client API ──────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Read all messages from a .jsonl file. Opts: `:limit` to cap results."
  @spec read_conversation(String.t(), keyword()) :: {:ok, [message()]} | {:error, term()}
  def read_conversation(file_path, opts \\ []) do
    GenServer.call(__MODULE__, {:read_conversation, file_path, opts}, 15_000)
  end

  @doc "Read the last N messages from a .jsonl file (tail)."
  @spec read_recent(String.t(), pos_integer()) :: {:ok, [message()]} | {:error, term()}
  def read_recent(file_path, limit \\ 50) do
    GenServer.call(__MODULE__, {:read_recent, file_path, limit}, 15_000)
  end

  @doc """
  Find all .jsonl files in a project directory and group by `cwd` to identify
  related sessions (main + subagents + claude-mem observers).
  """
  @spec correlate_sessions(String.t()) :: {:ok, map()} | {:error, term()}
  def correlate_sessions(project_dir) do
    GenServer.call(__MODULE__, {:correlate_sessions, project_dir}, 15_000)
  end

  @doc """
  Read new lines from a file starting at the given byte offset.
  Returns `{:ok, new_messages, new_offset}`.
  """
  @spec read_from_offset(String.t(), non_neg_integer()) ::
          {:ok, [message()], non_neg_integer()} | {:error, term()}
  def read_from_offset(file_path, offset) do
    GenServer.call(__MODULE__, {:read_from_offset, file_path, offset}, 15_000)
  end

  @doc "Get the current file size (for offset tracking initialization)."
  @spec file_size(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def file_size(file_path) do
    case File.stat(file_path) do
      {:ok, %{size: size}} -> {:ok, size}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Find related sessions for a given conversation file path."
  @spec find_related(String.t()) :: {:ok, [map()]} | {:error, term()}
  def find_related(file_path) do
    GenServer.call(__MODULE__, {:find_related, file_path}, 15_000)
  end

  # ── GenServer callbacks ─────────────────────────────────────────────

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_call({:read_conversation, file_path, opts}, _from, state) do
    result = do_read_conversation(file_path, opts)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:read_recent, file_path, limit}, _from, state) do
    result = do_read_recent(file_path, limit)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:correlate_sessions, project_dir}, _from, state) do
    result = do_correlate_sessions(project_dir)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:read_from_offset, file_path, offset}, _from, state) do
    result = do_read_from_offset(file_path, offset)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:find_related, file_path}, _from, state) do
    result = do_find_related(file_path)
    {:reply, result, state}
  end

  # ── Private implementation ──────────────────────────────────────────

  defp do_read_conversation(file_path, opts) do
    limit = Keyword.get(opts, :limit, :infinity)

    case File.read(file_path) do
      {:ok, data} ->
        messages =
          data
          |> String.split("\n", trim: true)
          |> maybe_limit(limit)
          |> Enum.map(&parse_line/1)
          |> Enum.reject(&is_nil/1)

        {:ok, messages}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_read_recent(file_path, limit) do
    case File.read(file_path) do
      {:ok, data} ->
        messages =
          data
          |> String.split("\n", trim: true)
          |> Enum.reverse()
          |> Enum.take(limit)
          |> Enum.reverse()
          |> Enum.map(&parse_line/1)
          |> Enum.reject(&is_nil/1)

        {:ok, messages}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_read_from_offset(file_path, offset) do
    case File.stat(file_path) do
      {:ok, %{size: size}} when size > offset ->
        case File.open(file_path, [:read, :binary]) do
          {:ok, fd} ->
            :file.position(fd, offset)

            case IO.read(fd, size - offset) do
              data when is_binary(data) ->
                File.close(fd)

                messages =
                  data
                  |> String.split("\n", trim: true)
                  |> Enum.map(&parse_line/1)
                  |> Enum.reject(&is_nil/1)

                {:ok, messages, size}

              _ ->
                File.close(fd)
                {:ok, [], offset}
            end

          {:error, reason} ->
            {:error, reason}
        end

      {:ok, %{size: _size}} ->
        {:ok, [], offset}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_correlate_sessions(project_dir) do
    expanded = Path.expand(project_dir)

    jsonl_files = find_jsonl_files(expanded)

    groups =
      jsonl_files
      |> Enum.map(fn path ->
        meta = extract_file_meta(path)
        %{path: path, meta: meta}
      end)
      |> Enum.group_by(fn entry ->
        cwd = get_in(entry, [:meta, :cwd]) || "unknown"
        cwd
      end)

    {:ok, groups}
  end

  defp do_find_related(file_path) do
    dir = Path.dirname(file_path)
    parent_dir = Path.dirname(dir)

    # Check for subagents directory alongside the file
    session_id = Path.rootname(Path.basename(file_path))
    subagents_dir = Path.join(dir, "#{session_id}/subagents")

    # Collect related files
    related = []

    # Subagent files
    related =
      if File.dir?(subagents_dir) do
        case File.ls(subagents_dir) do
          {:ok, files} ->
            subagent_entries =
              files
              |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
              |> Enum.map(fn f ->
                full = Path.join(subagents_dir, f)
                meta = extract_file_meta(full)

                %{
                  path: full,
                  type: :subagent,
                  agent_id: Path.rootname(f),
                  cwd: meta[:cwd],
                  timestamp: meta[:timestamp]
                }
              end)

            related ++ subagent_entries

          _ ->
            related
        end
      else
        related
      end

    # Check parent for other sessions in same project dir (same cwd / time window)
    related =
      case File.ls(dir) do
        {:ok, files} ->
          same_dir_sessions =
            files
            |> Enum.filter(fn f ->
              String.ends_with?(f, ".jsonl") and f != Path.basename(file_path)
            end)
            |> Enum.map(fn f ->
              full = Path.join(dir, f)
              meta = extract_file_meta(full)

              %{
                path: full,
                type: classify_session(f, meta),
                agent_id: Path.rootname(f),
                cwd: meta[:cwd],
                timestamp: meta[:timestamp]
              }
            end)

          related ++ same_dir_sessions

        _ ->
          related
      end

    # Also check if parent_dir has claude-mem observer dirs
    related =
      case File.ls(parent_dir) do
        {:ok, dirs} ->
          observer_entries =
            dirs
            |> Enum.filter(fn d ->
              String.contains?(d, "claude-mem") or String.contains?(d, "observer")
            end)
            |> Enum.flat_map(fn d ->
              obs_dir = Path.join(parent_dir, d)

              find_jsonl_files(obs_dir)
              |> Enum.map(fn f ->
                meta = extract_file_meta(f)

                %{
                  path: f,
                  type: :observer,
                  agent_id: Path.rootname(Path.basename(f)),
                  cwd: meta[:cwd],
                  timestamp: meta[:timestamp]
                }
              end)
            end)

          related ++ observer_entries

        _ ->
          related
      end

    {:ok, related}
  end

  defp classify_session(filename, meta) do
    cond do
      String.contains?(filename, "claude-mem") -> :observer
      String.contains?(filename, "mcp-search") -> :observer
      String.contains?(filename, "agent-") -> :subagent
      meta[:agent_id] && String.contains?(to_string(meta[:agent_id]), "claude-mem") -> :observer
      true -> :sibling
    end
  end

  defp find_jsonl_files(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.flat_map(fn entry ->
          full = Path.join(dir, entry)

          cond do
            String.ends_with?(entry, ".jsonl") -> [full]
            File.dir?(full) -> find_jsonl_files(full)
            true -> []
          end
        end)

      _ ->
        []
    end
  end

  defp extract_file_meta(path) do
    # Read just the first few lines to get session metadata
    case File.open(path, [:read, :binary, :utf8]) do
      {:ok, fd} ->
        meta = read_meta_lines(fd, 5, %{})
        File.close(fd)
        meta

      _ ->
        %{}
    end
  end

  defp read_meta_lines(_fd, 0, acc), do: acc

  defp read_meta_lines(fd, remaining, acc) do
    case IO.read(fd, :line) do
      :eof ->
        acc

      {:error, _} ->
        acc

      line when is_binary(line) ->
        case Jason.decode(line) do
          {:ok, parsed} ->
            new_acc =
              acc
              |> maybe_put(:cwd, parsed["cwd"])
              |> maybe_put(:session_id, parsed["sessionId"])
              |> maybe_put(:agent_id, parsed["agentId"])
              |> maybe_put(:timestamp, parsed["timestamp"])
              |> maybe_put(:git_branch, parsed["gitBranch"])

            if Map.has_key?(new_acc, :cwd) and Map.has_key?(new_acc, :session_id) do
              new_acc
            else
              read_meta_lines(fd, remaining - 1, new_acc)
            end

          _ ->
            read_meta_lines(fd, remaining - 1, acc)
        end
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put_new(map, key, value)

  @doc false
  def parse_line(line) do
    case Jason.decode(line) do
      {:ok, parsed} ->
        build_message(parsed)

      {:error, _} ->
        nil
    end
  end

  defp build_message(%{"type" => type} = parsed) when type in ["user", "assistant"] do
    message = parsed["message"] || %{}
    content = message["content"]
    usage = message["usage"]

    {text_content, tool_calls, tool_results} = extract_content_parts(content)

    %{
      type: type,
      role: message["role"] || type,
      content: text_content,
      timestamp: parsed["timestamp"],
      session_id: parsed["sessionId"],
      agent_id: parsed["agentId"],
      cwd: parsed["cwd"],
      uuid: parsed["uuid"],
      tool_calls: tool_calls,
      tool_results: tool_results,
      usage: normalize_usage(usage),
      raw_type: type
    }
  end

  defp build_message(%{"type" => "system", "subtype" => subtype} = parsed) do
    %{
      type: "system",
      role: "system",
      content: parsed["content"] || subtype,
      timestamp: parsed["timestamp"],
      session_id: parsed["sessionId"],
      agent_id: parsed["agentId"],
      cwd: parsed["cwd"],
      uuid: parsed["uuid"],
      tool_calls: [],
      tool_results: [],
      usage: nil,
      raw_type: "system:#{subtype}"
    }
  end

  # Skip non-message types (permission-mode, file-history-snapshot, etc.)
  defp build_message(_), do: nil

  defp extract_content_parts(content) when is_binary(content) do
    {content, [], []}
  end

  defp extract_content_parts(content) when is_list(content) do
    text_parts =
      content
      |> Enum.filter(fn
        %{"type" => "text"} -> true
        %{"type" => "thinking"} -> false
        _ -> false
      end)
      |> Enum.map(fn %{"text" => t} -> t end)
      |> Enum.join("\n")

    tool_calls =
      content
      |> Enum.filter(fn
        %{"type" => "tool_use"} -> true
        _ -> false
      end)
      |> Enum.map(fn tc ->
        %{
          id: tc["id"],
          name: tc["name"],
          input_preview: preview_input(tc["input"]),
          type: "tool_use"
        }
      end)

    tool_results =
      content
      |> Enum.filter(fn
        %{"type" => "tool_result"} -> true
        _ -> false
      end)
      |> Enum.map(fn tr ->
        %{
          tool_use_id: tr["tool_use_id"],
          content_preview: preview_content(tr["content"]),
          is_error: tr["is_error"] || false,
          type: "tool_result"
        }
      end)

    text = if text_parts == "", do: nil, else: text_parts
    {text, tool_calls, tool_results}
  end

  defp extract_content_parts(_), do: {nil, [], []}

  defp preview_input(input) when is_map(input) do
    case Jason.encode(input) do
      {:ok, json} -> String.slice(json, 0, 200)
      _ -> "..."
    end
  end

  defp preview_input(input) when is_binary(input), do: String.slice(input, 0, 200)
  defp preview_input(_), do: "..."

  defp preview_content(content) when is_binary(content), do: String.slice(content, 0, 200)

  defp preview_content(content) when is_list(content) do
    content
    |> Enum.map(fn
      %{"text" => t} -> t
      other -> inspect(other)
    end)
    |> Enum.join(" ")
    |> String.slice(0, 200)
  end

  defp preview_content(_), do: "..."

  defp normalize_usage(nil), do: nil

  defp normalize_usage(usage) when is_map(usage) do
    %{
      input_tokens: usage["input_tokens"] || 0,
      output_tokens: usage["output_tokens"] || 0,
      cache_read: get_in(usage, ["cache_read_input_tokens"]) || 0,
      cache_creation: get_in(usage, ["cache_creation_input_tokens"]) || 0
    }
  end

  defp normalize_usage(_), do: nil

  defp maybe_limit(list, :infinity), do: list
  defp maybe_limit(list, limit) when is_integer(limit), do: Enum.take(list, limit)
end
