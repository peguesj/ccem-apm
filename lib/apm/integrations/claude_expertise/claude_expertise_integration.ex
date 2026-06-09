defmodule Apm.Integrations.ClaudeExpertise.ClaudeExpertiseIntegration do
  @moduledoc "Claude Expertise integration — reads ~/Developer/claude-expertise/ sources"

  @behaviour Apm.Integrations.IntegrationBehaviour

  @expertise_path Path.expand("~/Developer/claude-expertise")

  @impl true
  def integration_name, do: "claude_expertise"
  @impl true
  def integration_description, do: "Claude Expertise — expertise source access and search"
  @impl true
  def integration_version, do: "1.0.0"
  @impl true
  def protocol, do: :rest
  @impl true
  def required_plugin, do: nil
  @impl true
  def target_native_feature, do: :expertise_search

  @impl true
  def connect(_config), do: {:ok, %{path: @expertise_path}}
  @impl true
  def disconnect, do: :ok
  @impl true
  def status, do: if(File.dir?(@expertise_path), do: :connected, else: :disconnected)

  @impl true
  def list_endpoints do
    [
      %{action: "list_sources", description: "List expertise source files"},
      %{action: "search_expertise", description: "Search expertise by keyword"},
      %{action: "get_source", description: "Read a specific source file"}
    ]
  end

  @impl true
  def handle_event("list_sources", _payload, _opts) do
    sources =
      Path.wildcard(Path.join(@expertise_path, "**/*.{md,json,yaml,yml}"))
      |> Enum.map(fn path ->
        %{
          path: path,
          name: Path.basename(path),
          relative: Path.relative_to(path, @expertise_path)
        }
      end)

    {:ok, %{sources: sources, count: length(sources)}}
  end

  def handle_event("search_expertise", %{"query" => query}, _opts) do
    results =
      Path.wildcard(Path.join(@expertise_path, "**/*.{md,json,yaml,yml}"))
      |> Enum.filter(fn path ->
        case File.read(path) do
          {:ok, content} -> String.contains?(String.downcase(content), String.downcase(query))
          _ -> false
        end
      end)
      |> Enum.map(fn path -> %{path: path, name: Path.basename(path)} end)

    {:ok, %{results: results, count: length(results)}}
  end

  def handle_event("get_source", %{"path" => path}, _opts) do
    case File.read(path) do
      {:ok, content} -> {:ok, %{path: path, content: content}}
      {:error, reason} -> {:error, "Failed to read: #{inspect(reason)}"}
    end
  end

  def handle_event(event, _payload, _opts), do: {:error, {:unknown_event, event}}

  @impl true
  def supervisor_children, do: []
end
