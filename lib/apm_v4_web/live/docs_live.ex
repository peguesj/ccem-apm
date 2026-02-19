defmodule ApmV4Web.DocsLive do
  @moduledoc "LiveView for browsing documentation wiki at /docs."

  use ApmV4Web, :live_view

  alias ApmV4.DocsStore

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
      |> assign(:active_skill_count, skill_count())

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    path = case params do
      %{"path" => parts} when is_list(parts) -> Enum.join(parts, "/")
      _ -> "index"
    end

    case DocsStore.get_page(path) do
      nil ->
        {:noreply, assign(socket, current_path: path, doc_html: nil, doc_title: "Not Found")}

      page ->
        {:noreply,
         assign(socket,
           current_path: path,
           doc_html: page.html,
           doc_title: page.title,
           page_title: "Docs - #{page.title}"
         )}
    end
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    if String.trim(query) == "" do
      {:noreply, assign(socket, search_query: "", search_results: nil)}
    else
      results = DocsStore.search(query)
      {:noreply, assign(socket, search_query: query, search_results: results)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen bg-base-300 overflow-hidden">
      <%!-- Sidebar nav --%>
      <aside class="w-56 bg-base-200 border-r border-base-300 flex flex-col flex-shrink-0">
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
          <.nav_item icon="hero-book-open" label="Docs" active={true} href="/docs" />
        </nav>
        <div class="p-3 border-t border-base-300">
          <div class="text-xs text-base-content/40">
            <div>Phoenix {Application.spec(:phoenix, :vsn)}</div>
          </div>
        </div>
      </aside>

      <%!-- Main area --%>
      <div class="flex-1 flex overflow-hidden">
        <%!-- TOC panel --%>
        <div class="w-56 bg-base-200 border-r border-base-300 flex flex-col flex-shrink-0 overflow-y-auto">
          <div class="p-3 border-b border-base-300">
            <form phx-change="search" phx-submit="search">
              <input
                type="text"
                name="query"
                value={@search_query}
                placeholder="Search docs..."
                phx-debounce="300"
                class="input input-xs input-bordered w-full bg-base-300 text-xs"
              />
            </form>
          </div>

          <%!-- Search results --%>
          <div :if={@search_results} class="p-2 space-y-1">
            <div class="text-[10px] uppercase tracking-wider text-base-content/40 px-2">
              {length(@search_results)} results
            </div>
            <a
              :for={result <- @search_results}
              href={"/docs/#{result.path}"}
              class="block px-2 py-1.5 rounded text-xs hover:bg-base-300 transition-colors"
            >
              <div class="font-medium text-primary">{result.title}</div>
              <div class="text-base-content/40 text-[10px] truncate">{result.snippet}</div>
            </a>
            <div :if={@search_results == []} class="text-xs text-base-content/40 px-2 py-4 text-center">
              No results found
            </div>
          </div>

          <%!-- TOC tree --%>
          <div :if={!@search_results} class="p-2 space-y-3">
            <div :for={group <- @toc} class="space-y-0.5">
              <div :if={group.category != "root"} class="text-[10px] uppercase tracking-wider text-base-content/40 px-2 pt-2 font-semibold">
                {format_category(group.category)}
              </div>
              <a
                :for={item <- group.items}
                href={"/docs/#{item.slug}"}
                class={[
                  "block px-2 py-1 rounded text-xs transition-colors",
                  @current_path == item.slug && "bg-primary/10 text-primary font-medium",
                  @current_path != item.slug && "text-base-content/60 hover:text-base-content hover:bg-base-300"
                ]}
              >
                {item.title}
              </a>
            </div>
          </div>
        </div>

        <%!-- Doc content --%>
        <div class="flex-1 flex flex-col overflow-hidden">
          <%!-- Breadcrumb --%>
          <header class="h-10 bg-base-200 border-b border-base-300 flex items-center px-4 flex-shrink-0">
            <div class="text-xs text-base-content/50 flex items-center gap-1">
              <a href="/docs" class="hover:text-primary">Docs</a>
              <span :if={@current_path && @current_path != "index"}>
                <span :for={part <- breadcrumb_parts(@current_path)} class="flex items-center gap-1 inline-flex">
                  <span class="text-base-content/30">/</span>
                  <span>{part}</span>
                </span>
              </span>
            </div>
          </header>

          <%!-- Content --%>
          <div class="flex-1 overflow-y-auto p-6">
            <div :if={@doc_html} class="prose prose-sm prose-invert max-w-3xl">
              {raw(@doc_html)}
            </div>
            <div :if={!@doc_html && @current_path} class="text-center py-12 text-base-content/40">
              <.icon name="hero-document-magnifying-glass" class="size-12 mb-4 mx-auto" />
              <p class="text-sm">Page not found: {@current_path}</p>
              <a href="/docs" class="text-primary text-xs hover:underline mt-2 block">Back to docs home</a>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # Components

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

  defp format_category("root"), do: "Overview"
  defp format_category("user"), do: "User Guide"
  defp format_category("developer"), do: "Developer"
  defp format_category("admin"), do: "Admin"
  defp format_category(other), do: String.capitalize(other)

  defp breadcrumb_parts(path) do
    path |> String.split("/") |> Enum.map(&String.replace(&1, "-", " ")) |> Enum.map(&String.capitalize/1)
  end

  defp skill_count do
    try do
      map_size(ApmV4.SkillTracker.get_skill_catalog())
    catch
      :exit, _ -> 0
    end
  end
end
