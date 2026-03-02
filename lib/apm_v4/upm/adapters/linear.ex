defmodule ApmV4.UPM.Adapters.Linear do
  @moduledoc """
  PM adapter for Linear issue tracking platform.
  Uses :httpc POST with GraphQL queries to interact with Linear API.
  """
  @behaviour ApmV4.UPM.Adapters.PMAdapter

  require Logger

  @linear_api "https://api.linear.app/graphql"

  @impl true
  def list_issues(integration) do
    team_id = integration.project_key

    query = """
    query {
      issues(filter: { team: { id: { eq: "#{team_id}" } } }) {
        nodes {
          id
          title
          state { name }
          priority
          url
          completedAt
        }
      }
    }
    """

    case graphql_request(integration.api_key, query) do
      {:ok, %{"data" => %{"issues" => %{"nodes" => nodes}}}} ->
        {:ok, nodes}

      {:ok, body} ->
        Logger.warning("[Linear] Unexpected response: #{inspect(body)}")
        {:ok, []}

      {:error, _} = err ->
        err
    end
  end

  @impl true
  def create_issue(integration, attrs) do
    team_id = integration.project_key
    title = Map.get(attrs, :title) || Map.get(attrs, "title") || "Untitled"

    mutation = """
    mutation {
      issueCreate(input: { teamId: "#{team_id}", title: "#{escape(title)}" }) {
        issue { id title url }
      }
    }
    """

    case graphql_request(integration.api_key, mutation) do
      {:ok, %{"data" => %{"issueCreate" => %{"issue" => issue}}}} ->
        {:ok, issue}

      {:ok, body} ->
        {:error, "Unexpected Linear response: #{inspect(body)}"}

      {:error, _} = err ->
        err
    end
  end

  @impl true
  def update_issue(integration, issue_id, attrs) do
    state_id = Map.get(attrs, :state_id) || Map.get(attrs, "state_id")

    state_clause =
      if state_id, do: ~s(stateId: "#{state_id}"), else: ""

    mutation = """
    mutation {
      issueUpdate(id: "#{issue_id}", input: { #{state_clause} }) {
        issue { id title url }
      }
    }
    """

    case graphql_request(integration.api_key, mutation) do
      {:ok, %{"data" => %{"issueUpdate" => %{"issue" => issue}}}} ->
        {:ok, issue}

      {:ok, body} ->
        {:error, "Unexpected Linear response: #{inspect(body)}"}

      {:error, _} = err ->
        err
    end
  end

  @impl true
  def normalize(raw) do
    %{
      platform_id: to_string(raw["id"] || ""),
      platform_key: raw["identifier"] || raw["id"] || "",
      platform_url: raw["url"],
      title: raw["title"] || "Untitled",
      status: normalize_state(raw["state"]),
      priority: normalize_priority(raw["priority"]),
      passes: raw["completedAt"] != nil
    }
  end

  @impl true
  def test_connection(integration) do
    query = "query { viewer { id name } }"

    case graphql_request(integration.api_key, query) do
      {:ok, %{"data" => %{"viewer" => %{"name" => name}}}} ->
        {:ok, "Linear connected as #{name}"}

      {:ok, body} ->
        {:error, "Unexpected response: #{inspect(body)}"}

      {:error, reason} ->
        {:error, "Linear connection failed: #{inspect(reason)}"}
    end
  end

  # Private helpers

  defp graphql_request(api_key, query) do
    url = String.to_charlist(@linear_api)
    body = Jason.encode!(%{query: query})
    headers = [
      {~c"Content-Type", ~c"application/json"},
      {~c"Authorization", String.to_charlist(api_key || "")}
    ]

    case :httpc.request(:post, {url, headers, ~c"application/json", String.to_charlist(body)}, [], []) do
      {:ok, {{_, 200, _}, _, resp_body}} ->
        Jason.decode(List.to_string(resp_body))

      {:ok, {{_, status, _}, _, resp_body}} ->
        {:error, "HTTP #{status}: #{List.to_string(resp_body)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_state(%{"name" => "Done"}), do: :done
  defp normalize_state(%{"name" => "In Progress"}), do: :in_progress
  defp normalize_state(%{"name" => "Todo"}), do: :todo
  defp normalize_state(%{"name" => "Cancelled"}), do: :cancelled
  defp normalize_state(_), do: :backlog

  defp normalize_priority(0), do: :none
  defp normalize_priority(1), do: :urgent
  defp normalize_priority(2), do: :high
  defp normalize_priority(3), do: :medium
  defp normalize_priority(4), do: :low
  defp normalize_priority(_), do: :none

  defp escape(str), do: String.replace(str, ~s("), ~s(\\"))
end
