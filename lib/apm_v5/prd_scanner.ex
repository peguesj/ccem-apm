defmodule ApmV5.PrdScanner do
  @moduledoc """
  Scans ~/Developer and ~/.claude/skills/ralph for prd.json files.
  Returns structured metadata: project name, branch, story counts, passes status.
  """
  require Logger

  @primary_path "~/.claude/skills/ralph/prd.json"
  @search_roots ["~/Developer", "~/.claude/skills"]
  @max_depth 4

  @spec scan() :: [map()]
  def scan do
    paths = find_prd_files()
    paths
    |> Enum.map(&parse_prd/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.modified_at, {:desc, DateTime})
  end

  @spec find_primary() :: {:ok, map()} | {:error, :not_found}
  def find_primary do
    path = Path.expand(@primary_path)
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, parsed} ->
            result = build_prd_meta(path, parsed)
            {:ok, result}
          _ -> {:error, :invalid_json}
        end
      _ -> {:error, :not_found}
    end
  end

  # --- Private ---

  defp find_prd_files do
    @search_roots
    |> Enum.map(&Path.expand/1)
    |> Enum.flat_map(&find_in_dir(&1, 0))
    |> Enum.uniq()
  end

  defp find_in_dir(_dir, depth) when depth > @max_depth, do: []
  defp find_in_dir(dir, depth) do
    prd_path = Path.join(dir, "prd.json")
    found = if File.exists?(prd_path), do: [prd_path], else: []

    sub = case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.filter(&File.dir?/1)
        |> Enum.reject(&String.starts_with?(Path.basename(&1), ".") and depth > 0)
        |> Enum.flat_map(&find_in_dir(&1, depth + 1))
      _ -> []
    end

    found ++ sub
  end

  defp parse_prd(path) do
    with {:ok, content} <- File.read(path),
         {:ok, parsed} <- Jason.decode(content),
         true <- is_map(parsed) and Map.has_key?(parsed, "userStories") do
      build_prd_meta(path, parsed)
    else
      _ -> nil
    end
  end

  defp build_prd_meta(path, parsed) do
    stories = Map.get(parsed, "userStories", [])
    total = length(stories)
    passes = Enum.count(stories, &(Map.get(&1, "passes") == true))
    pending = total - passes

    stat = case File.stat(path) do
      {:ok, s} -> s
      _ -> %{mtime: {{2020, 1, 1}, {0, 0, 0}}}
    end

    mtime_dt = case stat.mtime do
      {{y, mo, d}, {h, mi, s}} ->
        case DateTime.new(Date.new!(y, mo, d), Time.new!(h, mi, s), "Etc/UTC") do
          {:ok, dt} -> dt
          _ -> DateTime.utc_now()
        end
      _ -> DateTime.utc_now()
    end

    %{
      path: path,
      project: Map.get(parsed, "project", Path.basename(Path.dirname(path))),
      branch: Map.get(parsed, "branchName", "unknown"),
      total_stories: total,
      passes: passes,
      pending: pending,
      modified_at: mtime_dt
    }
  end
end
