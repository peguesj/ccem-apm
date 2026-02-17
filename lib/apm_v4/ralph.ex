defmodule ApmV4.Ralph do
  @moduledoc """
  Reads prd.json files and generates D3.js-compatible flowchart data.
  Port of v3's get_ralph_data() (monitor.py lines 236-262).
  """

  @doc """
  Load a prd.json file and return structured Ralph data.
  Returns `{:ok, data}` or `{:error, reason}`.
  """
  @spec load(String.t() | nil) :: {:ok, map()} | {:error, term()}
  def load(nil), do: {:ok, empty_data()}
  def load(""), do: {:ok, empty_data()}

  def load(path) do
    case File.read(path) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, prd} -> {:ok, parse_prd(prd)}
          {:error, reason} -> {:error, {:json_parse, reason}}
        end

      {:error, reason} ->
        {:error, {:file_read, reason}}
    end
  end

  @doc """
  Generate D3.js-compatible nodes and edges from a list of stories.
  Nodes are color-coded: green for passes=true, red for passes=false.
  Edges form a linear chain.
  """
  @spec flowchart(list()) :: map()
  def flowchart(stories) when is_list(stories) do
    nodes =
      stories
      |> Enum.with_index()
      |> Enum.map(fn {story, idx} ->
        passes = story["passes"] == true

        %{
          id: story["id"] || "US-#{idx}",
          label: story["title"] || "Story #{idx + 1}",
          description: story["description"] || "",
          priority: story["priority"] || idx + 1,
          status: if(passes, do: "passed", else: "pending"),
          color: if(passes, do: "#22c55e", else: "#ef4444"),
          shape: "rectangle",
          x: idx * 180,
          y: 100
        }
      end)

    edges =
      nodes
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [source, target] ->
        %{
          source: source.id,
          target: target.id,
          animated: true
        }
      end)

    %{nodes: nodes, edges: edges}
  end

  def flowchart(_), do: %{nodes: [], edges: []}

  # --- Private ---

  defp parse_prd(prd) do
    stories = Map.get(prd, "userStories", [])
    total = length(stories)
    passed = Enum.count(stories, fn s -> s["passes"] == true end)

    %{
      project: Map.get(prd, "project", "Unknown"),
      branch: Map.get(prd, "branchName", ""),
      description: Map.get(prd, "description", ""),
      stories: stories,
      total: total,
      passed: passed
    }
  end

  defp empty_data do
    %{
      project: "",
      branch: "",
      description: "",
      stories: [],
      total: 0,
      passed: 0
    }
  end
end
