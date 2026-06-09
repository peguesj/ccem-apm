defmodule Apm.ColdStartResilienceTest do
  @moduledoc """
  CP-338 / US-518 / CCEM-715 — Cold-start race regression tests.

  /api/v2/formations was returning 500 when DashboardLive mounted before
  AgentRegistry GenServer had finished initializing its ETS tables. The
  unguarded :ets.tab2list/1 calls in get_notifications/0 and list_formations/0
  raised ArgumentError when the named table did not exist.

  These tests assert the public read paths gracefully degrade to empty lists,
  so the HTTP endpoint serves 200 with an empty envelope during the
  cold-start window.
  """
  use ApmWeb.ConnCase, async: false

  alias Apm.AgentRegistry
  alias Apm.UpmStore

  describe "AgentRegistry.get_notifications/0 — ETS resilience" do
    test "returns [] when notifications ETS table is absent" do
      with_table_dropped(:apm_notifications, fn ->
        assert AgentRegistry.get_notifications() == []
      end)
    end
  end

  describe "UpmStore.list_formations/0 — ETS resilience" do
    test "returns [] when formations ETS table is absent" do
      with_table_dropped(:upm_formations, fn ->
        assert UpmStore.list_formations() == []
      end)
    end
  end

  describe "UpmStore.list_all_formations/0 — ETS resilience" do
    test "returns a list (not crash) when notifications ETS table is absent" do
      with_table_dropped(:apm_notifications, fn ->
        assert is_list(UpmStore.list_all_formations())
      end)
    end

    test "tolerates formation entries missing :name key (sort guard)" do
      malformed = %{id: "fmt-malformed-test", events: [], registered_at: DateTime.utc_now()}
      :ets.insert(:upm_formations, {"fmt-malformed-test", malformed})

      try do
        assert is_list(UpmStore.list_all_formations())
      after
        :ets.delete(:upm_formations, "fmt-malformed-test")
      end
    end
  end

  # NOTE: HTTP integration coverage of /api/v2/formations during cold-start is
  # deferred — ApmWeb.ConnCase routes the request through OpenApiSpex's
  # CastAndValidate plug which rebuilds the API spec on every request, and
  # the spec build crashes inside OpenApiSpex.Paths.from_routes/1 on an
  # unrelated v9.3.0 issue. Verified live instead via curl after APM restart
  # at the controller level. Re-enable this test once the OpenApiSpex
  # initialization race is resolved.

  # Drop a named ETS table for the duration of `fun.0`, then restart the
  # owning GenServer so its supervisor recreates the table cleanly. This
  # avoids ownership drift: ETS tables created by transient test processes
  # die with those processes, breaking subsequent tests.
  defp with_table_dropped(table, fun) do
    owner = owner_for(table)

    try do
      # Stop the owning GenServer so we can safely delete its named table
      if owner, do: GenServer.stop(owner, :normal, 1000)

      # Drop the table if it survived (or was never owned)
      if :ets.info(table) != :undefined do
        try do
          :ets.delete(table)
        rescue
          ArgumentError -> :ok
        end
      end

      fun.()
    after
      # Restart the GenServer via its supervisor — table is recreated fresh.
      if owner, do: ensure_started(owner)
      # Give the supervisor a tick to bring it back up
      Process.sleep(20)
    end
  end

  defp owner_for(:apm_notifications), do: AgentRegistry
  defp owner_for(:upm_formations), do: UpmStore
  defp owner_for(_), do: nil

  defp ensure_started(mod) do
    case Process.whereis(mod) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        # Wait for the supervisor to bring it back
        Enum.reduce_while(1..20, :pending, fn _, _ ->
          case Process.whereis(mod) do
            pid when is_pid(pid) ->
              {:halt, :ok}

            nil ->
              Process.sleep(10)
              {:cont, :pending}
          end
        end)
    end
  end

  defp safe_dump(table) do
    :ets.tab2list(table)
  rescue
    ArgumentError -> []
  end
end
