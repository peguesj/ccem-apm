defmodule ApmV4Web.PageController do
  use ApmV4Web, :controller

  def home(conn, _params) do
    render(conn, :home)
  end

  @doc """
  Serves the Scalar API Reference UI pointing at the OpenAPI spec.
  Self-contained HTML page — no template needed.
  """
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
            title: 'CCEM APM v4 API Reference'
          }
        })
      </script>
    </body>
    </html>
    """)
  end
end
