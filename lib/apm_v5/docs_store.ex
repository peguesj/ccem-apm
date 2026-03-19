defmodule ApmV5.DocsStore do
  @moduledoc """
  GenServer that loads, parses, and caches markdown documentation from priv/docs/.
  Uses docs.json as the source of truth for structure, ordering, and metadata.
  Parses .md files via Earmark for HTML content.
  """

  use GenServer

  @docs_dir "priv/docs"

  # Client API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc "Get rendered HTML for a doc page by slug (e.g. \"user/getting-started\")"
  @spec get_page(String.t()) :: map() | nil
  def get_page(path) do
    GenServer.call(__MODULE__, {:get_page, path})
  end

  @doc "Get the full TOC as a list of categories with icons, ordered pages, and descriptions"
  @spec get_toc() :: [map()]
  def get_toc do
    GenServer.call(__MODULE__, :get_toc)
  end

  @doc "Get JSON metadata for a page by slug"
  @spec get_page_meta(String.t()) :: map() | nil
  def get_page_meta(slug) do
    GenServer.call(__MODULE__, {:get_page_meta, slug})
  end

  @doc "Get previous and next pages for navigation. Returns %{prev: meta | nil, next: meta | nil}"
  @spec get_adjacent_pages(String.t()) :: %{prev: map() | nil, next: map() | nil}
  def get_adjacent_pages(slug) do
    GenServer.call(__MODULE__, {:get_adjacent_pages, slug})
  end

  @doc "Search doc pages by query string, returns [{path, title, snippet}]"
  @spec search(String.t()) :: [map()]
  def search(query) do
    GenServer.call(__MODULE__, {:search, query})
  end

  # Server

  @impl true
  def init(_) do
    docs_path = Application.app_dir(:apm_v5, @docs_dir)
    {:ok, %{pages: %{}, toc: [], meta_index: %{}, ordered_slugs: [], docs_path: docs_path}, {:continue, :load_docs}}
  end

  @impl true
  def handle_continue(:load_docs, state) do
    {pages, toc, meta_index, ordered_slugs} = load_docs(state.docs_path)
    {:noreply, %{state | pages: pages, toc: toc, meta_index: meta_index, ordered_slugs: ordered_slugs}}
  end

  @impl true
  def handle_call({:get_page, path}, _from, state) do
    result = Map.get(state.pages, path)
    {:reply, result, state}
  end

  def handle_call(:get_toc, _from, state) do
    {:reply, state.toc, state}
  end

  def handle_call({:get_page_meta, slug}, _from, state) do
    {:reply, Map.get(state.meta_index, slug), state}
  end

  def handle_call({:get_adjacent_pages, slug}, _from, state) do
    adjacent = compute_adjacent(slug, state.ordered_slugs, state.meta_index)
    {:reply, adjacent, state}
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
        meta = Map.get(state.meta_index, path, %{})
        %{path: path, title: page.title, snippet: snippet, description: Map.get(meta, :description), tags: Map.get(meta, :tags, [])}
      end)
      |> Enum.sort_by(& &1.title)

    {:reply, results, state}
  end

  # Internals

  defp load_docs(docs_path) do
    manifest_path = Path.join(docs_path, "docs.json")

    if File.exists?(manifest_path) do
      load_from_manifest(docs_path, manifest_path)
    else
      load_legacy(docs_path)
    end
  end

  defp load_from_manifest(docs_path, manifest_path) do
    manifest = manifest_path |> File.read!() |> Jason.decode!(keys: :atoms)

    {pages, meta_index, ordered_slugs} =
      manifest.categories
      |> Enum.sort_by(& &1.order)
      |> Enum.reduce({%{}, %{}, []}, fn category, {pages_acc, meta_acc, slugs_acc} ->
        sorted_pages = Enum.sort_by(category.pages, & &1.order)

        Enum.reduce(sorted_pages, {pages_acc, meta_acc, slugs_acc}, fn page_meta, {p, m, s} ->
          file_path = Path.join(docs_path, page_meta.file)
          slug = page_meta.slug

          meta = %{
            slug: slug,
            title: page_meta.title,
            description: page_meta.description,
            icon: page_meta.icon,
            tags: page_meta.tags,
            category_id: category.id,
            category_label: category.label,
            order: page_meta.order
          }

          case File.read(file_path) do
            {:ok, raw} ->
              {html, title} = parse_markdown(raw)
              page = %{html: html, title: title, raw: raw, meta: meta}
              {Map.put(p, slug, page), Map.put(m, slug, meta), s ++ [slug]}

            {:error, _} ->
              {p, Map.put(m, slug, meta), s ++ [slug]}
          end
        end)
      end)

    toc =
      manifest.categories
      |> Enum.sort_by(& &1.order)
      |> Enum.map(fn category ->
        items =
          category.pages
          |> Enum.sort_by(& &1.order)
          |> Enum.map(fn page ->
            %{
              slug: page.slug,
              title: page.title,
              description: page.description,
              icon: page.icon,
              tags: page.tags
            }
          end)

        %{
          id: category.id,
          label: category.label,
          icon: category.icon,
          order: category.order,
          items: items
        }
      end)

    {pages, toc, meta_index, ordered_slugs}
  end

  defp load_legacy(docs_path) do
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
          {slug, %{html: html, title: title, raw: raw, meta: %{}}}
        end)
        |> Map.new()

      toc = build_legacy_toc(pages)
      meta_index = %{}
      ordered_slugs = pages |> Map.keys() |> Enum.sort()
      {pages, toc, meta_index, ordered_slugs}
    else
      {%{}, [], %{}, []}
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

  defp build_legacy_toc(pages) do
    pages
    |> Enum.map(fn {slug, page} ->
      parts = String.split(slug, "/")

      {category, _leaf} =
        case parts do
          [single] -> {"root", single}
          [cat | rest] -> {cat, Enum.join(rest, "/")}
        end

      {category, slug, page.title}
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
        |> Enum.map(fn {_cat, slug, title} -> %{slug: slug, title: title} end)
        |> Enum.sort_by(& &1.title)

      %{id: category, label: String.capitalize(category), icon: nil, order: nil, items: items}
    end)
  end

  defp compute_adjacent(slug, ordered_slugs, meta_index) do
    idx = Enum.find_index(ordered_slugs, &(&1 == slug))

    case idx do
      nil ->
        %{prev: nil, next: nil}

      _ ->
        prev = if idx > 0, do: Map.get(meta_index, Enum.at(ordered_slugs, idx - 1)), else: nil
        next = Map.get(meta_index, Enum.at(ordered_slugs, idx + 1))
        %{prev: prev, next: next}
    end
  end

  defp extract_snippet(raw, query_down) do
    lines = String.split(raw, "\n")

    case Enum.find(lines, fn l -> String.contains?(String.downcase(l), query_down) end) do
      nil -> String.slice(raw, 0, 120) <> "..."
      line -> String.slice(String.trim(line), 0, 120)
    end
  end
end
