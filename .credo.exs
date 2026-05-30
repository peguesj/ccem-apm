%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/"],
        excluded: [~r"/_build/", ~r"/deps/", ~r"/node_modules/"]
      },
      strict: false,
      color: true,
      checks: %{
        extra: [
          # Phase 0.2: Enforce canonical 5-tone severity vocabulary on badge tone attrs.
          # Flags non-canonical literals: ok/warn/err/danger/critical/problem/caution/notice
          {ApmV5Web.CredoChecks.BadgeTone, []}
        ]
      }
    }
  ]
}
