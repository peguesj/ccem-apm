defmodule Apm.Plugins.Lvm.ClaudePlatformLvmPlugin do
  @moduledoc """
  APM Plugin for Claude Platform LVM (Large Vision-Language Model) capabilities.

  Tracks model capabilities, context windows, and usage limits across
  Claude model variants. Delegates to ClaudeUsageStore for capability data.

  ## Actions

  - `list_models`       - List known Claude model variants with capabilities
  - `get_model_info`    - Get detailed info for a specific model
  - `check_limits`      - Check current usage against model limits
  - `model_comparison`  - Compare capabilities across models
  """

  @behaviour Apm.Plugins.PluginBehaviour

  alias Apm.ClaudeUsageStore

  @pubsub Apm.PubSub
  @lvm_topic "lvm:status"

  # Known Claude model capabilities (static reference data)
  @model_capabilities %{
    "claude-opus-4-6" => %{
      family: "claude-4",
      context_window: 200_000,
      max_output_tokens: 32_000,
      vision: true,
      tool_use: true,
      computer_use: true,
      extended_thinking: true,
      tier: "flagship"
    },
    "claude-sonnet-4-6" => %{
      family: "claude-4",
      context_window: 200_000,
      max_output_tokens: 16_000,
      vision: true,
      tool_use: true,
      computer_use: true,
      extended_thinking: true,
      tier: "balanced"
    },
    "claude-haiku-4-5" => %{
      family: "claude-4",
      context_window: 200_000,
      max_output_tokens: 8_192,
      vision: true,
      tool_use: true,
      computer_use: false,
      extended_thinking: false,
      tier: "speed"
    },
    "claude-sonnet-4-5-20250514" => %{
      family: "claude-4",
      context_window: 200_000,
      max_output_tokens: 16_000,
      vision: true,
      tool_use: true,
      computer_use: true,
      extended_thinking: true,
      tier: "balanced"
    }
  }

  # -- PluginBehaviour callbacks -----------------------------------------------

  @impl true
  @spec plugin_name() :: String.t()
  def plugin_name, do: "claude_platform_lvm"

  @impl true
  @spec plugin_description() :: String.t()
  def plugin_description,
    do: "Claude platform LVM capabilities — model info, context windows, usage limits"

  @impl true
  @spec plugin_version() :: String.t()
  def plugin_version, do: "1.0.0"

  @impl true
  @spec list_endpoints() :: [map()]
  def list_endpoints do
    [
      %{
        action: "list_models",
        description: "List all known Claude models with capabilities",
        params: %{}
      },
      %{
        action: "get_model_info",
        description: "Get info for a specific model",
        params: %{model: "string"}
      },
      %{
        action: "check_limits",
        description: "Check usage against model limits",
        params: %{project: "string"}
      },
      %{
        action: "model_comparison",
        description: "Compare models side by side",
        params: %{models: "list"}
      }
    ]
  end

  @impl true
  @spec handle_action(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def handle_action("list_models", _params, _opts) do
    models =
      Enum.map(@model_capabilities, fn {name, caps} ->
        Map.put(caps, :model, name)
      end)

    {:ok, %{models: models, count: length(models)}}
  end

  def handle_action("get_model_info", %{"model" => model}, _opts) do
    case Map.get(@model_capabilities, model) do
      nil ->
        # Check ClaudeUsageStore for dynamically recorded capabilities
        case ClaudeUsageStore.get_model_capabilities(model) do
          nil -> {:error, {:unknown_model, model}}
          caps -> {:ok, %{model: model, capabilities: caps, source: "dynamic"}}
        end

      caps ->
        dynamic = ClaudeUsageStore.get_model_capabilities(model)
        merged = if dynamic, do: Map.merge(caps, dynamic), else: caps
        {:ok, %{model: model, capabilities: merged, source: "static+dynamic"}}
    end
  end

  def handle_action("get_model_info", _params, _opts) do
    {:error, {:missing_param, "model is required"}}
  end

  def handle_action("check_limits", %{"project" => project}, _opts) do
    usage = ClaudeUsageStore.get_usage(project)
    summary = ClaudeUsageStore.get_summary()
    effort = ClaudeUsageStore.get_effort_level(project)

    limits =
      Enum.map(usage, fn {model, stats} ->
        caps =
          Map.get(@model_capabilities, model, %{
            context_window: 200_000,
            max_output_tokens: 16_000
          })

        %{
          model: model,
          input_tokens_used: Map.get(stats, :input, 0),
          output_tokens_used: Map.get(stats, :output, 0),
          context_window: Map.get(caps, :context_window, 200_000),
          max_output: Map.get(caps, :max_output_tokens, 16_000),
          utilization_pct: calculate_utilization(stats, caps)
        }
      end)

    # Broadcast status update
    Phoenix.PubSub.broadcast(
      @pubsub,
      @lvm_topic,
      {:lvm_limits_checked,
       %{
         project: project,
         effort: effort,
         checked_at: DateTime.utc_now() |> DateTime.to_iso8601()
       }}
    )

    {:ok, %{project: project, effort_level: effort, limits: limits, summary: summary}}
  end

  def handle_action("check_limits", _params, _opts) do
    {:error, {:missing_param, "project is required"}}
  end

  def handle_action("model_comparison", %{"models" => models}, _opts) when is_list(models) do
    comparison =
      Enum.map(models, fn model ->
        caps = Map.get(@model_capabilities, model, %{})
        %{model: model, capabilities: caps, known: map_size(caps) > 0}
      end)

    {:ok, %{comparison: comparison}}
  end

  def handle_action("model_comparison", _params, _opts) do
    {:error, {:missing_param, "models (list) is required"}}
  end

  def handle_action(action, _params, _opts) do
    {:error, {:unknown_action, action}}
  end

  @impl true
  @spec supervisor_children() :: [Supervisor.child_spec()]
  def supervisor_children, do: []

  @impl true
  @spec default_enabled?() :: boolean()
  def default_enabled?, do: true

  @impl true
  @spec nav_items() :: [{String.t(), String.t(), String.t() | nil}]
  def nav_items do
    [{"LVM Status", "/integrations/lvm", "hero-cpu-chip"}]
  end

  @impl true
  @spec plugin_live_module() :: module() | nil
  def plugin_live_module, do: ApmWeb.LvmStatusLive

  # -- Public API (for direct use by other modules) ----------------------------

  @doc "Return the static model capabilities map."
  @spec known_models() :: map()
  def known_models, do: @model_capabilities

  @doc "Get capabilities for a specific model (static only)."
  @spec get_capabilities(String.t()) :: map() | nil
  def get_capabilities(model), do: Map.get(@model_capabilities, model)

  # -- Private -----------------------------------------------------------------

  defp calculate_utilization(stats, caps) do
    total_tokens = Map.get(stats, :input, 0) + Map.get(stats, :output, 0)
    context = Map.get(caps, :context_window, 200_000)

    if context > 0 do
      Float.round(total_tokens / context * 100, 1)
    else
      0.0
    end
  end
end
