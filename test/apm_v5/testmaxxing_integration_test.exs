defmodule ApmV5.TestmaxxingIntegrationTest do
  use ApmV5Web.ConnCase, async: false

  @moduletag :testmaxxing

  alias ApmV5.AgentRegistry
  alias ApmV5.UpmStore
  alias ApmV5.FormationDot

  setup do
    ApmV5.GenServerHelpers.ensure_processes_alive()
    AgentRegistry.clear_all()

    case Process.whereis(UpmStore) do
      nil ->
        {:ok, _} = UpmStore.start_link([])

      _pid ->
        :ok
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # 1. Typed edges in push_formation_graph
  # ---------------------------------------------------------------------------

  describe "typed edges in formation graph data" do
    test "agents registered with pub/sub metadata in nested :metadata map have those fields stored" do
      fmt_id = "fmt-test-typed-edges"

      # pub/sub fields are nested in :metadata so FormationLive can access via
      # get_in(raw, [:metadata, :publishes])
      :ok =
        AgentRegistry.register_agent("typed-worker-1", %{
          formation_id: fmt_id,
          squadron: "alpha",
          name: "worker-one",
          metadata: %{publishes: ["alpha.w1.results"], subscribes: [], exports: [], imports: []}
        })

      :ok =
        AgentRegistry.register_agent("typed-lead-1", %{
          formation_id: fmt_id,
          squadron: "alpha",
          name: "alpha-lead",
          metadata: %{
            publishes: ["alpha.results"],
            subscribes: ["alpha.w1.results"],
            exports: [],
            imports: []
          }
        })

      worker = AgentRegistry.get_agent("typed-worker-1")
      assert get_in(worker, [:metadata, :publishes]) == ["alpha.w1.results"]
      assert get_in(worker, [:metadata, :subscribes]) == []

      lead = AgentRegistry.get_agent("typed-lead-1")
      assert get_in(lead, [:metadata, :subscribes]) == ["alpha.w1.results"]
      assert get_in(lead, [:metadata, :publishes]) == ["alpha.results"]
    end

    test "hierarchy edge_type is produced for formation -> squadron -> agent chain" do
      fmt_id = "fmt-test-hierarchy"

      :ok =
        AgentRegistry.register_agent("h-agent-1", %{
          formation_id: fmt_id,
          squadron: "bravo",
          name: "hierarchy-worker"
        })

      agents = AgentRegistry.list_formation(fmt_id)
      assert length(agents) == 1

      agent = hd(agents)
      assert agent.formation_id == fmt_id
      assert agent.squadron == "bravo"

      # Verify the DOT output contains hierarchy connections.
      # FormationDot sanitizes hyphens to underscores in node IDs, so
      # "h-agent-1" becomes "h_agent_1" in the DOT source.
      dot_src = FormationDot.generate(fmt_id, agents)
      assert String.contains?(dot_src, "digraph")
      assert String.contains?(dot_src, "h_agent_1")
      # Agent label is the name, not the id
      assert String.contains?(dot_src, "hierarchy-worker")
      # All edges rendered by FormationDot are black = hierarchy
      assert String.contains?(dot_src, ~s'[color="black"]')
    end

    test "pubsub edges are derivable from publishes/subscribes nested in agent metadata" do
      fmt_id = "fmt-test-pubsub-edges"

      :ok =
        AgentRegistry.register_agent("ps-publisher-1", %{
          formation_id: fmt_id,
          squadron: "sq1",
          name: "publisher",
          metadata: %{publishes: ["sq1.output"], subscribes: []}
        })

      :ok =
        AgentRegistry.register_agent("ps-subscriber-1", %{
          formation_id: fmt_id,
          squadron: "sq1",
          name: "subscriber",
          metadata: %{publishes: [], subscribes: ["sq1.output"]}
        })

      all_agents = AgentRegistry.list_agents()

      # Build publisher_map: channel -> publisher id (mirrors FormationLive logic)
      publisher_map =
        all_agents
        |> Enum.flat_map(fn a ->
          pubs = get_in(a, [:metadata, :publishes]) || []
          Enum.map(pubs, fn ch -> {ch, a.id} end)
        end)
        |> Map.new()

      assert Map.has_key?(publisher_map, "sq1.output")
      assert publisher_map["sq1.output"] == "ps-publisher-1"

      # Derive pubsub edge for subscriber (mirrors FormationLive logic)
      pubsub_edges =
        all_agents
        |> Enum.flat_map(fn a ->
          subs = get_in(a, [:metadata, :subscribes]) || []

          Enum.flat_map(subs, fn ch ->
            case Map.get(publisher_map, ch) do
              nil -> []
              pub_id -> [%{source: pub_id, target: a.id, edge_type: "pubsub"}]
            end
          end)
        end)

      ps_edge =
        Enum.find(pubsub_edges, fn e ->
          e.source == "ps-publisher-1" and e.target == "ps-subscriber-1"
        end)

      refute is_nil(ps_edge)
      assert ps_edge.edge_type == "pubsub"
    end

    test "data_export edges are derivable from exports/imports nested in agent metadata" do
      fmt_id = "fmt-test-data-export"

      :ok =
        AgentRegistry.register_agent("de-exporter-1", %{
          formation_id: fmt_id,
          squadron: "bravo",
          name: "bravo-lead",
          metadata: %{publishes: ["bravo.results"], exports: ["auth_session_cookie"], imports: []}
        })

      :ok =
        AgentRegistry.register_agent("de-importer-1", %{
          formation_id: fmt_id,
          squadron: "charlie",
          name: "charlie-lead",
          metadata: %{publishes: ["charlie.results"], exports: [], imports: ["auth_session_cookie"]}
        })

      all_agents = AgentRegistry.list_agents()

      # Build export map: export_label -> exporter id (mirrors FormationLive logic)
      export_map =
        all_agents
        |> Enum.flat_map(fn a ->
          exports = get_in(a, [:metadata, :exports]) || []
          Enum.map(exports, fn key -> {key, a.id} end)
        end)
        |> Map.new()

      assert Map.has_key?(export_map, "auth_session_cookie")
      assert export_map["auth_session_cookie"] == "de-exporter-1"

      # Derive data_export edge for importer (mirrors FormationLive logic)
      data_export_edges =
        all_agents
        |> Enum.flat_map(fn a ->
          imports = get_in(a, [:metadata, :imports]) || []

          Enum.flat_map(imports, fn imp ->
            case Map.get(export_map, imp) do
              nil -> []
              exp_id -> [%{source: exp_id, target: a.id, edge_type: "data_export"}]
            end
          end)
        end)

      de_edge =
        Enum.find(data_export_edges, fn e ->
          e.source == "de-exporter-1" and e.target == "de-importer-1"
        end)

      refute is_nil(de_edge)
      assert de_edge.edge_type == "data_export"
    end
  end

  # ---------------------------------------------------------------------------
  # 2. Notification channel field
  # ---------------------------------------------------------------------------

  describe "notification channel and source fields" do
    test "notification stored with channel and source when provided" do
      id =
        AgentRegistry.add_notification(%{
          title: "test",
          channel: "alpha.w1.results",
          source: "testmaxxing-pubsub"
        })

      assert is_integer(id) or is_binary(id)

      {:ok, notif} = AgentRegistry.get_notification(id)
      assert notif.channel == "alpha.w1.results"
      assert notif.source == "testmaxxing-pubsub"
      assert notif.title == "test"
    end

    test "notification channel and source default to nil when not provided" do
      id =
        AgentRegistry.add_notification(%{
          title: "bare notification"
        })

      {:ok, notif} = AgentRegistry.get_notification(id)
      assert is_nil(notif.channel)
      assert is_nil(notif.source)
    end

    test "multiple notifications with different channels are all retrievable" do
      AgentRegistry.add_notification(%{title: "n1", channel: "alpha.w1.results", source: "agent-a"})
      AgentRegistry.add_notification(%{title: "n2", channel: "bravo.w4.results", source: "agent-b"})
      AgentRegistry.add_notification(%{title: "n3"})

      all = AgentRegistry.get_notifications()
      assert length(all) >= 3

      channels = Enum.map(all, & &1.channel) |> Enum.sort()
      assert "alpha.w1.results" in channels
      assert "bravo.w4.results" in channels
    end
  end

  # ---------------------------------------------------------------------------
  # 3. DOT endpoint
  # ---------------------------------------------------------------------------

  describe "GET /api/formations/:id/dot" do
    test "returns 200 with text/plain content-type and digraph body for registered formation" do
      fmt_id = "fmt-dot-test-#{System.system_time(:millisecond)}"

      :ok =
        AgentRegistry.register_agent("dot-agent-alpha", %{
          formation_id: fmt_id,
          squadron: "alpha",
          name: "dot-worker"
        })

      conn = get(build_conn(), "/api/formations/#{fmt_id}/dot")

      # Endpoint returns 200 with DOT source
      assert conn.status == 200

      content_type = get_resp_header(conn, "content-type") |> List.first() || ""
      assert String.contains?(content_type, "text/plain")

      body = conn.resp_body
      assert String.contains?(body, "digraph")
      # FormationDot uses agent name as the label and sanitized id as the node id.
      # "dot-agent-alpha" -> node id "dot_agent_alpha", label "dot-worker"
      assert String.contains?(body, "dot_agent_alpha") or String.contains?(body, "dot-worker")
    end

    test "returns 404 for non-existent formation" do
      conn = get(build_conn(), "/api/formations/fmt-nonexistent-xyz/dot")
      assert conn.status == 404

      body = Jason.decode!(conn.resp_body)
      assert Map.has_key?(body, "error")
    end

    test "DOT body contains agent names from the formation" do
      fmt_id = "fmt-dot-multi-#{System.system_time(:millisecond)}"

      for i <- 1..3 do
        :ok =
          AgentRegistry.register_agent("dot-agent-#{i}", %{
            formation_id: fmt_id,
            squadron: "sq#{i}",
            name: "agent-#{i}"
          })
      end

      conn = get(build_conn(), "/api/formations/#{fmt_id}/dot")
      assert conn.status == 200

      body = conn.resp_body
      assert String.contains?(body, "digraph")

      # FormationDot sanitizes hyphens to underscores in node IDs.
      # "dot-agent-1" becomes "dot_agent_1" in DOT output; labels use agent name.
      Enum.each(1..3, fn i ->
        sanitized = "dot_agent_#{i}"
        label = "agent-#{i}"
        assert String.contains?(body, sanitized) or String.contains?(body, label)
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # 4. Testmaxxing template
  # ---------------------------------------------------------------------------

  describe "UpmStore.testmaxxing_template/0" do
    test "returns a map with 5 squadrons" do
      template = UpmStore.testmaxxing_template()

      assert is_map(template)
      assert template["template"] == "testmaxxing"

      squadrons = template["squadrons"]
      assert is_list(squadrons)
      assert length(squadrons) == 5
    end

    test "template has 20 agents total: 14 workers + 5 leads + 1 orchestrator" do
      template = UpmStore.testmaxxing_template()
      squadrons = template["squadrons"]

      worker_count =
        Enum.reduce(squadrons, 0, fn sq, acc ->
          acc + length(sq["agents"])
        end)

      lead_count = length(squadrons)

      orchestrator = template["orchestrator"]
      refute is_nil(orchestrator)

      assert worker_count == 14
      assert lead_count == 5
      assert worker_count + lead_count + 1 == 20
    end

    test "channel list has 20 entries" do
      template = UpmStore.testmaxxing_template()

      channels = template["channels"]
      assert is_list(channels)
      assert length(channels) == 20
    end

    test "exports map has bravo as source exporting to charlie and delta" do
      template = UpmStore.testmaxxing_template()

      exports = template["exports"]
      assert is_map(exports)
      assert Map.has_key?(exports, "bravo")

      bravo_export = exports["bravo"]
      assert is_map(bravo_export)

      targets = bravo_export["targets"]
      assert is_list(targets)
      assert "charlie" in targets
      assert "delta" in targets
    end

    test "template accepts an optional date and uses it in the formation id" do
      template = UpmStore.testmaxxing_template("20260101")
      assert template["id"] =~ "fmt-20260101"
    end
  end

  describe "UpmStore.create_from_template/1" do
    test "registers the testmaxxing formation and returns ok tuple with formation id" do
      result = UpmStore.create_from_template("testmaxxing")

      assert {:ok, formation_id} = result
      assert is_binary(formation_id)
      assert formation_id =~ "fmt-"

      formation = UpmStore.get_formation(formation_id)
      refute is_nil(formation)
      # register_formation stores the formation with atom keys from the struct
      assert formation.id == formation_id
      assert is_binary(formation.name)
    end

    test "registered formation has a non-empty name derived from the template" do
      {:ok, formation_id} = UpmStore.create_from_template("testmaxxing")

      formation = UpmStore.get_formation(formation_id)
      # The template sets "name" => "Testmaxxing Formation"
      assert formation.name == "Testmaxxing Formation"
    end

    test "formation is listed after creation" do
      {:ok, formation_id} = UpmStore.create_from_template("testmaxxing")

      formations = UpmStore.list_formations()
      ids = Enum.map(formations, fn f -> f.id end)
      assert formation_id in ids
    end

    test "returns error for unknown template" do
      assert {:error, :unknown_template} = UpmStore.create_from_template("nonexistent-template")
    end
  end

  # ---------------------------------------------------------------------------
  # 5. Agent registration with pub/sub fields via POST /api/register
  # ---------------------------------------------------------------------------

  describe "POST /api/register with pub/sub topology fields" do
    test "returns 201 ok with agent_id when pub/sub fields supplied" do
      agent_id = "pubsub-reg-#{System.system_time(:millisecond)}"

      conn =
        post(build_conn(), "/api/register", %{
          "agent_id" => agent_id,
          "name" => "pubsub-worker",
          "formation_id" => "fmt-reg-test",
          "squadron" => "alpha",
          "publishes" => ["alpha.output"],
          "subscribes" => ["alpha.input"]
        })

      assert conn.status == 201
      body = Jason.decode!(conn.resp_body)
      assert body["ok"] == true
      assert body["agent_id"] == agent_id
    end

    test "agent is retrievable after registration with pub/sub fields" do
      agent_id = "pubsub-retrieve-#{System.system_time(:millisecond)}"

      post(build_conn(), "/api/register", %{
        "agent_id" => agent_id,
        "name" => "pubsub-worker",
        "formation_id" => "fmt-reg-test",
        "squadron" => "alpha",
        "publishes" => ["alpha.output"],
        "subscribes" => ["alpha.input"],
        "exports" => ["session_token"],
        "imports" => ["db_credentials"]
      })

      agent = AgentRegistry.get_agent(agent_id)
      refute is_nil(agent)
      assert agent.id == agent_id
      assert agent.formation_id == "fmt-reg-test"
      assert agent.squadron == "alpha"
    end

    test "formation_id and squadron are stored on the agent" do
      agent_id = "formation-reg-#{System.system_time(:millisecond)}"
      fmt_id = "fmt-formation-reg-test"

      conn =
        post(build_conn(), "/api/register", %{
          "agent_id" => agent_id,
          "name" => "formation-worker",
          "formation_id" => fmt_id,
          "squadron" => "delta",
          "publishes" => ["delta.output"]
        })

      assert conn.status == 201

      agent = AgentRegistry.get_agent(agent_id)
      assert agent.formation_id == fmt_id
      assert agent.squadron == "delta"

      formation_agents = AgentRegistry.list_formation(fmt_id)
      ids = Enum.map(formation_agents, & &1.id)
      assert agent_id in ids
    end

    test "pub/sub fields stored in nested metadata map are accessible via get_in" do
      # Direct AgentRegistry call with metadata sub-map — the path FormationLive uses
      agent_id = "nested-pubsub-#{System.system_time(:millisecond)}"

      AgentRegistry.register_agent(agent_id, %{
        name: "nested-pubsub-worker",
        formation_id: "fmt-nested-test",
        metadata: %{
          publishes: ["nested.output"],
          subscribes: ["nested.input"],
          exports: ["token"],
          imports: ["creds"]
        }
      })

      agent = AgentRegistry.get_agent(agent_id)
      refute is_nil(agent)
      assert get_in(agent, [:metadata, :publishes]) == ["nested.output"]
      assert get_in(agent, [:metadata, :subscribes]) == ["nested.input"]
      assert get_in(agent, [:metadata, :exports]) == ["token"]
      assert get_in(agent, [:metadata, :imports]) == ["creds"]
    end
  end
end
