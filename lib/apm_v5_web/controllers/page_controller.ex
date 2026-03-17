defmodule ApmV5Web.PageController do
  use ApmV5Web, :controller

  def home(conn, _params) do
    render(conn, :home)
  end

  @doc """
  Serves the Scalar API Reference UI pointing at the OpenAPI spec.
  Self-contained HTML page — no template needed.
  """
  def upm_redirect(conn, _params) do
    redirect(conn, to: "/workflow/upm")
  end

  @doc """
  Redirects /docs/upm/status to the proper /showcase LiveView.

  The old `upm_showcase/2` action (which served the standalone static HTML with
  asset-path rewriting) is kept for backward-compatibility but is no longer
  routed.
  """
  def redirect_to_showcase(conn, _params) do
    redirect(conn, to: ~p"/showcase")
  end

  @doc """
  Serves the CCEM Showcase at /docs/upm/status.

  Reads priv/static/showcase/index.html, injects window.CCEM_APM_BASE_URL
  before the showcase JS loads so the dashboard connects to the correct APM
  server in any environment (local dev on :3032, staging, production, etc.).

  Asset paths (styles.css, showcase.js) are rewritten to /showcase/* so they
  resolve correctly when the page is served from /docs/upm/status.
  """
  def upm_showcase(conn, _params) do
    showcase_path = Application.app_dir(:apm_v5, "priv/static/showcase/index.html")

    raw_html =
      case File.read(showcase_path) do
        {:ok, content} -> content
        {:error, _} -> fallback_showcase_html()
      end

    # Derive APM base URL: prefer APM_BASE_URL env var, fall back to current host+port
    apm_base =
      System.get_env("APM_BASE_URL") ||
        "#{conn.scheme}://#{conn.host}#{if conn.port not in [80, 443], do: ":#{conn.port}", else: ""}"

    # Inject window.CCEM_APM_BASE_URL before </head>
    env_script = """
    <script>
      // Injected by CCEM APM at /docs/upm/status
      // Overrides the hardcoded localhost default in showcase.js
      window.CCEM_APM_BASE_URL = '#{apm_base}';
    </script>
    """

    # Rewrite relative asset paths to /showcase/* so they resolve from /docs/upm/status
    patched_html =
      raw_html
      |> String.replace(~s(href="styles.css"), ~s(href="/showcase/styles.css"))
      |> String.replace(~s(src="showcase.js"), ~s(src="/showcase/showcase.js"))
      |> String.replace("</head>", env_script <> "</head>")

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, patched_html)
  end

  defp fallback_showcase_html do
    """
    <!DOCTYPE html>
    <html lang="en">
    <head><meta charset="UTF-8"><title>CCEM Showcase</title></head>
    <body style="background:#0f0f0f;color:#fff;font-family:monospace;padding:2rem;">
      <h1>CCEM Showcase</h1>
      <p>Showcase assets not found. Run <code>mix phx.digest</code> or ensure
         <code>priv/static/showcase/</code> exists.</p>
      <p><a href="/api/status" style="color:#60a5fa;">/api/status</a></p>
    </body>
    </html>
    """
  end

  def api_docs(conn, _params) do
    html(conn, """
    <!DOCTYPE html>
    <html lang="en" data-theme="dark">
    <head>
      <meta charset="utf-8" />
      <meta name="viewport" content="width=device-width, initial-scale=1" />
      <title>CCEM APM API Reference</title>
      <style>
        body { margin: 0; background: #1d232a; }
      </style>
    </head>
    <body>
      <div id="scalar-api"></div>
      <script src="https://cdn.jsdelivr.net/npm/@scalar/api-reference"></script>
      <script>
        Scalar.createApiReference('#scalar-api', {
          url: '/api/v2/openapi.json',
          theme: 'purple',
          darkMode: true,
          layout: 'modern',
          hideDownloadButton: false,
          metaData: {
            title: 'CCEM APM API Reference'
          }
        })
      </script>
    </body>
    </html>
    """)
  end
end
