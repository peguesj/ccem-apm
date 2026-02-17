defmodule ApmV4.A2ui.ComponentBuilderTest do
  use ExUnit.Case, async: false

  alias ApmV4.AgentRegistry
  alias ApmV4.A2ui.ComponentBuilder

  setup do
    AgentRegistry.clear_all()
    :ok
  end

  describe "build_all/0" do
    test "returns a list of components with empty state" do
      components = ComponentBuilder.build_all()
      assert is_list(components)
      # Should have stat cards + empty table + empty chart at minimum
      assert length(components) > 0
    end

    test "all components have unique IDs" do
      AgentRegistry.register_agent("a1", %{name: "Alpha", status: "active"})
      AgentRegistry.register_agent("a2", %{name: "Beta", status: "idle"})

      components = ComponentBuilder.build_all()
      ids = Enum.map(components, & &1.id)
      assert ids == Enum.uniq(ids)
    end

    test "all components have a type field" do
      AgentRegistry.register_agent("a1", %{name: "Alpha", status: "active"})

      components = ComponentBuilder.build_all()

      for comp <- components do
        assert Map.has_key?(comp, :type)
        assert comp.type in ["card", "chart", "table", "alert", "badge", "progress"]
      end
    end
  end

  describe "build_stat_cards/3" do
    test "returns 4 card components" do
      cards = ComponentBuilder.build_stat_cards([], [], [])
      assert length(cards) == 4
      assert Enum.all?(cards, &(&1.type == "card"))
    end

    test "card components have title, body, footer, variant" do
      cards = ComponentBuilder.build_stat_cards([], [], [])

      for card <- cards do
        assert Map.has_key?(card, :title)
        assert Map.has_key?(card, :body)
        assert Map.has_key?(card, :footer)
        assert Map.has_key?(card, :variant)
      end
    end

    test "agent count card reflects actual agents" do
      agents = [
        %{id: "a1", name: "A1", status: "active", tier: 1},
        %{id: "a2", name: "A2", status: "idle", tier: 1},
        %{id: "a3", name: "A3", status: "error", tier: 2}
      ]

      cards = ComponentBuilder.build_stat_cards(agents, [], [])
      agent_card = Enum.find(cards, &(&1.id == "card-agent-count"))
      assert agent_card.body == "3"
      assert agent_card.footer =~ "1 active"
      assert agent_card.footer =~ "1 idle"
      assert agent_card.footer =~ "1 errors"
    end

    test "error card variant is error when errors exist" do
      agents = [%{id: "a1", name: "A1", status: "error", tier: 1}]
      cards = ComponentBuilder.build_stat_cards(agents, [], [])
      error_card = Enum.find(cards, &(&1.id == "card-error-count"))
      assert error_card.variant == "error"
    end

    test "error card variant is success when no errors" do
      agents = [%{id: "a1", name: "A1", status: "active", tier: 1}]
      cards = ComponentBuilder.build_stat_cards(agents, [], [])
      error_card = Enum.find(cards, &(&1.id == "card-error-count"))
      assert error_card.variant == "success"
    end
  end

  describe "build_agent_table/1" do
    test "returns a table component" do
      [table] = ComponentBuilder.build_agent_table([])
      assert table.type == "table"
      assert table.id == "table-agents"
      assert table.sortable == true
    end

    test "table has correct columns" do
      [table] = ComponentBuilder.build_agent_table([])
      assert table.columns == ["id", "name", "tier", "status", "last_seen"]
    end

    test "table rows match agents" do
      agents = [
        %{id: "a1", name: "Alpha", tier: 1, status: "active", last_seen: "2026-01-01T00:00:00Z"},
        %{id: "a2", name: "Beta", tier: 2, status: "idle", last_seen: "2026-01-01T00:00:00Z"}
      ]

      [table] = ComponentBuilder.build_agent_table(agents)
      assert length(table.rows) == 2
      assert Enum.at(table.rows, 0).id == "a1"
      assert Enum.at(table.rows, 1).name == "Beta"
    end
  end

  describe "build_status_chart/1" do
    test "returns a pie chart component" do
      [chart] = ComponentBuilder.build_status_chart([])
      assert chart.type == "chart"
      assert chart.chart_type == "pie"
      assert chart.id == "chart-status-distribution"
    end

    test "chart data reflects status distribution" do
      agents = [
        %{id: "a1", status: "active"},
        %{id: "a2", status: "active"},
        %{id: "a3", status: "idle"}
      ]

      [chart] = ComponentBuilder.build_status_chart(agents)
      label_data = Enum.zip(chart.labels, chart.data) |> Enum.into(%{})
      assert label_data["active"] == 2
      assert label_data["idle"] == 1
    end
  end

  describe "build_notification_alerts/1" do
    test "returns alert components from notifications" do
      notifications = [
        %{id: 1, title: "Build Failed", message: "Compilation error", level: "error"},
        %{id: 2, title: "Deploy OK", message: "Success", level: "success"}
      ]

      alerts = ComponentBuilder.build_notification_alerts(notifications)
      assert length(alerts) == 2
      assert Enum.all?(alerts, &(&1.type == "alert"))
    end

    test "alert components have level, message, dismissible" do
      notifications = [
        %{id: 1, title: "Test", message: "Message", level: "warning"}
      ]

      [alert] = ComponentBuilder.build_notification_alerts(notifications)
      assert alert.level == "warning"
      assert alert.message == "Test: Message"
      assert alert.dismissible == true
    end

    test "caps at 10 alerts" do
      notifications = Enum.map(1..15, fn i ->
        %{id: i, title: "N#{i}", message: "M#{i}", level: "info"}
      end)

      alerts = ComponentBuilder.build_notification_alerts(notifications)
      assert length(alerts) == 10
    end
  end

  describe "build_agent_badges/1" do
    test "returns badge components for each agent" do
      agents = [
        %{id: "a1", name: "Alpha", status: "active"},
        %{id: "a2", name: "Beta", status: "error"}
      ]

      badges = ComponentBuilder.build_agent_badges(agents)
      assert length(badges) == 2
      assert Enum.all?(badges, &(&1.type == "badge"))
    end

    test "badge variant matches status" do
      agents = [
        %{id: "a1", name: "Alpha", status: "active"},
        %{id: "a2", name: "Beta", status: "error"},
        %{id: "a3", name: "Gamma", status: "idle"},
        %{id: "a4", name: "Delta", status: "discovered"}
      ]

      badges = ComponentBuilder.build_agent_badges(agents)
      badge_map = Enum.into(badges, %{}, fn b -> {b.label, b.variant} end)

      assert badge_map["Alpha"] == "success"
      assert badge_map["Beta"] == "error"
      assert badge_map["Gamma"] == "ghost"
      assert badge_map["Delta"] == "info"
    end
  end

  describe "build_tier_progress/1" do
    test "returns progress components grouped by tier" do
      agents = [
        %{id: "a1", tier: 1, status: "active"},
        %{id: "a2", tier: 1, status: "idle"},
        %{id: "a3", tier: 2, status: "active"}
      ]

      progress = ComponentBuilder.build_tier_progress(agents)
      assert length(progress) == 2
      assert Enum.all?(progress, &(&1.type == "progress"))
    end

    test "progress percentage is calculated correctly" do
      agents = [
        %{id: "a1", tier: 1, status: "active"},
        %{id: "a2", tier: 1, status: "idle"},
        %{id: "a3", tier: 2, status: "active"},
        %{id: "a4", tier: 2, status: "active"}
      ]

      progress = ComponentBuilder.build_tier_progress(agents)
      tier1 = Enum.find(progress, &(&1.label == "Tier 1"))
      tier2 = Enum.find(progress, &(&1.label == "Tier 2"))

      assert tier1.value == 2
      assert tier1.max == 4
      assert tier1.percentage == 50.0

      assert tier2.value == 2
      assert tier2.max == 4
      assert tier2.percentage == 50.0
    end

    test "handles empty agents without division by zero" do
      progress = ComponentBuilder.build_tier_progress([])
      assert progress == []
    end
  end
end
