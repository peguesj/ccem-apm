defmodule Apm.WiringMonitor.Finding do
  @moduledoc """
  A single result from a wiring integrity check.

  ## Fields

  - `check`    — which invariant produced this finding (`:W1` – `:W4`)
  - `severity` — `:success | :warning | :error` (canonical 3-tone palette)
  - `subject`  — route path, hook name, topic, or module name
  - `detail`   — human-readable description of the finding
  - `checked_at` — `DateTime.utc_now/0` at finding creation
  """

  @enforce_keys [:check, :severity, :subject, :detail]

  defstruct [
    :check,
    :severity,
    :subject,
    :detail,
    checked_at: nil
  ]

  @type t :: %__MODULE__{
          check: :W1 | :W2 | :W3 | :W4,
          severity: :success | :warning | :error,
          subject: String.t(),
          detail: String.t(),
          checked_at: DateTime.t() | nil
        }

  @doc """
  Construct a new `Finding` with the current UTC timestamp.
  """
  @spec new(atom(), :success | :warning | :error, String.t(), String.t()) :: t()
  def new(check, severity, subject, detail) do
    %__MODULE__{
      check: check,
      severity: severity,
      subject: to_string(subject),
      detail: detail,
      checked_at: DateTime.utc_now()
    }
  end

  @doc """
  Return the canonical tone string for use with `<.badge tone={tone(finding)}>`.
  Maps `:success` → `"success"`, `:warning` → `"warning"`, `:error` → `"error"`.
  """
  @spec tone(t()) :: String.t()
  def tone(%__MODULE__{severity: :success}), do: "success"
  def tone(%__MODULE__{severity: :warning}), do: "warning"
  def tone(%__MODULE__{severity: :error}), do: "error"
  def tone(_), do: "neutral"
end
