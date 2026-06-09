defmodule Apm.Coalesce.SourceFetcher do
  @moduledoc """
  Fetches and normalises content from URLs, local files, and VIKI queries
  into a unified source map used by SkillLogicEngine.

  Source types:
  - HTTP/HTTPS URLs — fetched via :httpc, HTML stripped to markdown-ish text
  - Local .md files — read directly
  - Local .pdf files — delegates to pdf tool (if available)
  - "viki:<query>" — queries VIKI API at localhost:3033 (if running)
  - "upm:plan" — fetches current UPM project state from APM
  - "apm:<path>" — fetches from APM API

  Returns a list of %{url, content, domain, source_type, fetched_at} maps.
  """

  require Logger

  @apm_base "http://localhost:3032"
  @fetch_timeout_ms 15_000

  # ── Client API ──────────────────────────────────────────────────────────────

  @doc "Fetch all sources in parallel. Returns list of source maps."
  @spec fetch_all([String.t()]) :: [map()]
  def fetch_all(sources) when is_list(sources) do
    sources
    |> Task.async_stream(&fetch_one/1,
      max_concurrency: 8,
      timeout: @fetch_timeout_ms + 2_000,
      on_timeout: :kill_task
    )
    |> Enum.reduce([], fn
      {:ok, {:ok, source}}, acc ->
        [source | acc]

      {:ok, {:error, reason}}, acc ->
        Logger.warning("[SourceFetcher] Fetch failed: #{inspect(reason)}")
        acc

      {:exit, reason}, acc ->
        Logger.warning("[SourceFetcher] Task exit: #{inspect(reason)}")
        acc
    end)
    |> Enum.reverse()
  end

  def fetch_all(_), do: []

  @doc "Fetch a single source. Returns {:ok, source_map} | {:error, reason}."
  @spec fetch_one(String.t()) :: {:ok, map()} | {:error, term()}
  def fetch_one("viki:" <> query) do
    _fetch_viki(query)
  end

  def fetch_one("upm:plan") do
    _fetch_apm("/api/upm/projects")
  end

  def fetch_one("apm:" <> path) do
    _fetch_apm(path)
  end

  def fetch_one(source) when is_binary(source) do
    cond do
      String.starts_with?(source, "http://") or String.starts_with?(source, "https://") ->
        _fetch_url(source)

      String.ends_with?(source, ".pdf") ->
        _fetch_pdf(source)

      File.exists?(source) ->
        _fetch_local_file(source)

      true ->
        {:error, {:unknown_source, source}}
    end
  end

  # ── Private: Fetchers ──────────────────────────────────────────────────────

  defp _fetch_url(url) do
    Logger.info("[SourceFetcher] Fetching URL: #{url}")

    uri = URI.parse(url)
    domain = uri.host || "unknown"

    case :httpc.request(:get, {String.to_charlist(url), []}, [{:timeout, @fetch_timeout_ms}], []) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        content =
          body
          |> to_string()
          |> _strip_html_to_text()
          |> String.slice(0, 50_000)

        {:ok,
         %{
           url: url,
           domain: domain,
           source_type: :url,
           content: content,
           fetched_at: DateTime.utc_now() |> DateTime.to_iso8601(),
           byte_size: byte_size(to_string(body))
         }}

      {:ok, {{_, status, _}, _, _}} ->
        {:error, {:http_error, status, url}}

      {:error, reason} ->
        {:error, {:fetch_failed, reason, url}}
    end
  rescue
    e -> {:error, {:exception, e, url}}
  end

  defp _fetch_local_file(path) do
    Logger.info("[SourceFetcher] Reading local file: #{path}")

    case File.read(path) do
      {:ok, content} ->
        {:ok,
         %{
           url: path,
           domain: "local",
           source_type: :local_file,
           content: String.slice(content, 0, 50_000),
           fetched_at: DateTime.utc_now() |> DateTime.to_iso8601(),
           byte_size: byte_size(content)
         }}

      {:error, reason} ->
        {:error, {:file_read_failed, reason, path}}
    end
  end

  defp _fetch_pdf(path) do
    Logger.info("[SourceFetcher] PDF fetch not yet implemented: #{path}")

    # Placeholder — in production, would shell out to pdf skill or pdftotext
    {:ok,
     %{
       url: path,
       domain: "local",
       source_type: :pdf,
       content: "[PDF content extraction pending — use /pdf skill to pre-extract]",
       fetched_at: DateTime.utc_now() |> DateTime.to_iso8601(),
       byte_size: 0
     }}
  end

  defp _fetch_viki(query) do
    Logger.info("[SourceFetcher] VIKI query: #{query}")

    # VIKI API (when running at localhost:3033)
    url = "http://localhost:3033/api/search?q=#{URI.encode(query)}&limit=10"

    case :httpc.request(:get, {String.to_charlist(url), []}, [{:timeout, 5_000}], []) do
      {:ok, {{_, 200, _}, _, body}} ->
        content = body |> to_string() |> _viki_results_to_text()

        {:ok,
         %{
           url: "viki:#{query}",
           domain: "viki",
           source_type: :viki,
           content: content,
           fetched_at: DateTime.utc_now() |> DateTime.to_iso8601()
         }}

      _ ->
        # VIKI not running — return empty but non-failing
        {:ok,
         %{
           url: "viki:#{query}",
           domain: "viki",
           source_type: :viki,
           content: "[VIKI not running at localhost:3033]",
           fetched_at: DateTime.utc_now() |> DateTime.to_iso8601()
         }}
    end
  end

  defp _fetch_apm(path) do
    url = @apm_base <> path

    case :httpc.request(:get, {String.to_charlist(url), []}, [{:timeout, 5_000}], []) do
      {:ok, {{_, 200, _}, _, body}} ->
        {:ok,
         %{
           url: url,
           domain: "apm",
           source_type: :apm,
           content: to_string(body),
           fetched_at: DateTime.utc_now() |> DateTime.to_iso8601()
         }}

      {:ok, {{_, status, _}, _, _}} ->
        {:error, {:apm_http_error, status}}

      {:error, reason} ->
        {:error, {:apm_fetch_failed, reason}}
    end
  end

  # ── Private: Content Processing ───────────────────────────────────────────

  defp _strip_html_to_text(html) do
    html
    |> String.replace(~r/<script[^>]*>.*?<\/script>/si, " ")
    |> String.replace(~r/<style[^>]*>.*?<\/style>/si, " ")
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace(~r/&nbsp;/, " ")
    |> String.replace(~r/&amp;/, "&")
    |> String.replace(~r/&lt;/, "<")
    |> String.replace(~r/&gt;/, ">")
    |> String.replace(~r/&quot;/, "\"")
    |> String.replace(~r/\s{3,}/, "\n\n")
    |> String.trim()
  end

  defp _viki_results_to_text(json_body) do
    case Jason.decode(json_body) do
      {:ok, %{"results" => results}} ->
        results
        |> Enum.map(fn r -> "#{r["title"] || ""}\n#{r["content"] || r["summary"] || ""}" end)
        |> Enum.join("\n\n---\n\n")

      {:ok, other} ->
        inspect(other)

      {:error, _} ->
        json_body
    end
  end
end
