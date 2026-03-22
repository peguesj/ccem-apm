defmodule ApmV5.Auth.MemoryGate do
  @moduledoc """
  Stateless module for memory persistence authorization (AgentLock v1.1).

  Controls what content can be persisted to memory/disk by agents.
  Checks trust ceiling, data boundaries, prohibited patterns, and
  rate limits before allowing memory writes.

  ## Prohibited Patterns
  Detects and blocks persistence of:
  - API keys and tokens (32+ char hex/base64)
  - Private keys (PEM markers)
  - Connection strings with credentials
  - JWT tokens (eyJ... format)
  - SSH keys
  - OAuth tokens
  """

  alias ApmV5.Auth.Types

  @prohibited_patterns [
    # API keys / tokens (generic long hex/base64 strings in assignment context)
    {~r/(?:api[_-]?key|token|secret|password|passwd|pwd)\s*[:=]\s*["']?[A-Za-z0-9_\-+\/]{20,}/i,
     :api_key},
    # PEM private keys
    {~r/-----BEGIN\s+(RSA\s+)?PRIVATE\s+KEY-----/, :private_key},
    # Connection strings with credentials
    {~r/(?:postgres|mysql|mongodb|redis):\/\/[^:]+:[^@]+@/i, :connection_string},
    # JWT tokens
    {~r/eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/, :jwt_token},
    # SSH keys
    {~r/ssh-(?:rsa|ed25519|ecdsa)\s+[A-Za-z0-9+\/=]{40,}/, :ssh_key},
    # AWS access keys
    {~r/AKIA[0-9A-Z]{16}/, :aws_key},
    # OAuth bearer tokens in headers
    {~r/[Aa]uthorization:\s*[Bb]earer\s+[A-Za-z0-9_\-\.]{20,}/, :oauth_token}
  ]

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Authorize a memory write operation.

  Checks:
  1. Content does not contain prohibited patterns
  2. Trust ceiling is sufficient for the persistence level
  3. Rate limits are not exceeded

  Returns `:ok` or `{:error, reason, detail}`.
  """
  @spec authorize_write(String.t(), String.t(), String.t(), Types.persistence_level()) ::
          :ok | {:error, atom(), String.t()}
  def authorize_write(session_id, agent_id, content, persistence_level \\ :session) do
    with :ok <- check_prohibited_patterns(content),
         :ok <- check_trust_for_persistence(session_id, persistence_level),
         :ok <- check_rate_limit(agent_id) do
      :ok
    end
  end

  @doc """
  Authorize a memory read operation.

  Reads are generally permitted but may be restricted by trust ceiling.
  """
  @spec authorize_read(String.t(), String.t()) :: :ok | {:error, atom(), String.t()}
  def authorize_read(session_id, _agent_id) do
    trust = get_trust_ceiling(session_id)

    if trust == :untrusted do
      {:error, :memory_read_denied, "Trust ceiling is untrusted; memory reads restricted"}
    else
      :ok
    end
  end

  @doc """
  Scan content for prohibited patterns without blocking.

  Returns a list of `{pattern_type, matched_text}` tuples.
  """
  @spec scan_prohibited(String.t()) :: [{atom(), String.t()}]
  def scan_prohibited(content) do
    @prohibited_patterns
    |> Enum.flat_map(fn {regex, type} ->
      case Regex.run(regex, content) do
        [match | _] -> [{type, match}]
        nil -> []
      end
    end)
  end

  @doc "Returns the list of prohibited pattern types."
  @spec prohibited_pattern_types() :: [atom()]
  def prohibited_pattern_types do
    Enum.map(@prohibited_patterns, fn {_regex, type} -> type end)
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp check_prohibited_patterns(content) do
    case scan_prohibited(content) do
      [] ->
        :ok

      [{type, _match} | _] ->
        {:error, :memory_prohibited_content,
         "Content contains prohibited pattern: #{type}"}
    end
  end

  defp check_trust_for_persistence(session_id, persistence_level) do
    trust = get_trust_ceiling(session_id)

    case {persistence_level, trust} do
      {:cross_session, :untrusted} ->
        {:error, :memory_write_denied,
         "Cross-session persistence requires at least derived trust"}

      {:cross_session, :derived} ->
        # Derived trust allows cross-session but with warning
        :ok

      {:session, :untrusted} ->
        {:error, :memory_write_denied,
         "Session persistence blocked at untrusted trust ceiling"}

      _ ->
        :ok
    end
  end

  defp check_rate_limit(agent_id) do
    case ApmV5.Auth.RateLimiter.check(agent_id, "memory_write") do
      :ok -> :ok
      {:error, :rate_limited, retry_after} ->
        {:error, :memory_rate_limited,
         "Memory write rate limited; retry after #{retry_after}ms"}
    end
  end

  defp get_trust_ceiling(session_id) do
    try do
      ApmV5.Auth.ContextTracker.get_trust_ceiling(session_id)
    rescue
      _ -> :authoritative
    catch
      :exit, _ -> :authoritative
    end
  end
end
