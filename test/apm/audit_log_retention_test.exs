defmodule Apm.AuditLogRetentionTest do
  @moduledoc """
  Tests for audit-s6 retention policy (CP-224 / US-456):
  - Files older than archive_days() are deleted on run_daily_purge/2.
  - Yesterday's closed log file gets chmod 0444 on run_daily_purge/2.
  - Today's active file is left untouched.
  - online_days/0 and archive_days/0 return sensible defaults.
  """
  use ExUnit.Case, async: true

  alias Apm.AuditLog

  @tmp_dir Path.join(
             System.tmp_dir!(),
             "apm_audit_retention_test_#{:erlang.unique_integer([:positive])}"
           )

  setup do
    File.mkdir_p!(@tmp_dir)

    on_exit(fn ->
      # Restore write permissions before cleanup so File.rm_rf! can delete.
      case File.ls(@tmp_dir) do
        {:ok, files} ->
          Enum.each(files, fn f ->
            File.chmod(Path.join(@tmp_dir, f), 0o644)
          end)

        _ ->
          :ok
      end

      File.rm_rf!(@tmp_dir)
    end)

    :ok
  end

  describe "run_daily_purge/2" do
    test "deletes files older than archive_days" do
      today = Date.utc_today()
      # 400 days ago — well past the 365-day default archive window.
      old_date = Date.add(today, -400)
      old_filename = "ccem_audit_#{Date.to_iso8601(old_date)}.jsonl"
      old_path = Path.join(@tmp_dir, old_filename)
      File.write!(old_path, ~s({"id":1,"event_type":"test"}\n))

      assert File.exists?(old_path)

      AuditLog.run_daily_purge(@tmp_dir, today)

      refute File.exists?(old_path),
             "Expected old JSONL file (#{old_filename}) to be deleted during purge"
    end

    test "chmods yesterday's file to 0444" do
      today = Date.utc_today()
      yesterday = Date.add(today, -1)
      yesterday_filename = "ccem_audit_#{Date.to_iso8601(yesterday)}.jsonl"
      yesterday_path = Path.join(@tmp_dir, yesterday_filename)
      File.write!(yesterday_path, ~s({"id":1,"event_type":"test"}\n))
      # Ensure file is writable before the purge.
      File.chmod!(yesterday_path, 0o644)

      AuditLog.run_daily_purge(@tmp_dir, today)

      assert File.exists?(yesterday_path),
             "Yesterday's file should not be deleted"

      {:ok, %{mode: mode}} = File.stat(yesterday_path)
      permissions = Bitwise.band(mode, 0o777)

      assert permissions == 0o444,
             "Expected yesterday's file to be chmod 0444, got 0#{Integer.to_string(permissions, 8)}"
    end

    test "does not touch today's active log file" do
      today = Date.utc_today()
      today_filename = "ccem_audit_#{Date.to_iso8601(today)}.jsonl"
      today_path = Path.join(@tmp_dir, today_filename)
      File.write!(today_path, ~s({"id":1}\n))
      File.chmod!(today_path, 0o644)

      AuditLog.run_daily_purge(@tmp_dir, today)

      assert File.exists?(today_path), "Today's file must not be deleted"
      {:ok, %{mode: mode}} = File.stat(today_path)
      assert Bitwise.band(mode, 0o777) == 0o644, "Today's file must remain writable"
    end

    test "ignores non-audit files in log dir" do
      today = Date.utc_today()
      unrelated = Path.join(@tmp_dir, "other_file.log")
      File.write!(unrelated, "not an audit log\n")

      AuditLog.run_daily_purge(@tmp_dir, today)

      assert File.exists?(unrelated), "Unrelated files must not be touched"
    end

    test "handles empty log dir gracefully" do
      empty_dir = Path.join(@tmp_dir, "empty_subdir")
      File.mkdir_p!(empty_dir)
      assert :ok = AuditLog.run_daily_purge(empty_dir, Date.utc_today())
    end

    test "handles missing log dir gracefully" do
      missing_dir = Path.join(@tmp_dir, "does_not_exist")
      assert :ok = AuditLog.run_daily_purge(missing_dir, Date.utc_today())
    end
  end

  describe "online_days/0 and archive_days/0" do
    test "return positive integers" do
      assert AuditLog.online_days() > 0
      assert AuditLog.archive_days() > 0
    end

    test "archive_days >= online_days by default" do
      assert AuditLog.archive_days() >= AuditLog.online_days()
    end

    test "online_days defaults to 90" do
      assert AuditLog.online_days() == 90
    end

    test "archive_days defaults to 365" do
      assert AuditLog.archive_days() == 365
    end
  end
end
