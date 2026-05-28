defmodule ApmV5.Auth.PolicyPredicate do
  @moduledoc """
  Struct-based AST for contextual policy predicates (CP-286 / auth-s3-c).

  A `PolicyPredicate` describes a runtime condition that must hold before a
  policy rule is applied. Predicates are evaluated by `evaluate/2` against a
  context map and return `:match | :no_match`.

  ## Predicate Types

  | `:type`           | Required params                  | Description                                       |
  |-------------------|----------------------------------|---------------------------------------------------|
  | `:time_window`    | `from_hour`, `to_hour` (0-23)    | Current UTC hour must be in `[from_hour, to_hour]`|
  | `:env_match`      | `env` (atom)                     | Context `:env` must equal param `env`             |
  | `:path_glob`      | `glob` (string)                  | Context `:path` matches the glob pattern          |
  | `:formation_role` | `role` (atom)                    | Context `:formation_role` must equal param `role` |

  ## Integration

  `evaluate_all/2` short-circuits on the first `:no_match` (AND semantics).

  `PolicyEngine.evaluate/3` calls `evaluate_all/2` with a rule's predicates
  before performing risk classification, so a rule only activates when all its
  predicates match.

  ## Example

      iex> pred = %ApmV5.Auth.PolicyPredicate{type: :env_match, params: %{env: :prod}}
      iex> ApmV5.Auth.PolicyPredicate.evaluate(pred, %{env: :prod})
      :match
      iex> ApmV5.Auth.PolicyPredicate.evaluate(pred, %{env: :dev})
      :no_match
  """

  @type predicate_type ::
          :time_window
          | :env_match
          | :path_glob
          | :formation_role

  @type t :: %__MODULE__{
          type: predicate_type() | atom(),
          params: map()
        }

  defstruct type: nil, params: %{}

  @doc """
  Evaluate a single predicate against a context map.

  Returns `:match` when the condition holds, `:no_match` otherwise.
  Unknown predicate types return `:no_match` (safe default).
  """
  @spec evaluate(t(), map()) :: :match | :no_match
  def evaluate(%__MODULE__{type: :time_window, params: params}, _context) do
    from_hour = Map.get(params, :from_hour, 0)
    to_hour = Map.get(params, :to_hour, 23)

    if from_hour > 23 or to_hour > 23 do
      :no_match
    else
      hour = DateTime.utc_now().hour

      if from_hour <= to_hour do
        if hour >= from_hour and hour <= to_hour, do: :match, else: :no_match
      else
        # Wraps midnight: e.g. from_hour=22, to_hour=4
        if hour >= from_hour or hour <= to_hour, do: :match, else: :no_match
      end
    end
  end

  def evaluate(%__MODULE__{type: :env_match, params: params}, context) do
    expected = Map.get(params, :env)
    actual = Map.get(context, :env)

    if expected != nil and expected == actual, do: :match, else: :no_match
  end

  def evaluate(%__MODULE__{type: :path_glob, params: params}, context) do
    glob = Map.get(params, :glob)
    path = Map.get(context, :path)

    if is_binary(glob) and is_binary(path) do
      if glob_match?(glob, path), do: :match, else: :no_match
    else
      :no_match
    end
  end

  def evaluate(%__MODULE__{type: :formation_role, params: params}, context) do
    expected = Map.get(params, :role)
    actual = Map.get(context, :formation_role)

    if expected != nil and expected == actual, do: :match, else: :no_match
  end

  def evaluate(%__MODULE__{}, _context), do: :no_match

  @doc """
  Evaluate a list of predicates with AND semantics.

  Returns `:match` when all predicates match (or the list is empty).
  Short-circuits on the first `:no_match`.
  """
  @spec evaluate_all([t()], map()) :: :match | :no_match
  def evaluate_all([], _context), do: :match

  def evaluate_all([pred | rest], context) do
    case evaluate(pred, context) do
      :match -> evaluate_all(rest, context)
      :no_match -> :no_match
    end
  end

  # ---------------------------------------------------------------------------
  # Glob matching
  # ---------------------------------------------------------------------------

  # Simple glob → regex conversion supporting:
  #   ** — match any path segment sequence (including /)
  #   *  — match any sequence except /
  #   ?  — match a single non-/ character
  @spec glob_match?(String.t(), String.t()) :: boolean()
  defp glob_match?(glob, path) do
    pattern = glob_to_regex(glob)

    case Regex.compile("^#{pattern}$") do
      {:ok, re} -> Regex.match?(re, path)
      _ -> false
    end
  end

  # Converts a glob pattern to a regex string.
  # Order of operations matters:
  # 1. Escape literal dots
  # 2. Replace ** with a placeholder (must happen before single-* replacement)
  # 3. Replace single * with [^/]* (any segment, no slash)
  # 4. Replace ? with [^/]
  # 5. Replace placeholder with .* (any sequence including slashes)
  @double_star_placeholder "\x00DS\x00"

  defp glob_to_regex(glob) do
    glob
    |> String.replace(".", "\\.")
    |> String.replace("**", @double_star_placeholder)
    |> String.replace("*", "[^/]*")
    |> String.replace("?", "[^/]")
    |> String.replace(@double_star_placeholder, ".*")
  end
end
