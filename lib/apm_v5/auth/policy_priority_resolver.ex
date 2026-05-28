defmodule ApmV5.Auth.PolicyPriorityResolver do
  @moduledoc """
  Conflict resolution for overlapping authorization policy rules (auth-v10.1-s4 / CP-294).

  When multiple policy rules match a given tool call, `resolve/2` collapses
  them into a single `:always_allow | :always_deny | :none` decision using one
  of three config-driven strategies:

  - `:deny_wins`       — any deny overrides all allows (most secure, default)
  - `:most_specific`   — the rule with the highest specificity score wins;
                          specificity is defined by the number of non-wildcard
                          fields bound (tool > role > session > project > any)
  - `:first_match`     — the rule listed first (by `inserted_at`) wins

  ## Configuration

  Set the active strategy in config:

      config :apm_v5, ApmV5.Auth.PolicyPriorityResolver, strategy: :deny_wins

  Default is `:deny_wins`.

  ## Integration with PolicyEngine

  `PolicyEngine.evaluate/3` calls `PolicyPriorityResolver.resolve/2` when
  `PolicyRulesStore.check_rule/1` returns `:none` and a context key
  `:matching_rules` is present (list of rule maps from a multi-rule query).
  For the common single-rule fast path, the existing `check_rule/1` is used
  directly and no resolver call is needed.

  ## Usage

      rules = [
        %{tool_name: "Bash", action: :always_deny, inserted_at: ~U[2025-01-01 00:00:00Z]},
        %{tool_name: "Bash", action: :always_allow, inserted_at: ~U[2025-01-02 00:00:00Z]}
      ]

      ApmV5.Auth.PolicyPriorityResolver.resolve(rules, :deny_wins)
      #=> :always_deny

  """

  @type rule :: %{
          required(:tool_name) => String.t(),
          required(:action) => :always_allow | :always_deny,
          optional(:inserted_at) => String.t() | DateTime.t(),
          optional(:specificity) => non_neg_integer()
        }

  @type strategy :: :deny_wins | :most_specific | :first_match

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Resolve a list of matching rules to a single decision using `strategy`.

  Returns `:always_allow | :always_deny | :none`.

  - Empty list → `:none`
  - Single-element list → that element's action (strategy irrelevant)
  - Multi-element → strategy applied

  ## Strategies

  - `:deny_wins`     — if ANY rule is `:always_deny`, result is `:always_deny`
  - `:most_specific` — highest-specificity rule wins (tie → deny_wins on tie)
  - `:first_match`   — earliest `inserted_at` wins

  """
  @spec resolve([rule()], strategy()) :: :always_allow | :always_deny | :none
  def resolve([], _strategy), do: :none
  def resolve([%{action: action}], _strategy), do: action

  def resolve(rules, :deny_wins) do
    if Enum.any?(rules, &(&1.action == :always_deny)) do
      :always_deny
    else
      :always_allow
    end
  end

  def resolve(rules, :most_specific) do
    winner =
      rules
      |> Enum.sort_by(&specificity_score/1, :desc)
      |> hd()

    # If multiple rules tie at top specificity, apply deny_wins as tiebreaker
    top_score = specificity_score(winner)

    top_rules =
      Enum.filter(rules, fn r -> specificity_score(r) == top_score end)

    case top_rules do
      [single] -> single.action
      tied -> resolve(tied, :deny_wins)
    end
  end

  def resolve(rules, :first_match) do
    rules
    |> Enum.sort_by(&parse_inserted_at/1, DateTime)
    |> hd()
    |> Map.fetch!(:action)
  end

  @doc """
  Returns the configured strategy from application env, defaulting to `:deny_wins`.

  ## Example

      iex> ApmV5.Auth.PolicyPriorityResolver.configured_strategy()
      :deny_wins

  """
  @spec configured_strategy() :: strategy()
  def configured_strategy do
    Application.get_env(:apm_v5, __MODULE__, [])
    |> Keyword.get(:strategy, :deny_wins)
  end

  @doc """
  Resolve rules using the application-configured strategy.

  Equivalent to `resolve(rules, configured_strategy())`.
  """
  @spec resolve([rule()]) :: :always_allow | :always_deny | :none
  def resolve(rules), do: resolve(rules, configured_strategy())

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Specificity score: wildcard "*" has score 0; explicit tool name has score 1.
  # Extend as additional rule dimensions (role, session, project) are added.
  defp specificity_score(%{tool_name: "*"}), do: 0
  defp specificity_score(%{specificity: s}) when is_integer(s), do: s
  defp specificity_score(%{tool_name: _}), do: 1

  # Parse inserted_at — accepts DateTime struct or ISO 8601 string.
  defp parse_inserted_at(%{inserted_at: %DateTime{} = dt}), do: dt

  defp parse_inserted_at(%{inserted_at: iso}) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> dt
      _ -> ~U[1970-01-01 00:00:00Z]
    end
  end

  defp parse_inserted_at(_), do: ~U[1970-01-01 00:00:00Z]
end
