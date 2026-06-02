defmodule Apm.Auth.OpaClient do
  @moduledoc """
  HTTP client for the OPA (Open Policy Agent) sidecar (auth-v10.1-s1 / CP-291).

  Wraps the OPA REST API v1 (`POST /v1/data/{package}/{rule}`) with a minimal
  ~30-line surface area.  Uses Erlang `:httpc` (stdlib) — no external HTTP dep
  required — consistent with the rest of the CCEM APM codebase.

  ## Configuration

      config :apm, Apm.Auth.OpaClient,
        base_url: "http://localhost:8181",
        timeout_ms: 2_000

  Default `base_url` is `http://localhost:8181` (standard OPA sidecar port).

  ## OPA decision endpoint

  `POST /v1/data/{package}/{rule}` with JSON body `{"input": {...}}`.

  OPA responds:

      {"result": true}   # rule matched → policy allows
      {"result": false}  # rule not matched → policy denies
      {}                 # undefined rule → treated as false (deny-safe)

  ## Usage

      # Evaluate time-of-day policy
      case Apm.Auth.OpaClient.evaluate("apm/agentlock/time_of_day", "allow", %{
        tool_name: "Bash",
        hour: 14,
        role: "agent"
      }) do
        {:ok, true}  -> :allowed
        {:ok, false} -> :denied
        {:error, reason} -> {:error, reason}
      end

  ## Health check

      Apm.Auth.OpaClient.health()
      #=> :ok | {:error, reason}

  """

  require Logger

  @default_base_url "http://localhost:8181"
  @default_timeout_ms 2_000

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Evaluate an OPA policy rule for the given input.

  `package_rule` is the URL path fragment after `/v1/data/`, e.g.:
    - `"apm/agentlock/time_of_day"`
    - `"apm/agentlock/formation_role"`

  Returns `{:ok, boolean()}` or `{:error, reason}`.

  An undefined rule (empty OPA result `{}`) is treated as `false` (deny-safe).
  """
  @spec evaluate(String.t(), String.t(), map()) ::
          {:ok, boolean()} | {:error, term()}
  def evaluate(package_rule, rule_key \\ "allow", input) when is_map(input) do
    url = "#{base_url()}/v1/data/#{package_rule}"
    body = Jason.encode!(%{"input" => input})

    case post_json(url, body) do
      {:ok, response_body} ->
        case Jason.decode(response_body) do
          {:ok, %{"result" => result}} when is_boolean(result) ->
            {:ok, result}

          {:ok, %{"result" => %{} = result}} ->
            # Nested result map — look up the specific rule key
            {:ok, Map.get(result, rule_key, false)}

          {:ok, %{}} ->
            # Undefined rule (OPA returns empty object)
            Logger.debug("[OpaClient] Undefined rule #{package_rule} — treating as false")
            {:ok, false}

          {:error, decode_err} ->
            Logger.warning("[OpaClient] JSON decode error: #{inspect(decode_err)}")
            {:error, {:decode_error, decode_err}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Health check against the OPA sidecar.

  GETs `/health` and returns `:ok` if the sidecar responds 200.
  """
  @spec health() :: :ok | {:error, term()}
  def health do
    url = "#{base_url()}/health"

    case get_request(url) do
      {:ok, _body} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Returns the configured OPA base URL."
  @spec base_url() :: String.t()
  def base_url do
    Application.get_env(:apm, __MODULE__, [])
    |> Keyword.get(:base_url, @default_base_url)
  end

  @doc "Returns the configured request timeout in ms."
  @spec timeout_ms() :: non_neg_integer()
  def timeout_ms do
    Application.get_env(:apm, __MODULE__, [])
    |> Keyword.get(:timeout_ms, @default_timeout_ms)
  end

  # ---------------------------------------------------------------------------
  # Private HTTP helpers
  # ---------------------------------------------------------------------------

  defp post_json(url, body) do
    url_charlist = String.to_charlist(url)
    headers = [{~c"content-type", ~c"application/json"}]
    body_charlist = String.to_charlist(body)
    opts = [{:timeout, timeout_ms()}]

    case :httpc.request(:post, {url_charlist, headers, ~c"application/json", body_charlist}, opts, []) do
      {:ok, {{_version, 200, _reason}, _headers, resp_body}} ->
        {:ok, List.to_string(resp_body)}

      {:ok, {{_version, status, _reason}, _headers, resp_body}} ->
        Logger.warning("[OpaClient] POST #{url} → HTTP #{status}: #{inspect(resp_body)}")
        {:error, {:http_error, status}}

      {:error, reason} ->
        Logger.warning("[OpaClient] POST #{url} failed: #{inspect(reason)}")
        {:error, {:connection_error, reason}}
    end
  end

  defp get_request(url) do
    url_charlist = String.to_charlist(url)
    opts = [{:timeout, timeout_ms()}]

    case :httpc.request(:get, {url_charlist, []}, opts, []) do
      {:ok, {{_version, 200, _reason}, _headers, resp_body}} ->
        {:ok, List.to_string(resp_body)}

      {:ok, {{_version, status, _reason}, _headers, _body}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, {:connection_error, reason}}
    end
  end
end
