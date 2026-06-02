defmodule ApmWeb.CredoChecks.BadgeTone do
  @moduledoc """
  Enforces the canonical 5-tone severity vocabulary on component tone attrs.

  Flags any HEEx template that passes a non-canonical literal (e.g. `tone="err"`,
  `tone={:warn}`, `tone="danger"`) — these all became errors at Phase 0.2.
  Computed tones (`tone={@status}`) pass; only string/atom literals are checked.

  Canonical vocab: `success | warning | error | info | neutral`
  Extended (DS-only): `accent | iris`
  """

  use Credo.Check,
    base_priority: :high,
    category: :consistency,
    explanations: [
      check: """
      The CCEM design system uses a canonical 5-tone severity vocabulary:
        success | warning | error | info | neutral
      Extended design-system-only tones: accent | iris.

      Non-canonical tone literals like "ok", "warn", "err", "danger", "critical"
      were normalized in Phase 0.2 (v11 foundations). Any new usage should use
      the canonical set exclusively.
      """,
      params: []
    ]

  @stale_tones ~w(ok warn err danger critical problem caution notice)

  @impl true
  def run(%Credo.SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)
    source = SourceFile.source(source_file)

    # Scan for string literals in tone= attrs: tone="stale"
    string_issues =
      for stale <- @stale_tones,
          match = Regex.scan(~r/tone\s*=\s*"#{stale}"/, source, return: :index),
          {byte_offset, _} <- match do
        line_no = line_no_from_offset(source, byte_offset)
        build_issue(issue_meta, line_no, stale, "\"#{stale}\"")
      end

    # Scan for atom literals in tone= attrs: tone={:stale}
    atom_issues =
      for stale <- @stale_tones,
          match = Regex.scan(~r/tone\s*=\s*\{:#{stale}\}/, source, return: :index),
          {byte_offset, _} <- match do
        line_no = line_no_from_offset(source, byte_offset)
        build_issue(issue_meta, line_no, stale, "{:#{stale}}")
      end

    string_issues ++ atom_issues
  end

  defp line_no_from_offset(source, byte_offset) do
    source
    |> binary_part(0, byte_offset)
    |> String.split("\n")
    |> length()
  end

  defp build_issue(issue_meta, line_no, stale_tone, literal) do
    canonical = canonical_for(stale_tone)

    format_issue(issue_meta,
      message: "Non-canonical tone literal #{literal} — use \"#{canonical}\" (Phase 0.2 canonical vocab)",
      line_no: line_no,
      trigger: literal
    )
  end

  defp canonical_for("ok"), do: "success"
  defp canonical_for("warn"), do: "warning"
  defp canonical_for("err"), do: "error"
  defp canonical_for("danger"), do: "error"
  defp canonical_for("critical"), do: "error"
  defp canonical_for("problem"), do: "error"
  defp canonical_for("caution"), do: "warning"
  defp canonical_for("notice"), do: "info"
  defp canonical_for(_), do: "neutral"
end
