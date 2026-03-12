defmodule ApmV5Web.DocsLive do
  @moduledoc """
  LiveView for browsing documentation wiki at /docs.
  Industry-standard documentation viewer with left TOC, content area,
  on-page heading navigation, and search with Cmd+K shortcut.
  """

  use ApmV5Web, :live_view

  alias ApmV5.DocsStore

  @category_icons %{
    "root" => "hero-home",
    "user" => "hero-user",
    "developer" => "hero-code-bracket",
    "admin" => "hero-cog-6-tooth"
  }

  @category_labels %{
    "root" => "Overview",
    "user" => "User Guide",
    "developer" => "Developer",
    "admin" => "Administration"
  }

  @impl true
  def mount(_params, _session, socket) do
    toc = DocsStore.get_toc()

    socket =
      socket
      |> assign(:page_title, "Docs")
      |> assign(:toc, toc)
      |> assign(:search_query, "")
      |> assign(:search_results, nil)
      |> assign(:current_path, nil)
      |> assign(:doc_html, nil)
      |> assign(:doc_title, nil)
      |> assign(:doc_description, nil)
      |> assign(:doc_category, nil)
      |> assign(:doc_read_time, nil)
      |> assign(:page_headings, [])
      |> assign(:prev_page, nil)
      |> assign(:next_page, nil)
      |> assign(:collapsed_categories, MapSet.new())
      |> assign(:mobile_toc_open, false)
      |> assign(:active_skill_count, skill_count())

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    path =
      case params do
        %{"path" => parts} when is_list(parts) -> Enum.join(parts, "/")
        _ -> "index"
      end

    toc = socket.assigns.toc

    case DocsStore.get_page(path) do
      nil ->
        {:noreply,
         assign(socket,
           current_path: path,
           doc_html: nil,
           doc_title: "Not Found",
           doc_description: nil,
           doc_category: nil,
           doc_read_time: nil,
           page_headings: [],
           prev_page: nil,
           next_page: nil
         )}

      page ->
        category = extract_category(path)
        headings = extract_headings(page.html)
        read_time = estimate_read_time(Map.get(page, :raw, page.html))
        meta = Map.get(page, :meta, %{})
        description = Map.get(meta, :description, Map.get(page, :description, nil))
        {prev_page, next_page} = find_prev_next(toc, path)

        {:noreply,
         assign(socket,
           current_path: path,
           doc_html: page.html,
           doc_title: page.title,
           doc_description: description,
           doc_category: category,
           doc_read_time: read_time,
           page_headings: headings,
           prev_page: prev_page,
           next_page: next_page,
           page_title: "Docs - #{page.title}",
           mobile_toc_open: false
         )}
    end
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    if String.trim(query) == "" do
      {:noreply, assign(socket, search_query: "", search_results: nil)}
    else
      results = DocsStore.search(query)

      grouped =
        results
        |> Enum.group_by(fn r -> extract_category(r.path) end)
        |> Enum.sort_by(fn {cat, _} -> category_sort_key(cat) end)

      {:noreply, assign(socket, search_query: query, search_results: grouped)}
    end
  end

  def handle_event("clear_search", _params, socket) do
    {:noreply, assign(socket, search_query: "", search_results: nil)}
  end

  def handle_event("toggle_category", %{"category" => category}, socket) do
    collapsed = socket.assigns.collapsed_categories

    collapsed =
      if MapSet.member?(collapsed, category) do
        MapSet.delete(collapsed, category)
      else
        MapSet.put(collapsed, category)
      end

    {:noreply, assign(socket, :collapsed_categories, collapsed)}
  end

  def handle_event("toggle_mobile_toc", _params, socket) do
    {:noreply, assign(socket, :mobile_toc_open, !socket.assigns.mobile_toc_open)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen bg-base-300 overflow-hidden">
      <%!-- App Sidebar Nav --%>
      <aside class="w-56 bg-base-200 border-r border-base-300 flex flex-col flex-shrink-0 hidden lg:flex">
        <div class="p-4 border-b border-base-300">
          <h1 class="text-lg font-bold text-primary flex items-center gap-2">
            <span class="inline-block w-2 h-2 rounded-full bg-success animate-pulse"></span>
            CCEM APM v4
          </h1>
          <p class="text-xs text-base-content/50 mt-1">Agent Performance Monitor</p>
        </div>
        <nav class="flex-1 p-2 space-y-1">
          <.nav_item icon="hero-squares-2x2" label="Dashboard" active={false} href="/" />
          <.nav_item icon="hero-globe-alt" label="All Projects" active={false} href="/apm-all" />
          <.nav_item icon="hero-sparkles" label="Skills" active={false} href="/skills" badge={@active_skill_count} />
          <.nav_item icon="hero-arrow-path" label="Ralph" active={false} href="/ralph" />
          <.nav_item icon="hero-clock" label="Timeline" active={false} href="/timeline" />
          <.nav_item icon="hero-rectangle-group" label="Formations" active={false} href="/formation" />
          <.nav_item icon="hero-signal" label="Ports" active={false} href="/ports" />
          <.nav_item icon="hero-beaker" label="UAT" active={false} href="/uat" />
          <.nav_item icon="hero-book-open" label="Docs" active={true} href="/docs" />
        </nav>
        <div class="p-3 border-t border-base-300">
          <div class="text-xs text-base-content/40">
            <div>Phoenix {Application.spec(:phoenix, :vsn)}</div>
          </div>
        </div>
      </aside>

      <%!-- Main docs area --%>
      <div class="flex-1 flex overflow-hidden">
        <%!-- Mobile header --%>
        <div class="lg:hidden fixed top-0 left-0 right-0 z-30 bg-base-200 border-b border-base-300 h-12 flex items-center px-4 gap-3">
          <button phx-click="toggle_mobile_toc" class="btn btn-ghost btn-sm btn-square">
            <.icon name="hero-bars-3" class="size-5" />
          </button>
          <a href="/docs" class="text-sm font-semibold text-primary">Docs</a>
          <span :if={@doc_title && @current_path != "index"} class="text-xs text-base-content/50 truncate">
            / {@doc_title}
          </span>
        </div>

        <%!-- Mobile TOC overlay --%>
        <div
          :if={@mobile_toc_open}
          class="lg:hidden fixed inset-0 z-40 bg-black/50"
          phx-click="toggle_mobile_toc"
        >
          <div class="w-72 h-full bg-base-200 overflow-y-auto" phx-click-away="toggle_mobile_toc">
            <div class="p-4 border-b border-base-300 flex items-center justify-between">
              <span class="text-sm font-semibold text-primary">Documentation</span>
              <button phx-click="toggle_mobile_toc" class="btn btn-ghost btn-xs btn-square">
                <.icon name="hero-x-mark" class="size-4" />
              </button>
            </div>
            <.toc_content
              toc={@toc}
              current_path={@current_path}
              collapsed_categories={@collapsed_categories}
              search_query={@search_query}
              search_results={@search_results}
            />
          </div>
        </div>

        <%!-- Desktop TOC panel --%>
        <div class="w-64 bg-base-200 border-r border-base-300 flex-col flex-shrink-0 overflow-hidden hidden lg:flex">
          <div class="p-4 border-b border-base-300">
            <a href="/docs" class="flex items-center gap-2 mb-3">
              <.icon name="hero-book-open" class="size-5 text-primary" />
              <span class="text-base font-bold text-base-content">Documentation</span>
            </a>
            <%!-- Search box --%>
            <form phx-change="search" phx-submit="search" class="relative">
              <.icon name="hero-magnifying-glass" class="size-3.5 absolute left-2.5 top-1/2 -translate-y-1/2 text-base-content/30" />
              <input
                type="text"
                name="query"
                value={@search_query}
                placeholder="Search docs..."
                phx-debounce="200"
                class="input input-sm input-bordered w-full pl-8 pr-14 bg-base-300/50 text-xs focus:bg-base-300"
              />
              <kbd class="absolute right-2 top-1/2 -translate-y-1/2 kbd kbd-xs text-base-content/30">
                Cmd+K
              </kbd>
            </form>
          </div>

          <div class="flex-1 overflow-y-auto">
            <.toc_content
              toc={@toc}
              current_path={@current_path}
              collapsed_categories={@collapsed_categories}
              search_query={@search_query}
              search_results={@search_results}
            />
          </div>
        </div>

        <%!-- Content area --%>
        <div class="flex-1 flex overflow-hidden lg:mt-0 mt-12">
          <div class="flex-1 overflow-y-auto" id="docs-content-scroll">
            <div :if={@doc_html} class="max-w-4xl mx-auto px-6 py-8 lg:px-10 lg:py-10">
              <%!-- Page header --%>
              <div class="mb-8">
                <%!-- Breadcrumb --%>
                <nav class="flex items-center gap-1.5 text-xs text-base-content/40 mb-4">
                  <a href="/docs" class="hover:text-primary transition-colors">Docs</a>
                  <span :if={@doc_category && @doc_category != "root"} class="flex items-center gap-1.5">
                    <.icon name="hero-chevron-right" class="size-3" />
                    <span class="text-base-content/50">{format_category(@doc_category)}</span>
                  </span>
                  <span :if={@current_path != "index"} class="flex items-center gap-1.5">
                    <.icon name="hero-chevron-right" class="size-3" />
                    <span class="text-base-content/60">{@doc_title}</span>
                  </span>
                </nav>

                <%!-- Title and meta --%>
                <h1 class="text-3xl lg:text-4xl font-extrabold text-base-content tracking-tight leading-tight">
                  {@doc_title}
                </h1>
                <p :if={@doc_description} class="mt-3 text-base text-base-content/50 leading-relaxed">
                  {@doc_description}
                </p>
                <div class="flex items-center gap-3 mt-4">
                  <span :if={@doc_category && @doc_category != "root"} class="badge badge-sm badge-outline gap-1.5">
                    <.icon name={category_icon(@doc_category)} class="size-3" />
                    {format_category(@doc_category)}
                  </span>
                  <span :if={@doc_read_time} class="badge badge-sm badge-ghost gap-1">
                    <.icon name="hero-clock" class="size-3" />
                    {@doc_read_time} min read
                  </span>
                </div>
                <div class="divider mt-6 mb-0"></div>
              </div>

              <%!-- Rendered markdown content --%>
              <div id={"doc-content-#{@current_path}"} phx-hook="DocContent" class="doc-content docs-prose prose prose-invert max-w-none
                prose-headings:scroll-mt-20
                prose-a:text-primary prose-a:no-underline hover:prose-a:underline
                prose-code:text-primary prose-code:bg-base-300 prose-code:px-1.5 prose-code:py-0.5 prose-code:rounded-md prose-code:text-[0.8125em] prose-code:font-normal prose-code:before:content-none prose-code:after:content-none
                prose-pre:bg-neutral prose-pre:rounded-xl prose-pre:border prose-pre:border-base-300/50 prose-pre:shadow-md
                prose-img:rounded-lg prose-img:shadow-md prose-img:mx-auto
              ">
                {raw(@doc_html)}
              </div>

              <%!-- Prev/Next navigation --%>
              <div :if={@prev_page || @next_page} class="grid grid-cols-1 sm:grid-cols-2 gap-4 mt-12 pt-8 border-t border-base-300">
                <div>
                  <a
                    :if={@prev_page}
                    href={"/docs/#{@prev_page.slug}"}
                    class="group flex items-center gap-3 p-4 rounded-xl border border-base-300 bg-base-200/50 hover:border-primary/30 hover:bg-base-200 transition-all"
                  >
                    <.icon name="hero-arrow-left" class="size-5 text-base-content/30 group-hover:text-primary transition-colors flex-shrink-0" />
                    <div class="text-right flex-1 min-w-0">
                      <div class="text-[10px] uppercase tracking-wider text-base-content/30 mb-0.5">Previous</div>
                      <div class="text-sm font-medium text-base-content/80 group-hover:text-primary transition-colors truncate">
                        {@prev_page.title}
                      </div>
                    </div>
                  </a>
                </div>
                <div>
                  <a
                    :if={@next_page}
                    href={"/docs/#{@next_page.slug}"}
                    class="group flex items-center gap-3 p-4 rounded-xl border border-base-300 bg-base-200/50 hover:border-primary/30 hover:bg-base-200 transition-all"
                  >
                    <div class="flex-1 min-w-0">
                      <div class="text-[10px] uppercase tracking-wider text-base-content/30 mb-0.5">Next</div>
                      <div class="text-sm font-medium text-base-content/80 group-hover:text-primary transition-colors truncate">
                        {@next_page.title}
                      </div>
                    </div>
                    <.icon name="hero-arrow-right" class="size-5 text-base-content/30 group-hover:text-primary transition-colors flex-shrink-0" />
                  </a>
                </div>
              </div>

              <%!-- Footer --%>
              <div class="mt-12 pt-6 border-t border-base-300 text-center">
                <p class="text-xs text-base-content/30">
                  CCEM APM v4 Documentation
                </p>
              </div>
            </div>

            <%!-- Not found state --%>
            <div :if={!@doc_html && @current_path} class="flex flex-col items-center justify-center py-24 px-6 text-center">
              <div class="w-16 h-16 rounded-2xl bg-base-200 flex items-center justify-center mb-6">
                <.icon name="hero-document-magnifying-glass" class="size-8 text-base-content/20" />
              </div>
              <h2 class="text-lg font-semibold text-base-content/60 mb-2">Page Not Found</h2>
              <p class="text-sm text-base-content/40 mb-6 max-w-sm">
                The page <code class="text-primary bg-neutral/50 px-1.5 py-0.5 rounded text-xs">{@current_path}</code> does not exist.
              </p>
              <a href="/docs" class="btn btn-primary btn-sm gap-2">
                <.icon name="hero-arrow-left" class="size-4" />
                Back to docs
              </a>
            </div>
          </div>

          <%!-- On-page TOC (right sidebar) --%>
          <div :if={@doc_html && @page_headings != []} class="w-48 flex-shrink-0 hidden xl:block border-l border-base-300 overflow-y-auto">
            <div class="p-4 sticky top-0">
              <h4 class="text-[10px] uppercase tracking-widest text-base-content/30 font-semibold mb-3">
                On this page
              </h4>
              <nav class="space-y-0.5">
                <a
                  :for={heading <- @page_headings}
                  href={"##{heading.id}"}
                  class={[
                    "block text-xs transition-colors hover:text-primary truncate",
                    heading.level == 2 && "text-base-content/60 py-1",
                    heading.level == 3 && "text-base-content/40 py-0.5 pl-3"
                  ]}
                >
                  {heading.text}
                </a>
              </nav>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ---------- TOC Content Component ----------

  attr :toc, :list, required: true
  attr :current_path, :string
  attr :collapsed_categories, :any, required: true
  attr :search_query, :string
  attr :search_results, :any

  defp toc_content(assigns) do
    ~H"""
    <div class="p-3">
      <%!-- Search results --%>
      <div :if={@search_results} class="space-y-4">
        <div class="flex items-center justify-between px-1">
          <span class="text-[10px] uppercase tracking-wider text-base-content/40">
            {Enum.reduce(@search_results, 0, fn {_, items}, acc -> acc + length(items) end)} results
          </span>
          <button phx-click="clear_search" class="text-[10px] text-primary hover:underline">
            Clear
          </button>
        </div>
        <div :for={{category, results} <- @search_results} class="space-y-1">
          <div class="text-[10px] uppercase tracking-wider text-base-content/30 px-2 font-semibold flex items-center gap-1.5">
            <.icon name={category_icon(category)} class="size-3" />
            {format_category(category)}
          </div>
          <a
            :for={result <- results}
            href={"/docs/#{result.path}"}
            class="block px-3 py-2 rounded-lg text-xs hover:bg-base-300 transition-colors group"
          >
            <div class="font-medium text-base-content/80 group-hover:text-primary transition-colors">
              {result.title}
            </div>
            <div class="text-base-content/35 text-[11px] mt-0.5 line-clamp-2 leading-relaxed">
              {highlight_snippet(result.snippet, @search_query)}
            </div>
          </a>
        </div>
        <div :if={@search_results == []} class="text-center py-8">
          <.icon name="hero-magnifying-glass" class="size-8 text-base-content/15 mx-auto mb-3" />
          <p class="text-xs text-base-content/40">No results for "{@search_query}"</p>
        </div>
      </div>

      <%!-- TOC tree --%>
      <div :if={!@search_results} class="space-y-1">
        <div :for={group <- @toc} class="mb-1">
          <%!-- Category header --%>
          <button
            phx-click="toggle_category"
            phx-value-category={group[:category] || group[:id]}
            class="w-full flex items-center gap-2 px-3 py-2 rounded-lg text-xs font-semibold uppercase tracking-wider text-base-content/40 hover:text-base-content/60 hover:bg-base-300/50 transition-all group"
          >
            <.icon name={category_icon(group[:category] || group[:id])} class="size-3.5 text-base-content/30 group-hover:text-primary/60 transition-colors" />
            <span class="flex-1 text-left">{format_category(group[:category] || group[:id])}</span>
            <.icon
              name={if MapSet.member?(@collapsed_categories, group[:category] || group[:id]), do: "hero-chevron-right", else: "hero-chevron-down"}
              class="size-3 text-base-content/20 transition-transform"
            />
          </button>

          <%!-- Category items --%>
          <div :if={!MapSet.member?(@collapsed_categories, group[:category] || group[:id])} class="mt-0.5 space-y-0.5 ml-2">
            <a
              :for={item <- group.items}
              href={"/docs/#{item.slug}"}
              class={[
                "flex items-center gap-2 px-3 py-1.5 rounded-lg text-xs transition-all relative",
                @current_path == item.slug &&
                  "bg-primary/8 text-primary font-medium before:absolute before:left-0 before:top-1 before:bottom-1 before:w-0.5 before:rounded-full before:bg-primary",
                @current_path != item.slug &&
                  "text-base-content/55 hover:text-base-content/80 hover:bg-base-300/50"
              ]}
              title={Map.get(item, :description, nil)}
            >
              <span class="truncate">{item.title}</span>
            </a>
          </div>
        </div>
      </div>

      <%!-- API Reference link --%>
      <div :if={!@search_results} class="mt-4 pt-3 border-t border-base-content/5 px-1">
        <a
          href="/api/docs"
          target="_blank"
          class="flex items-center gap-2 px-3 py-2 rounded-lg text-xs text-base-content/50 hover:text-primary hover:bg-base-300/50 transition-all group"
        >
          <.icon name="hero-arrow-top-right-on-square" class="size-3.5 text-base-content/30 group-hover:text-primary/60 transition-colors" />
          <span class="font-medium">API Reference</span>
          <span class="text-[10px] text-base-content/25 ml-auto">OpenAPI</span>
        </a>
      </div>
    </div>
    """
  end

  # ---------- Nav Item Component ----------

  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :active, :boolean, default: false
  attr :href, :string, required: true
  attr :badge, :any, default: nil

  defp nav_item(assigns) do
    ~H"""
    <a
      href={@href}
      class={[
        "flex items-center gap-3 px-3 py-2 rounded text-sm transition-colors",
        @active && "bg-primary/10 text-primary font-medium",
        !@active && "text-base-content/60 hover:text-base-content hover:bg-base-300"
      ]}
    >
      <.icon name={@icon} class="size-4" />
      {@label}
      <span :if={@badge && @badge > 0} class="badge badge-xs badge-primary ml-auto">{@badge}</span>
    </a>
    """
  end

  # ---------- Helpers ----------

  defp extract_category(path) do
    case String.split(path, "/") do
      [_single] -> "root"
      [cat | _] -> cat
    end
  end

  defp category_icon(category) do
    Map.get(@category_icons, category, "hero-folder")
  end

  defp format_category(category) do
    Map.get(@category_labels, category, String.capitalize(category))
  end

  defp category_sort_key(cat) do
    case cat do
      "root" -> 0
      "user" -> 1
      "developer" -> 2
      "admin" -> 3
      _ -> 4
    end
  end

  defp estimate_read_time(text) when is_binary(text) do
    word_count = text |> String.split(~r/\s+/) |> length()
    max(1, div(word_count, 200))
  end

  defp estimate_read_time(_), do: nil

  @heading_regex ~r/<h([23])[^>]*id="([^"]*)"[^>]*>(.*?)<\/h[23]>/s
  @tag_strip_regex ~r/<[^>]+>/

  defp extract_headings(html) when is_binary(html) do
    @heading_regex
    |> Regex.scan(html)
    |> Enum.map(fn
      [_, level, id, text] ->
        clean_text = Regex.replace(@tag_strip_regex, text, "") |> String.trim()
        %{level: String.to_integer(level), id: id, text: clean_text}

      _ ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp extract_headings(_), do: []

  defp find_prev_next(toc, current_path) do
    all_pages =
      toc
      |> Enum.flat_map(fn group -> group.items end)

    current_index = Enum.find_index(all_pages, fn item -> item.slug == current_path end)

    case current_index do
      nil ->
        {nil, nil}

      0 ->
        {nil, Enum.at(all_pages, 1)}

      idx ->
        {Enum.at(all_pages, idx - 1), Enum.at(all_pages, idx + 1)}
    end
  end

  defp highlight_snippet(snippet, _query) when is_binary(snippet), do: snippet
  defp highlight_snippet(_, _), do: ""

  defp skill_count do
    try do
      map_size(ApmV5.SkillTracker.get_skill_catalog())
    catch
      :exit, _ -> 0
    end
  end
end
