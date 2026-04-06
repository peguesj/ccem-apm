defmodule ApmV5.Integrations.ClaudeMem.ClaudeMemIntegration do
  @moduledoc "Claude Memory integration — reads project memory files from ~/.claude/projects/*/memory/"

  @behaviour ApmV5.Integrations.IntegrationBehaviour

  @memory_base Path.expand("~/.claude/projects")

  @impl true
  def integration_name, do: "claude_mem"
  @impl true
  def integration_description, do: "Claude Memory — project memory file access and search"
  @impl true
  def integration_version, do: "1.0.0"
  @impl true
  def protocol, do: :rest
  @impl true
  def required_plugin, do: nil
  @impl true
  def target_native_feature, do: :memory_system

  @impl true
  def connect(_config), do: {:ok, %{memory_base: @memory_base}}
  @impl true
  def disconnect, do: :ok
  @impl true
  def status, do: if(File.dir?(@memory_base), do: :connected, else: :disconnected)

  @impl true
  def list_endpoints do
    [
      %{action: "list_memories", description: "List all project memory files"},
      %{action: "search_memories", description: "Search memory files by keyword"},
      %{action: "get_memory", description: "Read a specific memory file"}
    ]
  end

  @impl true
  def handle_event("list_memories", _payload, _opts) do
    memories =
      Path.wildcard(Path.join(@memory_base, "*/memory/*.md"))
      |> Enum.map(fn path ->
        %{path: path, project: path |> Path.dirname() |> Path.dirname() |> Path.basename(), name: Path.basename(path)}
      end)

    {:ok, %{memories: memories, count: length(memories)}}
  end

  def handle_event("search_memories", %{"query" => query}, _opts) do
    results =
      Path.wildcard(Path.join(@memory_base, "*/memory/*.md"))
      |> Enum.filter(fn path ->
        case File.read(path) do
          {:ok, content} -> String.contains?(String.downcase(content), String.downcase(query))
          _ -> false
        end
      end)
      |> Enum.map(fn path ->
        %{path: path, project: path |> Path.dirname() |> Path.dirname() |> Path.basename(), name: Path.basename(path)}
      end)

    {:ok, %{results: results, count: length(results)}}
  end

  def handle_event("get_memory", %{"path" => path}, _opts) do
    case File.read(path) do
      {:ok, content} -> {:ok, %{path: path, content: content}}
      {:error, reason} -> {:error, "Failed to read #{path}: #{inspect(reason)}"}
    end
  end

  def handle_event(event, _payload, _opts), do: {:error, {:unknown_event, event}}

  @impl true
  def supervisor_children, do: []
end
