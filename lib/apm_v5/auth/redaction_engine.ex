defmodule ApmV5.Auth.RedactionEngine do
  @moduledoc """
  Stateless data redaction engine for AgentLock authorization.

  Applies 7 built-in regex patterns to detect and redact sensitive
  data from agent output. Supports auto, manual, and none modes.

  ## Built-in Patterns
  1. SSN — US Social Security Numbers
  2. Credit Card — 16-digit card numbers
  3. Email — Email addresses
  4. Phone — US phone numbers
  5. IP Address — IPv4 addresses
  6. AWS Key — AWS access key IDs
  7. Generic API Key — Long hex/base64 strings in key context
  """

  alias ApmV5.Auth.Types.RedactionResult

  @patterns [
    {:ssn, ~r/\b\d{3}-\d{2}-\d{4}\b/, "[REDACTED:ssn]"},
    {:credit_card, ~r/\b\d{4}[\s\-]?\d{4}[\s\-]?\d{4}[\s\-]?\d{4}\b/, "[REDACTED:credit_card]"},
    {:email, ~r/\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b/, "[REDACTED:email]"},
    {:phone, ~r/\b(?:\+1[\s\-]?)?\(?\d{3}\)?[\s\-]?\d{3}[\s\-]?\d{4}\b/, "[REDACTED:phone]"},
    {:ip_address, ~r/\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b/, "[REDACTED:ip]"},
    {:aws_key, ~r/\bAKIA[0-9A-Z]{16}\b/, "[REDACTED:aws_key]"},
    {:api_key,
     ~r/(?:api[_\-]?key|token|secret)\s*[:=]\s*["']?([A-Za-z0-9_\-]{32,64})["']?/i,
     "[REDACTED:api_key]"}
  ]

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Redact sensitive data from text using configured mode.

  ## Modes
  - `:auto` — apply all built-in patterns
  - `:manual` — apply only specified pattern types
  - `:none` — return text unchanged

  ## Options
  - `:patterns` — list of pattern type atoms to apply (for manual mode)
  """
  @spec redact(String.t(), atom(), keyword()) :: RedactionResult.t()
  def redact(text, mode \\ :auto, opts \\ [])

  def redact(text, :none, _opts) do
    %RedactionResult{redacted_text: text, mode: :none, had_redactions: false}
  end

  def redact(text, :auto, _opts) do
    apply_patterns(text, @patterns, :auto)
  end

  def redact(text, :manual, opts) do
    selected_types = Keyword.get(opts, :patterns, [])

    selected =
      @patterns
      |> Enum.filter(fn {type, _regex, _replacement} -> type in selected_types end)

    apply_patterns(text, selected, :manual)
  end

  @doc """
  Scan text for sensitive patterns without redacting.

  Returns a list of `{type, matched_text, position}` tuples.
  """
  @spec scan(String.t()) :: [{atom(), String.t(), non_neg_integer()}]
  def scan(text) do
    @patterns
    |> Enum.flat_map(fn {type, regex, _replacement} ->
      Regex.scan(regex, text, return: :index)
      |> Enum.map(fn [{start, len} | _] ->
        matched = String.slice(text, start, len)
        {type, matched, start}
      end)
    end)
    |> Enum.sort_by(fn {_type, _text, pos} -> pos end)
  end

  @doc "Returns all available pattern types."
  @spec pattern_types() :: [atom()]
  def pattern_types do
    Enum.map(@patterns, fn {type, _regex, _replacement} -> type end)
  end

  @doc "Check if text contains any sensitive patterns."
  @spec contains_sensitive?(String.t()) :: boolean()
  def contains_sensitive?(text) do
    Enum.any?(@patterns, fn {_type, regex, _replacement} ->
      Regex.match?(regex, text)
    end)
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp apply_patterns(text, patterns, mode) do
    {redacted_text, redactions} =
      Enum.reduce(patterns, {text, []}, fn {type, regex, replacement}, {txt, reds} ->
        case Regex.scan(regex, txt) do
          [] ->
            {txt, reds}

          matches ->
            new_reds =
              Enum.map(matches, fn [match | _] ->
                %{type: type, original: mask_original(match), replacement: replacement}
              end)

            new_txt = Regex.replace(regex, txt, replacement)
            {new_txt, reds ++ new_reds}
        end
      end)

    %RedactionResult{
      redacted_text: redacted_text,
      redactions: redactions,
      mode: mode,
      had_redactions: redactions != []
    }
  end

  # Mask the middle of matched content for audit logging
  defp mask_original(text) when byte_size(text) <= 8, do: "***"

  defp mask_original(text) do
    len = String.length(text)
    prefix = String.slice(text, 0, 3)
    suffix = String.slice(text, len - 3, 3)
    "#{prefix}...#{suffix}"
  end
end
