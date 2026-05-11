defmodule ApmV5.AppVersion do
  @moduledoc """
  Single source of truth for the apm_v5 application version.

  The version is declared once in `mix.exs` (`project[:version]`) and surfaced
  here via `Application.spec/2`, which reads the value baked into the `.app`
  manifest at build time. All UI, API, and metadata callers should use
  `ApmV5.AppVersion.current/0` rather than hardcoding strings.

  Named `AppVersion` (not `Version`) to avoid shadowing the Elixir stdlib
  `Version` module used elsewhere for SemVer parsing (e.g. ExportManager).

  Why runtime lookup (not a compile-time `@version` attribute): module
  attributes captured from `Mix.Project.config/0` do not trigger recompile when
  `mix.exs` changes, so a stale bump would silently leak into shipped code.
  """

  @spec current() :: String.t()
  def current do
    :apm_v5
    |> Application.spec(:vsn)
    |> to_string()
  end
end
