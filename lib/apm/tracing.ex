defmodule Apm.Tracing do
  # Author: Jeremiah Pegues <jeremiah@pegues.io>
  @moduledoc """
  Thin OpenTelemetry API wrappers for CCEM APM span kinds.

  Provides four higher-order functions that start a named OTel span,
  set the appropriate semantic-convention attributes, execute the given
  function, and end the span — regardless of whether the function raises
  or returns.

  ## Span kinds and canonical attributes

  | Function | `openinference.span.kind` | Primary attrs |
  |---|---|---|
  | `with_agent_span/3` | `"AGENT"` | `gen_ai.provider.name`, `gen_ai.agent.id`, `ccem.formation.id` |
  | `with_tool_span/3` | `"TOOL"` | `ccem.session.id` |
  | `with_llm_span/4` | `"LLM"` | `gen_ai.request.model`, `gen_ai.usage.*` |
  | `with_formation_span/3` | `"CHAIN"` | `ccem.formation.id`, `ccem.formation.wave` |

  ## Example

      iex> Apm.Tracing.with_agent_span("agent-42", "fmt-001", fn ->
      ...>   :ok
      ...> end)
      :ok

  All functions are safe no-ops when the OTel SDK is not configured — the
  `:otel_tracer` application simply returns a no-op span context.
  """

  require OpenTelemetry.Tracer, as: Tracer

  alias OpenTelemetry.SemConv.Incubating.GenAiAttributes

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Execute `fun` inside an OTel span representing a CCEM agent invocation.

  Sets the following attributes on the active span:
    - `openinference.span.kind` = `"AGENT"`
    - `gen_ai.provider.name` = `opts[:provider_name]` (default `"anthropic"`)
    - `gen_ai.agent.id` = `agent_id`
    - `gen_ai.agent.name` = `opts[:agent_name]` (optional)
    - `gen_ai.agent.description` = `opts[:agent_description]` (optional)
    - `gen_ai.agent.version` = `opts[:agent_version]` (optional)
    - `ccem.formation.id` = `formation_id`

  Pass `provider_name: "ccem"` in opts when instrumenting CCEM-internal operations
  (e.g., `AgentRegistry.register_agent/3`).

  Returns the return value of `fun`.
  """
  @spec with_agent_span(String.t(), String.t() | nil, (-> result), keyword()) :: result
        when result: term()
  def with_agent_span(agent_id, formation_id, fun, opts \\ [])
      when is_binary(agent_id) and is_function(fun, 0) do
    provider = Keyword.get(opts, :provider_name, "anthropic")

    base_attrs = %{
      :"openinference.span.kind" => "AGENT",
      :"gen_ai.provider.name" => provider,
      :"gen_ai.agent.id" => agent_id,
      :"ccem.formation.id" => formation_id || ""
    }

    optional_attrs =
      opts
      |> Keyword.take([:agent_name, :agent_description, :agent_version])
      |> Enum.reduce(%{}, fn
        {:agent_name, v}, acc when is_binary(v) ->
          Map.put(acc, :"gen_ai.agent.name", v)

        {:agent_description, v}, acc when is_binary(v) ->
          Map.put(acc, :"gen_ai.agent.description", v)

        {:agent_version, v}, acc when is_binary(v) ->
          Map.put(acc, :"gen_ai.agent.version", v)

        _, acc ->
          acc
      end)

    run_span("ccem.agent", Map.merge(base_attrs, optional_attrs), fun)
  end

  @doc """
  Execute `fun` inside an OTel span representing a Claude Code tool call.

  Sets the following attributes on the active span:
    - `openinference.span.kind` = `"TOOL"`
    - `tool.name` = `tool_name`
    - `ccem.session.id` = `session_id`

  Returns the return value of `fun`.
  """
  @spec with_tool_span(String.t(), String.t() | nil, (-> result)) :: result when result: term()
  def with_tool_span(tool_name, session_id, fun)
      when is_binary(tool_name) and is_function(fun, 0) do
    attrs = %{
      :"openinference.span.kind" => "TOOL",
      :"tool.name" => tool_name,
      :"ccem.session.id" => session_id || ""
    }

    run_span("ccem.tool", attrs, fun)
  end

  @doc """
  Execute `fun` inside an OTel span representing a Claude LLM inference call.

  Sets the following attributes on the active span:
    - `openinference.span.kind` = `"LLM"`
    - `gen_ai.request.model` = `model`
    - `gen_ai.usage.input_tokens` = `input_tokens`
    - `gen_ai.usage.output_tokens` = `output_tokens`
    - `gen_ai.usage.cache_read.input_tokens` = `opts[:cache_read_tokens]` (default 0)
    - `gen_ai.usage.cache_creation.input_tokens` = `opts[:cache_creation_tokens]` (default 0)

  `opts` is an optional keyword list accepted as the fourth argument for cache token counts.

  Returns the return value of `fun`.
  """
  @spec with_llm_span(
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          (-> result),
          keyword()
        ) :: result
        when result: term()
  def with_llm_span(model, input_tokens, output_tokens, fun, opts \\ [])
      when is_binary(model) and is_integer(input_tokens) and is_integer(output_tokens) and
             is_function(fun, 0) do
    cache_read = Keyword.get(opts, :cache_read_tokens, 0)
    cache_creation = Keyword.get(opts, :cache_creation_tokens, 0)

    attrs = %{
      :"openinference.span.kind" => "LLM",
      GenAiAttributes.gen_ai_request_model() => model,
      GenAiAttributes.gen_ai_usage_input_tokens() => input_tokens,
      GenAiAttributes.gen_ai_usage_output_tokens() => output_tokens,
      :"gen_ai.usage.cache_read.input_tokens" => cache_read,
      :"gen_ai.usage.cache_creation.input_tokens" => cache_creation
    }

    run_span("ccem.llm", attrs, fun)
  end

  @doc """
  Execute `fun` inside an OTel span representing a CCEM formation wave.

  Sets the following attributes on the active span:
    - `openinference.span.kind` = `"CHAIN"`
    - `ccem.formation.id` = `formation_id`
    - `ccem.formation.wave` = `wave` (integer)

  Returns the return value of `fun`.
  """
  @spec with_formation_span(String.t(), non_neg_integer(), (-> result)) :: result
        when result: term()
  def with_formation_span(formation_id, wave, fun)
      when is_binary(formation_id) and is_integer(wave) and is_function(fun, 0) do
    attrs = %{
      :"openinference.span.kind" => "CHAIN",
      :"ccem.formation.id" => formation_id,
      :"ccem.formation.wave" => wave
    }

    run_span("ccem.formation", attrs, fun)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # `run_span/3` delegates to `:otel_tracer.with_span/4` (Erlang API) so it can
  # accept an arbitrary zero-arity function without needing a macro context.
  # Attributes are set inside the span body so they are attached before any
  # child span is created by `fun`.
  @spec run_span(String.t(), map(), (-> result)) :: result when result: term()
  defp run_span(span_name, attrs, fun) do
    tracer = :opentelemetry.get_application_tracer(__MODULE__)

    :otel_tracer.with_span(tracer, span_name, %{}, fn span_ctx ->
      OpenTelemetry.Span.set_attributes(span_ctx, attrs)
      fun.()
    end)
  end
end
