defmodule Apm.Plugins.OpenDesign.OpenDesignClient do
  @moduledoc """
  Lightweight HTTP client for the open-design daemon REST API.

  The daemon runs locally (default port 17456). All requests are fire-and-return
  using Erlang's built-in `:httpc`. No external dependencies required.

  Open Design daemon API reference: https://github.com/nexu-io/open-design
  Key endpoints used:
    GET  /api/health            — daemon liveness + version
    GET  /api/version           — version string
    GET  /api/agents            — detected agent CLIs on the machine
    GET  /api/skills            — skill catalog from ~/.claude/skills/ + ./skills/
    GET  /api/skills/:id        — single skill by ID
    GET  /api/design-systems    — design system catalog
    GET  /api/design-systems/:id — single design system
    GET  /api/projects          — all projects
    GET  /api/projects/:id      — single project
    GET  /api/templates         — artifact templates
  """

  require Logger

  @default_port 17456
  @timeout_ms 5_000

  # ── Public API ────────────────────────────────────────────────────────────────

  @spec base_url(non_neg_integer()) :: String.t()
  def base_url(port \\ @default_port), do: "http://localhost:#{port}"

  @spec health(non_neg_integer()) :: {:ok, map()} | {:error, term()}
  def health(port \\ @default_port), do: get(port, "/api/health")

  @spec version(non_neg_integer()) :: {:ok, map()} | {:error, term()}
  def version(port \\ @default_port), do: get(port, "/api/version")

  @spec list_agents(non_neg_integer()) :: {:ok, list()} | {:error, term()}
  def list_agents(port \\ @default_port) do
    case get(port, "/api/agents") do
      {:ok, %{"agents" => agents}} -> {:ok, agents}
      {:ok, agents} when is_list(agents) -> {:ok, agents}
      other -> other
    end
  end

  @spec list_skills(non_neg_integer()) :: {:ok, list()} | {:error, term()}
  def list_skills(port \\ @default_port) do
    case get(port, "/api/skills") do
      {:ok, %{"skills" => skills}} -> {:ok, skills}
      {:ok, skills} when is_list(skills) -> {:ok, skills}
      other -> other
    end
  end

  @spec get_skill(String.t(), non_neg_integer()) :: {:ok, map()} | {:error, term()}
  def get_skill(id, port \\ @default_port), do: get(port, "/api/skills/#{URI.encode(id)}")

  @spec list_design_systems(non_neg_integer()) :: {:ok, list()} | {:error, term()}
  def list_design_systems(port \\ @default_port) do
    case get(port, "/api/design-systems") do
      {:ok, %{"designSystems" => ds}} -> {:ok, ds}
      {:ok, %{"design_systems" => ds}} -> {:ok, ds}
      {:ok, ds} when is_list(ds) -> {:ok, ds}
      other -> other
    end
  end

  @spec get_design_system(String.t(), non_neg_integer()) :: {:ok, map()} | {:error, term()}
  def get_design_system(id, port \\ @default_port),
    do: get(port, "/api/design-systems/#{URI.encode(id)}")

  @spec list_projects(non_neg_integer()) :: {:ok, list()} | {:error, term()}
  def list_projects(port \\ @default_port) do
    case get(port, "/api/projects") do
      {:ok, %{"projects" => ps}} -> {:ok, ps}
      {:ok, ps} when is_list(ps) -> {:ok, ps}
      other -> other
    end
  end

  @spec get_project(String.t(), non_neg_integer()) :: {:ok, map()} | {:error, term()}
  def get_project(id, port \\ @default_port), do: get(port, "/api/projects/#{URI.encode(id)}")

  @spec list_templates(non_neg_integer()) :: {:ok, list()} | {:error, term()}
  def list_templates(port \\ @default_port) do
    case get(port, "/api/templates") do
      {:ok, %{"templates" => ts}} -> {:ok, ts}
      {:ok, ts} when is_list(ts) -> {:ok, ts}
      other -> other
    end
  end

  @spec reachable?(non_neg_integer()) :: boolean()
  def reachable?(port \\ @default_port) do
    case health(port) do
      {:ok, _} -> true
      _ -> false
    end
  end

  # ── HTTP primitives ───────────────────────────────────────────────────────────

  @spec get(non_neg_integer(), String.t()) :: {:ok, term()} | {:error, term()}
  defp get(port, path) do
    url = ~c"http://localhost:#{port}#{path}"

    :httpc.request(:get, {url, []}, [{:timeout, @timeout_ms}], [])
    |> parse_response()
  end

  @spec parse_response(term()) :: {:ok, term()} | {:error, term()}
  defp parse_response({:ok, {{_, status, _}, _headers, body}}) when status in 200..299 do
    body_str = if is_list(body), do: List.to_string(body), else: body

    case Jason.decode(body_str) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _} -> {:ok, body_str}
    end
  end

  defp parse_response({:ok, {{_, status, _}, _, body}}) do
    Logger.debug("[OpenDesignClient] HTTP #{status}: #{inspect(body)}")
    {:error, {:http_error, status}}
  end

  defp parse_response({:error, {:failed_connect, _}}) do
    {:error, :daemon_unreachable}
  end

  defp parse_response({:error, reason}) do
    {:error, reason}
  end
end
