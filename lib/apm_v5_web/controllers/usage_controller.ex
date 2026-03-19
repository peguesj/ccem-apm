defmodule ApmV5Web.UsageController do
  @moduledoc """
  REST API for Claude model/token usage tracking.

  Provides read and write access to ClaudeUsageStore:
    GET    /api/usage                  — all usage data
    GET    /api/usage/summary          — aggregated summary with effort levels
    GET    /api/usage/project/:name    — per-project breakdown
    POST   /api/usage/record           — record a usage event
    DELETE /api/usage/project/:name    — reset counters for a project
  """

  use ApmV5Web, :controller

  alias ApmV5.ClaudeUsageStore

  @doc "GET /api/usage — return all usage data keyed by project then model."
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    json(conn, %{ok: true, usage: ClaudeUsageStore.get_all_usage()})
  end

  @doc "GET /api/usage/summary — aggregated totals, model breakdown, per-project effort levels."
  @spec summary(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def summary(conn, _params) do
    json(conn, %{ok: true, summary: ClaudeUsageStore.get_summary()})
  end

  @doc "GET /api/usage/project/:name — usage data for a single project."
  @spec project(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def project(conn, %{"name" => name}) do
    usage = ClaudeUsageStore.get_usage(name)
    effort = ClaudeUsageStore.get_effort_level(name)

    json(conn, %{
      ok: true,
      project: name,
      effort_level: effort,
      usage: usage
    })
  end

  @doc """
  POST /api/usage/record — record a usage event.

  Expected body:
    {
      "project":       "ccem",
      "model":         "claude-sonnet-4-6",
      "input_tokens":  1000,
      "output_tokens": 250,
      "cache_tokens":  0,
      "tool_calls":    1
    }
  """
  @spec record(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def record(conn, params) do
    project = Map.get(params, "project", "unknown")
    model = Map.get(params, "model", "claude-sonnet-4-6")

    usage = %{
      input: parse_int(params["input_tokens"]),
      output: parse_int(params["output_tokens"]),
      cache: parse_int(params["cache_tokens"]),
      tool_calls: parse_int(params["tool_calls"])
    }

    :ok = ClaudeUsageStore.record_usage(project, model, usage)

    updated = ClaudeUsageStore.get_usage(project)
    effort = ClaudeUsageStore.get_effort_level(project)

    conn
    |> put_status(201)
    |> json(%{
      ok: true,
      project: project,
      model: model,
      effort_level: effort,
      usage: updated
    })
  end

  @doc "DELETE /api/usage/project/:name — reset all counters for a project."
  @spec reset(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def reset(conn, %{"name" => name}) do
    :ok = ClaudeUsageStore.reset_project(name)
    json(conn, %{ok: true, project: name, message: "Usage data reset"})
  end

  # -------------------------------------------------------------------------
  # Private helpers
  # -------------------------------------------------------------------------

  defp parse_int(nil), do: 0
  defp parse_int(v) when is_integer(v), do: v
  defp parse_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp parse_int(_), do: 0
end
