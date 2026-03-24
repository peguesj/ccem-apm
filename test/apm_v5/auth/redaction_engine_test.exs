defmodule ApmV5.Auth.RedactionEngineTest do
  use ExUnit.Case, async: true

  alias ApmV5.Auth.RedactionEngine
  alias ApmV5.Auth.Types.RedactionResult

  # ── redact/2 :none mode ────────────────────────────────────────────────────

  test "redact :none mode returns text unchanged" do
    result = RedactionEngine.redact("my SSN is 123-45-6789", :none)
    assert %RedactionResult{} = result
    assert result.redacted_text == "my SSN is 123-45-6789"
    assert result.had_redactions == false
    assert result.mode == :none
  end

  # ── redact/2 :auto mode ────────────────────────────────────────────────────

  test "redact :auto detects SSN" do
    result = RedactionEngine.redact("SSN: 123-45-6789", :auto)
    assert result.had_redactions == true
    assert String.contains?(result.redacted_text, "[REDACTED:ssn]")
    refute String.contains?(result.redacted_text, "123-45-6789")
  end

  test "redact :auto detects email" do
    result = RedactionEngine.redact("email: test@example.com", :auto)
    assert result.had_redactions == true
    assert String.contains?(result.redacted_text, "[REDACTED:email]")
    refute String.contains?(result.redacted_text, "test@example.com")
  end

  test "redact :auto detects credit card numbers" do
    result = RedactionEngine.redact("card: 4111-1111-1111-1111", :auto)
    assert result.had_redactions == true
    assert String.contains?(result.redacted_text, "[REDACTED:credit_card]")
  end

  test "redact :auto detects phone numbers" do
    result = RedactionEngine.redact("call me at (555) 123-4567", :auto)
    assert result.had_redactions == true
    assert String.contains?(result.redacted_text, "[REDACTED:phone]")
  end

  test "redact :auto detects IP addresses" do
    result = RedactionEngine.redact("server at 192.168.1.100", :auto)
    assert result.had_redactions == true
    assert String.contains?(result.redacted_text, "[REDACTED:ip]")
  end

  test "redact :auto detects AWS access keys" do
    # AWS key regex: AKIA + exactly 16 uppercase alphanumeric chars = 20 total
    result = RedactionEngine.redact("key: AKIAIOSFODNN7EXAMPLE", :auto)
    assert result.had_redactions == true
    assert String.contains?(result.redacted_text, "[REDACTED:aws_key]")
  end

  test "redact :auto detects API keys in assignment context" do
    result =
      RedactionEngine.redact(
        "api_key: abcdef1234567890abcdef1234567890ab",
        :auto
      )

    assert result.had_redactions == true
    assert String.contains?(result.redacted_text, "[REDACTED:api_key]")
  end

  test "redact :auto returns no redactions for safe text" do
    result = RedactionEngine.redact("hello world, this is safe", :auto)
    assert result.had_redactions == false
    assert result.redacted_text == "hello world, this is safe"
    assert result.mode == :auto
  end

  test "redact :auto handles multiple sensitive patterns" do
    text = "SSN: 123-45-6789, email: test@example.com"
    result = RedactionEngine.redact(text, :auto)
    assert result.had_redactions == true
    assert length(result.redactions) >= 2
    refute String.contains?(result.redacted_text, "123-45-6789")
    refute String.contains?(result.redacted_text, "test@example.com")
  end

  # ── redact/3 :manual mode ──────────────────────────────────────────────────

  test "redact :manual applies only specified patterns" do
    text = "SSN: 123-45-6789, email: user@test.com"
    result = RedactionEngine.redact(text, :manual, patterns: [:ssn])
    assert result.had_redactions == true
    assert String.contains?(result.redacted_text, "[REDACTED:ssn]")
    # Email should NOT be redacted in manual mode with only :ssn
    assert String.contains?(result.redacted_text, "user@test.com")
  end

  test "redact :manual with empty patterns returns text unchanged" do
    text = "SSN: 123-45-6789"
    result = RedactionEngine.redact(text, :manual, patterns: [])
    assert result.had_redactions == false
    assert result.redacted_text == text
  end

  # ── scan/1 ─────────────────────────────────────────────────────────────────

  test "scan returns pattern matches with positions" do
    matches = RedactionEngine.scan("SSN: 123-45-6789, email: a@b.com")
    assert length(matches) >= 2
    assert Enum.all?(matches, fn {type, text, pos} ->
      is_atom(type) and is_binary(text) and is_integer(pos)
    end)
  end

  test "scan returns matches sorted by position" do
    matches = RedactionEngine.scan("123-45-6789 test@example.com")
    positions = Enum.map(matches, fn {_, _, pos} -> pos end)
    assert positions == Enum.sort(positions)
  end

  test "scan returns empty list for safe text" do
    assert RedactionEngine.scan("hello world") == []
  end

  # ── contains_sensitive?/1 ──────────────────────────────────────────────────

  test "contains_sensitive? returns true for SSN" do
    assert RedactionEngine.contains_sensitive?("SSN: 123-45-6789")
  end

  test "contains_sensitive? returns true for email" do
    assert RedactionEngine.contains_sensitive?("test@example.com")
  end

  test "contains_sensitive? returns false for safe text" do
    refute RedactionEngine.contains_sensitive?("hello world")
    refute RedactionEngine.contains_sensitive?("just a normal sentence")
  end

  # ── pattern_types/0 ────────────────────────────────────────────────────────

  test "pattern_types returns all 7 types" do
    types = RedactionEngine.pattern_types()
    assert length(types) == 7
    assert :ssn in types
    assert :credit_card in types
    assert :email in types
    assert :phone in types
    assert :ip_address in types
    assert :aws_key in types
    assert :api_key in types
  end
end
