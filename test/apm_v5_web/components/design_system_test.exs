defmodule ApmV5Web.Components.DesignSystemTest do
  @moduledoc """
  DS TDD suite — smoke tests for every design system component (CP-174 / US-449).

  Run with: mix test --only design_system
  """

  use ApmV5Web.ConnCase, async: true

  @moduletag :design_system

  import Phoenix.Component
  import Phoenix.LiveViewTest

  # Alias all component modules for brevity in tests.
  alias ApmV5Web.Components.DesignSystem, as: DS
  alias ApmV5Web.Components.AiComponents, as: AI
  alias ApmV5Web.Components.GraphComponents, as: GC
  alias ApmV5Web.Components.TopBar, as: TB
  alias ApmV5Web.Components.InspectorPanel, as: IP
  alias ApmV5Web.Components.PageLayout, as: PL

  # ---------------------------------------------------------------------------
  # Rendering helper — produces an HTML string from a component function + assigns
  # ---------------------------------------------------------------------------

  defp r(fun, assigns \\ []) do
    assigns_map = Map.new([{:__changed__, nil} | assigns])
    fun.(assigns_map) |> rendered_to_string()
  end

  # ---------------------------------------------------------------------------
  # DesignSystem — btn/1
  # ---------------------------------------------------------------------------

  describe "DesignSystem.btn/1" do
    test "primary variant renders a button" do
      html = r(&DS.btn/1, variant: "primary", size: "md", inner_block: [])
      assert html =~ "<button"
    end

    test "primary variant contains accent background" do
      html = r(&DS.btn/1, variant: "primary", size: "md", inner_block: [])
      assert html =~ "ccem-accent"
    end

    test "secondary variant contains bg-2 surface" do
      html = r(&DS.btn/1, variant: "secondary", size: "md", inner_block: [])
      assert html =~ "ccem-bg-2"
    end

    test "ghost variant contains transparent background" do
      html = r(&DS.btn/1, variant: "ghost", size: "md", inner_block: [])
      assert html =~ "transparent"
    end

    test "destructive variant contains err color" do
      html = r(&DS.btn/1, variant: "destructive", size: "md", inner_block: [])
      assert html =~ "ccem-err"
    end

    test "icon variant renders aspect-ratio 1/1" do
      html = r(&DS.btn/1, variant: "icon", size: "md", inner_block: [])
      assert html =~ "aspect-ratio"
    end

    test "xs size applies 1.5rem height" do
      html = r(&DS.btn/1, variant: "secondary", size: "xs", inner_block: [])
      assert html =~ "1.5rem"
    end

    test "sm size applies 1.75rem height" do
      html = r(&DS.btn/1, variant: "secondary", size: "sm", inner_block: [])
      assert html =~ "1.75rem"
    end

    test "md size applies 2rem height" do
      html = r(&DS.btn/1, variant: "secondary", size: "md", inner_block: [])
      assert html =~ "2rem"
    end

    test "lg size applies 2.5rem height" do
      html = r(&DS.btn/1, variant: "secondary", size: "lg", inner_block: [])
      assert html =~ "2.5rem"
    end
  end

  # ---------------------------------------------------------------------------
  # DesignSystem — badge/1
  # ---------------------------------------------------------------------------

  describe "DesignSystem.badge/1" do
    test "neutral tone renders span" do
      html = r(&DS.badge/1, tone: "neutral", inner_block: [])
      assert html =~ "<span"
    end

    test "accent tone contains ccem-accent" do
      html = r(&DS.badge/1, tone: "accent", inner_block: [])
      assert html =~ "ccem-accent"
    end

    test "ok tone contains ccem-ok" do
      html = r(&DS.badge/1, tone: "ok", inner_block: [])
      assert html =~ "ccem-ok"
    end

    test "warn tone contains ccem-warn" do
      html = r(&DS.badge/1, tone: "warn", inner_block: [])
      assert html =~ "ccem-warn"
    end

    test "err tone contains ccem-err" do
      html = r(&DS.badge/1, tone: "err", inner_block: [])
      assert html =~ "ccem-err"
    end

    test "info tone contains ccem-info" do
      html = r(&DS.badge/1, tone: "info", inner_block: [])
      assert html =~ "ccem-info"
    end

    test "iris tone contains ccem-iris" do
      html = r(&DS.badge/1, tone: "iris", inner_block: [])
      assert html =~ "ccem-iris"
    end

    test "dot=true renders ccem-pulse class" do
      html = r(&DS.badge/1, tone: "ok", dot: true, inner_block: [])
      assert html =~ "ccem-pulse"
    end

    test "dot=false omits ccem-pulse class" do
      html = r(&DS.badge/1, tone: "ok", dot: false, inner_block: [])
      refute html =~ "ccem-pulse"
    end
  end

  # ---------------------------------------------------------------------------
  # DesignSystem — card/1
  # ---------------------------------------------------------------------------

  describe "DesignSystem.card/1" do
    test "renders a div" do
      html = r(&DS.card/1, inner_block: [])
      assert html =~ "<div"
    end

    test "default is padded" do
      html = r(&DS.card/1, padded: true, inner_block: [])
      assert html =~ "padding: 16px"
    end

    test "padded=false omits padding" do
      html = r(&DS.card/1, padded: false, inner_block: [])
      refute html =~ "padding: 16px"
    end
  end

  # ---------------------------------------------------------------------------
  # DesignSystem — stat_tile/1
  # ---------------------------------------------------------------------------

  describe "DesignSystem.stat_tile/1" do
    test "renders label text" do
      html = r(&DS.stat_tile/1, label: "Active Agents", value: "42")
      assert html =~ "Active Agents"
    end

    test "renders value text" do
      html = r(&DS.stat_tile/1, label: "Tokens", value: "1.2M")
      assert html =~ "1.2M"
    end

    test "renders delta when provided" do
      html = r(&DS.stat_tile/1, label: "Cost", value: "$5", delta: "+8%")
      assert html =~ "+8%"
    end
  end

  # ---------------------------------------------------------------------------
  # DesignSystem — segmented_control/1
  # ---------------------------------------------------------------------------

  describe "DesignSystem.segmented_control/1" do
    test "renders all options as buttons" do
      html = r(&DS.segmented_control/1, options: ["Overview", "Logs", "Metrics"], active: "Overview")
      assert html =~ "Overview"
      assert html =~ "Logs"
      assert html =~ "Metrics"
    end

    test "active option has aria-selected=true" do
      html = r(&DS.segmented_control/1, options: ["A", "B"], active: "A")
      assert html =~ ~s(aria-selected="true")
    end
  end

  # ---------------------------------------------------------------------------
  # DesignSystem — toggle/1
  # ---------------------------------------------------------------------------

  describe "DesignSystem.toggle/1" do
    test "renders role=switch" do
      html = r(&DS.toggle/1, on: false)
      assert html =~ ~s(role="switch")
    end

    test "on=true sets aria-checked=true" do
      html = r(&DS.toggle/1, on: true)
      assert html =~ ~s(aria-checked="true")
    end

    test "on=false sets aria-checked=false" do
      html = r(&DS.toggle/1, on: false)
      assert html =~ ~s(aria-checked="false")
    end
  end

  # ---------------------------------------------------------------------------
  # DesignSystem — kbd/1
  # ---------------------------------------------------------------------------

  describe "DesignSystem.kbd/1" do
    test "renders kbd element with key text" do
      html = r(&DS.kbd/1, key: "⌘")
      assert html =~ "<kbd"
      assert html =~ "⌘"
    end
  end

  # ---------------------------------------------------------------------------
  # DesignSystem — ds_input/1
  # ---------------------------------------------------------------------------

  describe "DesignSystem.ds_input/1" do
    test "text type renders input element" do
      html = r(&DS.ds_input/1, type: "text", placeholder: "Enter text")
      assert html =~ ~s(type="text")
    end

    test "search type without suffix shows cmd-K chip" do
      html = r(&DS.ds_input/1, type: "search")
      assert html =~ "⌘K"
    end
  end

  # ---------------------------------------------------------------------------
  # DesignSystem — data_table/1
  # ---------------------------------------------------------------------------

  describe "DesignSystem.data_table/1" do
    test "renders table element" do
      html =
        r(&DS.data_table/1,
          rows: [],
          col: [%{label: "Name", inner_block: [], __slot__: :col}]
        )

      assert html =~ "<table"
    end

    test "renders column headers from slot label" do
      html =
        r(&DS.data_table/1,
          rows: [],
          col: [
            %{label: "Agent", inner_block: [], __slot__: :col},
            %{label: "Status", inner_block: [], __slot__: :col}
          ]
        )

      assert html =~ "Agent"
      assert html =~ "Status"
    end
  end

  # ---------------------------------------------------------------------------
  # AiComponents — sparkline/1
  # ---------------------------------------------------------------------------

  describe "AiComponents.sparkline/1" do
    test "renders SVG element" do
      html = r(&AI.sparkline/1, data: [10, 20, 30, 40, 50])
      assert html =~ "<svg"
    end

    test "renders polyline for data" do
      html = r(&AI.sparkline/1, data: [10, 20, 30])
      assert html =~ "<polyline"
    end

    test "live_dot=true renders pulse circle" do
      html = r(&AI.sparkline/1, data: [10, 20, 30], live_dot: true)
      assert html =~ "ccem-pulse"
    end
  end

  # ---------------------------------------------------------------------------
  # AiComponents — streaming_text/1
  # ---------------------------------------------------------------------------

  describe "AiComponents.streaming_text/1" do
    test "renders text content" do
      html = r(&AI.streaming_text/1, text: "Hello world")
      assert html =~ "Hello world"
    end

    test "streaming=true shows caret element" do
      html = r(&AI.streaming_text/1, text: "Streaming", streaming: true)
      assert html =~ "ccem-caret"
    end

    test "streaming=false hides caret" do
      html = r(&AI.streaming_text/1, text: "Done", streaming: false)
      refute html =~ "ccem-caret"
    end
  end

  # ---------------------------------------------------------------------------
  # AiComponents — skeleton/1
  # ---------------------------------------------------------------------------

  describe "AiComponents.skeleton/1" do
    test "renders shimmer element" do
      html = r(&AI.skeleton/1, [])
      assert html =~ "ccem-shimmer"
    end

    test "lines=3 renders three shimmer bars" do
      html = r(&AI.skeleton/1, lines: 3)
      # 3 shimmer divs → String.split produces 4 parts
      assert length(String.split(html, "ccem-shimmer")) >= 4
    end
  end

  # ---------------------------------------------------------------------------
  # AiComponents — waveform/1
  # ---------------------------------------------------------------------------

  describe "AiComponents.waveform/1" do
    test "renders aria label Processing" do
      html = r(&AI.waveform/1, [])
      assert html =~ "Processing"
    end

    test "active=false freezes bars with scaleY" do
      html = r(&AI.waveform/1, active: false)
      assert html =~ "scaleY(0.4)"
    end
  end

  # ---------------------------------------------------------------------------
  # AiComponents — gauge/1
  # ---------------------------------------------------------------------------

  describe "AiComponents.gauge/1" do
    test "renders SVG gauge element" do
      html = r(&AI.gauge/1, value: 72)
      assert html =~ "<svg"
      assert html =~ "<circle"
    end

    test "renders value text in center" do
      html = r(&AI.gauge/1, value: 72)
      assert html =~ "72"
    end
  end

  # ---------------------------------------------------------------------------
  # AiComponents — presence_stack/1
  # ---------------------------------------------------------------------------

  describe "AiComponents.presence_stack/1" do
    test "renders user initials" do
      html =
        r(&AI.presence_stack/1,
          users: [%{name: "Alice Smith", status: "active"}, %{name: "Bob Jones", status: "idle"}]
        )

      assert html =~ "AS"
      assert html =~ "BJ"
    end

    test "overflow beyond max renders plus badge" do
      html =
        r(&AI.presence_stack/1,
          users: [
            %{name: "A B", status: "active"},
            %{name: "C D", status: "active"},
            %{name: "E F", status: "active"},
            %{name: "G H", status: "active"},
            %{name: "I J", status: "active"}
          ],
          max: 4
        )

      assert html =~ "+1"
    end
  end

  # ---------------------------------------------------------------------------
  # AiComponents — agent_card/1
  # ---------------------------------------------------------------------------

  describe "AiComponents.agent_card/1" do
    test "renders agent name" do
      html = r(&AI.agent_card/1, agent_id: "agent-001", name: "Orchestrator Alpha", role: "orchestrator", status: "active")
      assert html =~ "Orchestrator Alpha"
    end

    test "renders role label" do
      html = r(&AI.agent_card/1, agent_id: "agent-002", name: "Scout", role: "swarm_agent", status: "idle")
      assert html =~ "swarm_agent"
    end

    test "renders identicon SVG" do
      html = r(&AI.agent_card/1, agent_id: "agent-003", name: "Beta", status: "idle")
      assert html =~ "<svg"
    end
  end

  # ---------------------------------------------------------------------------
  # AiComponents — bars/1
  # ---------------------------------------------------------------------------

  describe "AiComponents.bars/1" do
    test "renders SVG element with ccem-bars class" do
      html = r(&AI.bars/1, data: [%{value: 10}, %{value: 40}, %{value: 25}])
      assert html =~ "<svg"
      assert html =~ "ccem-bars"
    end

    test "renders one rect per data point" do
      html = r(&AI.bars/1, data: [%{value: 10}, %{value: 20}, %{value: 30}])
      # 3 data points → 3 <rect elements → split produces 4 parts
      assert length(String.split(html, "<rect")) == 4
    end
  end

  # ---------------------------------------------------------------------------
  # GraphComponents — graph_node/1
  # ---------------------------------------------------------------------------

  describe "GraphComponents.graph_node/1" do
    for role <- ~w(orchestrator squadron_lead swarm_agent cluster_agent individual) do
      @tag role: role
      test "renders #{role} role with data-node-id attribute", %{role: role} do
        html = r(&GC.graph_node/1, node_id: "n-#{role}", label: role, role: role)
        assert html =~ "data-node-id"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # GraphComponents — graph_edge/1
  # ---------------------------------------------------------------------------

  describe "GraphComponents.graph_edge/1" do
    for edge_type <- ~w(pubsub dependency data_flow default) do
      @tag edge_type: edge_type
      test "renders #{edge_type} edge type with data-edge-id attribute", %{edge_type: et} do
        html = r(&GC.graph_edge/1, edge_id: "e-#{et}", source_id: "a", target_id: "b", edge_type: et)
        assert html =~ "data-edge-id"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # TopBar — top_bar/1
  # ---------------------------------------------------------------------------

  describe "TopBar.top_bar/1" do
    test "renders header element with defaults" do
      html = r(&TB.top_bar/1, [])
      assert html =~ "<header"
    end

    test "renders custom project name" do
      html = r(&TB.top_bar/1, project_name: "MyProject")
      assert html =~ "MyProject"
    end

    test "renders cmd-K button" do
      html = r(&TB.top_bar/1, [])
      assert html =~ "⌘K"
    end
  end

  # ---------------------------------------------------------------------------
  # InspectorPanel — inspector_panel/1
  # ---------------------------------------------------------------------------

  describe "InspectorPanel.inspector_panel/1" do
    test "renders Inspector header when open=true" do
      html = r(&IP.inspector_panel/1, open: true, selection: [], copilot: [], filters: [])
      assert html =~ "Inspector"
    end

    test "renders display:none when open=false" do
      html = r(&IP.inspector_panel/1, open: false, selection: [], copilot: [], filters: [])
      assert html =~ "display:none"
    end
  end

  # ---------------------------------------------------------------------------
  # PageLayout — page_layout/1
  # ---------------------------------------------------------------------------

  describe "PageLayout.page_layout/1" do
    test "renders the ccem-sidebar zone" do
      html = r(&PL.page_layout/1, sidebar_collapsed: false, inspector_open: false, sidebar: [], main: [], topbar: [], inspector: [])
      assert html =~ "ccem-sidebar"
    end

    test "sidebar collapses to 48px when sidebar_collapsed=true" do
      html = r(&PL.page_layout/1, sidebar_collapsed: true, inspector_open: false, sidebar: [], main: [], topbar: [], inspector: [])
      assert html =~ "width:48px"
    end

    test "sidebar is 220px when sidebar_collapsed=false" do
      html = r(&PL.page_layout/1, sidebar_collapsed: false, inspector_open: false, sidebar: [], main: [], topbar: [], inspector: [])
      assert html =~ "width:220px"
    end

    test "inspector zone not rendered when inspector_open=false" do
      # Empty inspector slot + inspector_open=false → no 280px container
      html = r(&PL.page_layout/1, sidebar_collapsed: false, inspector_open: false, sidebar: [], main: [], topbar: [], inspector: [])
      refute html =~ "width:280px"
    end

    test "inspector zone not rendered when inspector slot is empty even if inspector_open=true" do
      # When the slot list is empty, the condition `@inspector != []` is false
      html = r(&PL.page_layout/1, sidebar_collapsed: false, inspector_open: true, sidebar: [], main: [], topbar: [], inspector: [])
      refute html =~ "width:280px"
    end

    test "renders full viewport height" do
      html = r(&PL.page_layout/1, sidebar_collapsed: false, inspector_open: false, sidebar: [], main: [], topbar: [], inspector: [])
      assert html =~ "height:100vh"
    end

    test "renders overflow:hidden on outer container" do
      html = r(&PL.page_layout/1, sidebar_collapsed: false, inspector_open: false, sidebar: [], main: [], topbar: [], inspector: [])
      assert html =~ "overflow:hidden"
    end
  end
end
