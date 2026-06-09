defmodule ApmWeb.UsageController do
  @moduledoc """
  REST API for Claude model/token usage tracking.

  Provides read and write access to ClaudeUsageStore:
    GET    /api/usage                  — all usage data
    GET    /api/usage/summary          — aggregated summary with effort levels
    GET    /api/usage/project/:name    — per-project breakdown
    POST   /api/usage/record           — record a usage event
    DELETE /api/usage/project/:name    — reset counters for a project

  Broadcasts PubSub events on mutations to `"apm:usage"` topic.
  """

  use ApmWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias ApmWeb.Schemas
  alias OpenApiSpex.Schema
  alias Apm.ClaudeUsageStore

  operation(:index,
    summary: "Get all usage data",
    description: "Returns all Claude model/token usage data keyed by project then model.",
    tags: ["Usage"],
    responses: [
      ok: {"Usage data", "application/json", Schemas.OkResponse}
    ]
  )

  operation(:summary,
    summary: "Usage summary",
    description: "Returns aggregated totals, model breakdown, and per-project effort levels.",
    tags: ["Usage"],
    responses: [
      ok: {"Usage summary", "application/json", Schemas.OkResponse}
    ]
  )

  operation(:project,
    summary: "Per-project usage",
    description: "Returns usage data and effort level for a single project.",
    tags: ["Usage"],
    parameters: [
      name: [in: :path, type: :string, required: true, description: "Project name"]
    ],
    responses: [
      ok: {"Project usage", "application/json", Schemas.OkResponse}
    ]
  )

  operation(:record,
    summary: "Record usage event",
    description: "Records a Claude model usage event (tokens, tool_calls) for a project.",
    tags: ["Usage"],
    request_body:
      {"Usage event payload", "application/json",
       %Schema{
         type: :object,
         properties: %{
           project: %Schema{type: :string, description: "Project name", default: "unknown"},
           model: %Schema{type: :string, description: "Model ID", example: "claude-sonnet-4-6"},
           input_tokens: %Schema{type: :integer, description: "Input token count"},
           output_tokens: %Schema{type: :integer, description: "Output token count"},
           cache_tokens: %Schema{type: :integer, description: "Cache token count"},
           tool_calls: %Schema{type: :integer, description: "Number of tool calls"}
         }
       }, required: true},
    responses: [
      created: {"Usage recorded", "application/json", Schemas.OkResponse}
    ]
  )

  operation(:limits,
    summary: "Model capability limits",
    description:
      "Returns model capability limits with optional utilization data if `project` is specified.",
    tags: ["Usage"],
    parameters: [
      project: [
        in: :query,
        type: :string,
        required: false,
        description: "Project name for utilization data"
      ]
    ],
    responses: [
      ok: {"Model limits", "application/json", Schemas.OkResponse}
    ]
  )

  operation(:reset,
    summary: "Reset project usage",
    description: "Resets all usage counters for a project.",
    tags: ["Usage"],
    parameters: [
      name: [in: :path, type: :string, required: true, description: "Project name"]
    ],
    responses: [
      ok: {"Usage reset", "application/json", Schemas.OkResponse}
    ]
  )

  # Catch-all for any action not explicitly annotated above.
  def open_api_operation(_action), do: nil

  @pubsub Apm.PubSub
  @topic "apm:usage"

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

    Phoenix.PubSub.broadcast(
      @pubsub,
      @topic,
      {:usage_recorded,
       %{
         project: project,
         model: model,
         effort_level: effort,
         input_tokens: usage.input,
         output_tokens: usage.output
       }}
    )

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

  @doc "GET /api/usage/limits — model capability limits with current utilization."
  @spec limits(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def limits(conn, params) do
    project = Map.get(params, "project")

    model_caps = Apm.Plugins.Lvm.ClaudePlatformLvmPlugin.known_models()
    dynamic_caps = ClaudeUsageStore.get_all_model_capabilities()

    # Merge static + dynamic capabilities
    all_caps =
      Map.merge(model_caps, dynamic_caps, fn _k, static, dynamic ->
        Map.merge(static, dynamic)
      end)

    # If project specified, add utilization data
    limits =
      if project do
        usage = ClaudeUsageStore.get_usage(project)

        Enum.map(all_caps, fn {model, caps} ->
          model_usage = Map.get(usage, model, %{})

          %{
            model: model,
            capabilities: caps,
            usage: %{
              input_tokens: Map.get(model_usage, :input_tokens, 0),
              output_tokens: Map.get(model_usage, :output_tokens, 0),
              tool_calls: Map.get(model_usage, :tool_calls, 0)
            },
            utilization_pct: calc_utilization(model_usage, caps)
          }
        end)
      else
        Enum.map(all_caps, fn {model, caps} ->
          %{model: model, capabilities: caps}
        end)
      end

    json(conn, %{ok: true, limits: limits, model_count: length(limits)})
  end

  @doc "DELETE /api/usage/project/:name — reset all counters for a project."
  @spec reset(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def reset(conn, %{"name" => name}) do
    :ok = ClaudeUsageStore.reset_project(name)

    Phoenix.PubSub.broadcast(@pubsub, @topic, {:usage_reset, %{project: name}})

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

  defp calc_utilization(usage, caps) do
    total = Map.get(usage, :input_tokens, 0) + Map.get(usage, :output_tokens, 0)
    context = Map.get(caps, :context_window, 200_000)

    if context > 0 do
      Float.round(total / context * 100, 1)
    else
      0.0
    end
  end
end
