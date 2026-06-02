defmodule Apm.Governance.ComplianceReportEngineTest do
  @moduledoc """
  Basic tests for ComplianceReportEngine (comp-ms2 / CP-233 / US-465).

  async: false because the engine Agent is a named process.
  """

  use ExUnit.Case, async: false

  alias Apm.Governance.ComplianceReportEngine

  @tag :compliance_report
  test "generate/0 returns a report struct with overall_score >= 50" do
    report = ComplianceReportEngine.generate()

    assert is_map(report)
    assert %DateTime{} = report.generated_at
    assert is_integer(report.overall_score)
    assert report.overall_score >= 50,
           "Expected overall_score >= 50, got #{report.overall_score}. " <>
             "Controls: #{inspect(report.controls_by_status)}"
  end

  @tag :compliance_report
  test "generate/0 returns controls_by_status with non-zero satisfied count" do
    report = ComplianceReportEngine.generate()
    assert report.controls_by_status.satisfied >= 1
  end

  @tag :compliance_report
  test "generate/0 populates by_framework with all 7 frameworks" do
    report = ComplianceReportEngine.generate()
    expected_frameworks = [:nist_ai_rmf, :soc2, :iso_27001, :nist_csf, :pci_dss, :eu_ai_act, :cis]

    for fw <- expected_frameworks do
      assert Map.has_key?(report.by_framework, fw),
             "Expected by_framework to contain #{fw}, got keys: #{inspect(Map.keys(report.by_framework))}"
    end
  end

  @tag :compliance_report
  test "generate/0 returns a non-empty controls list" do
    report = ComplianceReportEngine.generate()
    assert length(report.controls) >= 1
    # Each control has id, name, status, frameworks, evidence
    [first | _] = report.controls
    assert Map.has_key?(first, :id)
    assert Map.has_key?(first, :name)
    assert Map.has_key?(first, :status)
    assert Map.has_key?(first, :evidence)
  end

  @tag :compliance_report
  test "to_json/1 produces string keys and ISO8601 generated_at" do
    report = ComplianceReportEngine.generate()
    json = ComplianceReportEngine.to_json(report)

    assert is_map(json)
    assert is_binary(json["generated_at"])
    assert is_integer(json["overall_score"])
    assert is_map(json["controls_by_status"])
    assert is_list(json["controls"])
    assert is_map(json["by_framework"])
    assert is_map(json["kri_snapshot"])
  end

  @tag :compliance_report
  test "to_markdown/1 produces a string containing the score header" do
    report = ComplianceReportEngine.generate()
    md = ComplianceReportEngine.to_markdown(report)

    assert is_binary(md)
    assert md =~ "CCEM Compliance Posture Report"
    assert md =~ "Overall Score:"
    assert md =~ "NIST AI RMF"
  end

  @tag :compliance_report
  test "refresh/0 returns a freshly generated report" do
    report1 = ComplianceReportEngine.generate()
    # Brief pause so timestamps differ
    Process.sleep(10)
    report2 = ComplianceReportEngine.refresh()

    assert DateTime.compare(report2.generated_at, report1.generated_at) in [:gt, :eq]
  end
end
