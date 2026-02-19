defmodule ApmV4.DocsStore do
  @moduledoc """
  GenServer that loads, parses, and caches markdown documentation from priv/docs/.
  Provides TOC tree, page lookup, and simple search.
  """

  use GenServer

  @docs_dir "priv/docs"

  # Client API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc "Get rendered HTML for a doc page by path (e.g. \"user/getting-started\")"
  def get_page(path) do
    GenServer.call(__MODULE__, {:get_page, path})
  end

  @doc "Get the full TOC tree as a list of {category, [{slug, title}]}"
  def get_toc do
    GenServer.call(__MODULE__, :get_toc)
  end

  @doc "Search doc pages by query string, returns [{path, title, snippet}]"
  def search(query) do
    GenServer.call(__MODULE__, {:search, query})
  end

  # Server

  @impl true
  def init(_) do
    docs_path = Application.app_dir(:apm_v4, @docs_dir)
    {pages, toc} = load_docs(docs_path)
    {:ok, %{pages: pages, toc: toc, docs_path: docs_path}}
  end

  @impl true
  def handle_call({:get_page, path}, _from, state) do
    result = Map.get(state.pages, path)
    {:reply, result, state}
  end

  def handle_call(:get_toc, _from, state) do
    {:reply, state.toc, state}
  end

  def handle_call({:search, query}, _from, state) do
    query_down = String.downcase(query)

    results =
      state.pages
      |> Enum.filter(fn {_path, page} ->
        String.contains?(String.downcase(page.raw), query_down) ||
          String.contains?(String.downcase(page.title), query_down)
      end)
      |> Enum.map(fn {path, page} ->
        snippet = extract_snippet(page.raw, query_down)
        %{path: path, title: page.title, snippet: snippet}
      end)
      |> Enum.sort_by(& &1.title)

    {:reply, results, state}
  end

  # Internals

  defp load_docs(docs_path) do
    if File.dir?(docs_path) do
      files =
        docs_path
        |> Path.join("**/*.md")
        |> Path.wildcard()
        |> Enum.sort()

      pages =
        files
        |> Enum.map(fn file ->
          relative = Path.relative_to(file, docs_path)
          slug = relative |> String.replace_suffix(".md", "")
          raw = File.read!(file)
          {html, title} = parse_markdown(raw)
          {slug, %{html: html, title: title, raw: raw}}
        end)
        |> Map.new()

      toc = build_toc(pages)
      {pages, toc}
    else
      {%{}, []}
    end
  end

  defp parse_markdown(raw) do
    title =
      case Regex.run(~r/^#\s+(.+)$/m, raw) do
        [_, t] -> String.trim(t)
        _ -> "Untitled"
      end

    {:ok, html, _} = Earmark.as_html(raw)
    {html, title}
  end

  defp build_toc(pages) do
    # Group by category (directory) or "root" for top-level files
    pages
    |> Enum.map(fn {slug, page} ->
      parts = String.split(slug, "/")

      {category, leaf} =
        case parts do
          [single] -> {"root", single}
          [cat | rest] -> {cat, Enum.join(rest, "/")}
        end

      {category, slug, leaf, page.title}
    end)
    |> Enum.group_by(&elem(&1, 0))
    |> Enum.sort_by(fn {cat, _} ->
      case cat do
        "root" -> 0
        "user" -> 1
        "developer" -> 2
        "admin" -> 3
        _ -> 4
      end
    end)
    |> Enum.map(fn {category, entries} ->
      items =
        entries
        |> Enum.map(fn {_cat, slug, _leaf, title} -> %{slug: slug, title: title} end)
        |> Enum.sort_by(& &1.title)

      %{category: category, items: items}
    end)
  end

  defp extract_snippet(raw, query_down) do
    lines = String.split(raw, "\n")

    case Enum.find(lines, fn l -> String.contains?(String.downcase(l), query_down) end) do
      nil -> String.slice(raw, 0, 120) <> "..."
      line -> String.slice(String.trim(line), 0, 120)
    end
  end
end
