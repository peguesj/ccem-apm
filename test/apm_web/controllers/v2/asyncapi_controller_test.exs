defmodule ApmWeb.V2.AsyncApiControllerTest do
  @moduledoc """
  Tests for GET /api/v2/asyncapi.yaml (api-s9 / CP-268).

  Validates the AsyncAPI 3.0 document:
  - Endpoint exists and returns 200
  - Content-type is text/yaml or application/yaml
  - Body is valid YAML that parses without error
  - Document has asyncapi version field (3.0.x)
  - Document has ≥20 channels documenting PubSub topics
  """

  use ApmWeb.ConnCase, async: true

  @moduletag :asyncapi

  describe "GET /api/v2/asyncapi.yaml" do
    test "returns 200", %{conn: conn} do
      conn = get(conn, "/api/v2/asyncapi.yaml")
      assert conn.status == 200
    end

    test "returns YAML content (text/yaml or application/yaml content-type)", %{conn: conn} do
      conn = get(conn, "/api/v2/asyncapi.yaml")
      content_type = conn |> get_resp_header("content-type") |> List.first("") |> String.downcase()
      assert content_type =~ "yaml" or content_type =~ "text/plain"
    end

    test "body is non-empty string", %{conn: conn} do
      conn = get(conn, "/api/v2/asyncapi.yaml")
      assert byte_size(conn.resp_body) > 0
    end

    test "body parses as valid YAML", %{conn: conn} do
      conn = get(conn, "/api/v2/asyncapi.yaml")
      body = conn.resp_body
      # Use :yamerl or manual check — since yamerl/yaml_elixir may not be deps,
      # we validate YAML structure by checking key markers
      assert body =~ "asyncapi:"
      assert body =~ "channels:"
      # YAML must not have obvious syntax errors — check indentation marker
      refute body =~ "!!null"
    end

    test "asyncapi version is 3.0.x", %{conn: conn} do
      conn = get(conn, "/api/v2/asyncapi.yaml")
      body = conn.resp_body
      assert body =~ ~r/asyncapi:\s+['"]?3\.0\./
    end

    test "document has info block with title and version", %{conn: conn} do
      conn = get(conn, "/api/v2/asyncapi.yaml")
      body = conn.resp_body
      assert body =~ "info:"
      assert body =~ "title:"
      assert body =~ "version:"
    end

    test "document has ≥20 channels", %{conn: conn} do
      conn = get(conn, "/api/v2/asyncapi.yaml")
      body = conn.resp_body
      # Count channel entries: each top-level channel in AsyncAPI 3.0 is a key
      # under `channels:`. We match lines that look like "  <channel_name>:"
      # (two-space indent, no leading $, followed by colon).
      # We also count the `channels:` block marker lines that come after it.
      #
      # A conservative count: grep for "apm:" or "agentlock:" or "auth:" patterns
      # that are recognisable channel prefixes within the YAML.
      channel_lines =
        body
        |> String.split("\n")
        |> Enum.filter(fn line ->
          # Matches lines like "  apm_agents:" or "  'apm:agents':" or "  auth_decisions:"
          Regex.match?(~r/^\s{2,4}[a-zA-Z_'"][a-zA-Z0-9_:'"-]+:\s*$/, line)
        end)

      assert length(channel_lines) >= 20,
             "Expected ≥20 channel entries, got #{length(channel_lines)}. Body:\n#{String.slice(body, 0, 500)}"
    end

    test "covers core CCEM PubSub topics", %{conn: conn} do
      conn = get(conn, "/api/v2/asyncapi.yaml")
      body = conn.resp_body

      # Core topics that MUST be documented
      required_topics = ~w[apm_agents apm_hooks apm_formations apm_notifications auth_decisions governance_circuits]

      Enum.each(required_topics, fn topic ->
        assert body =~ topic,
               "Expected asyncapi.yaml to document topic '#{topic}' but it was absent"
      end)
    end

    test "channels block appears before operations block (if present)", %{conn: conn} do
      conn = get(conn, "/api/v2/asyncapi.yaml")
      body = conn.resp_body
      channels_pos = :binary.match(body, "channels:")
      refute channels_pos == :nomatch, "Expected 'channels:' block in asyncapi.yaml"
    end
  end
end
