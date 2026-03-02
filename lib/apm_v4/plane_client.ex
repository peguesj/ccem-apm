defmodule ApmV4.PlaneClient do
  @moduledoc """
  HTTP client for the Plane project management API.
  Uses Erlang :httpc (no external deps). Reads API key from the CSV file at
  ~/Developer/plane/.claude/claude-code-helper-remote-plane-api-pat.csv
  """
  require Logger

  @base_url "https://plane.lgtm.build/api/v1/workspaces/lgtm"
  @ccem_project_id "a20e1d2e-3139-406e-ae03-dc6d1d8cb995"
  @key_file_path "~/Developer/plane/.claude/claude-code-helper-remote-plane-api-pat.csv"

  # --- Public API ---

  @spec list_projects() :: {:ok, [map()]} | {:error, term()}
  def list_projects do
    get("/projects/")
  end

  @spec list_issues(String.t(), map()) :: {:ok, [map()]} | {:error, term()}
  def list_issues(project_id \\ @ccem_project_id, _filter \\ %{}) do
    get("/projects/#{project_id}/issues/?per_page=100")
  end

  @spec create_issue(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def create_issue(project_id \\ @ccem_project_id, attrs) do
    post("/projects/#{project_id}/issues/", attrs)
  end

  @spec update_issue(String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def update_issue(project_id \\ @ccem_project_id, issue_id, attrs) do
    patch("/projects/#{project_id}/issues/#{issue_id}/", attrs)
  end

  @spec check_connection() :: {:ok, String.t()} | {:error, String.t()}
  def check_connection do
    case get("/projects/") do
      {:ok, _} -> {:ok, "Connected to #{@base_url}"}
      {:error, reason} -> {:error, "Cannot reach Plane: #{inspect(reason)}"}
    end
  end

  # --- Private HTTP helpers ---

  defp get(path) do
    url = String.to_charlist("#{@base_url}#{path}")
    headers = build_headers()
    case :httpc.request(:get, {url, headers}, [{:timeout, 10_000}], []) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        decode_body(body)
      {:ok, {{_, status, _}, _headers, body}} ->
        {:error, %{status: status, body: to_string(body)}}
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp post(path, body) do
    url = String.to_charlist("#{@base_url}#{path}")
    headers = build_headers()
    encoded = Jason.encode!(body)
    case :httpc.request(:post, {url, headers, ~c"application/json", String.to_charlist(encoded)}, [{:timeout, 10_000}], []) do
      {:ok, {{_, status, _}, _headers, resp_body}} when status in 200..299 ->
        decode_body(resp_body)
      {:ok, {{_, status, _}, _headers, resp_body}} ->
        {:error, %{status: status, body: to_string(resp_body)}}
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp patch(path, body) do
    url = String.to_charlist("#{@base_url}#{path}")
    headers = build_headers()
    encoded = Jason.encode!(body)
    case :httpc.request(:patch, {url, headers, ~c"application/json", String.to_charlist(encoded)}, [{:timeout, 10_000}], []) do
      {:ok, {{_, status, _}, _headers, resp_body}} when status in 200..299 ->
        decode_body(resp_body)
      {:ok, {{_, status, _}, _headers, resp_body}} ->
        {:error, %{status: status, body: to_string(resp_body)}}
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_headers do
    api_key = get_api_key()
    [{~c"X-Api-Key", String.to_charlist(api_key)}]
  end

  defp decode_body(body) do
    case Jason.decode(to_string(body)) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _} -> {:ok, %{raw: to_string(body)}}
    end
  end

  @spec get_api_key() :: String.t()
  def get_api_key do
    path = Path.expand(@key_file_path)
    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.drop(1)
        |> List.first("")
        |> String.split(",")
        |> List.last("")
        |> String.trim()
      {:error, _} ->
        Logger.warning("[PlaneClient] Cannot read API key from #{path}")
        System.get_env("PLANE_API_KEY", "plane_api_73588ec6f1c34e09b389b8565b7b63c9")
    end
  end
end
