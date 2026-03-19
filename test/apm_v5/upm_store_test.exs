defmodule ApmV5.UpmStoreTest do
  use ExUnit.Case, async: false

  alias ApmV5.UpmStore

  setup do
    # Ensure PubSub is running
    case Process.whereis(ApmV5.PubSub) do
      nil -> Phoenix.PubSub.Supervisor.start_link(name: ApmV5.PubSub)
      _pid -> :ok
    end

    # Ensure AgentRegistry is running (register_agent/1 delegates to it)
    case Process.whereis(ApmV5.AgentRegistry) do
      nil ->
        case ApmV5.AgentRegistry.start_link([]) do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
        end
      _pid -> :ok
    end

    # Ensure UpmStore is running
    case Process.whereis(UpmStore) do
      nil ->
        {:ok, _pid} = UpmStore.start_link([])
      _pid ->
        :ok
    end

    # Clear ETS tables between tests
    :ets.delete_all_objects(:upm_sessions)
    :ets.delete_all_objects(:upm_events)
    :ets.delete_all_objects(:upm_formations)

    :ok
  end

  describe "register_session/1" do
    test "creates session in ETS and returns {:ok, session_id}" do
      params = %{
        "stories" => [%{"id" => "US-001", "title" => "First Story"}],
        "waves" => 3,
        "prd_branch" => "feature/prd-1",
        "plane_project_id" => "proj-abc"
      }

      assert {:ok, session_id} = UpmStore.register_session(params)
      assert String.starts_with?(session_id, "upm-")
    end

    test "stores session with correct fields" do
      params = %{
        "stories" => ["US-001", "US-002"],
        "waves" => 2,
        "prd_branch" => "main"
      }

      {:ok, session_id} = UpmStore.register_session(params)
      session = UpmStore.get_session(session_id)

      assert session.id == session_id
      assert session.total_waves == 2
      assert session.current_wave == 0
      assert session.status == "registered"
      assert session.prd_branch == "main"
      assert length(session.stories) == 2
      assert %DateTime{} = session.started_at
    end

    test "parses binary stories into pending story maps" do
      params = %{"stories" => ["US-001", "US-002"]}

      {:ok, session_id} = UpmStore.register_session(params)
      session = UpmStore.get_session(session_id)

      [s1, s2] = session.stories
      assert s1.id == "US-001"
      assert s1.status == "pending"
      assert s1.agent_id == nil
      assert s2.id == "US-002"
    end

    test "parses map stories preserving fields" do
      params = %{
        "stories" => [
          %{"id" => "US-001", "title" => "Story One", "plane_issue_id" => "CCEM-42"}
        ]
      }

      {:ok, session_id} = UpmStore.register_session(params)
      session = UpmStore.get_session(session_id)

      [story] = session.stories
      assert story.id == "US-001"
      assert story.title == "Story One"
      assert story.plane_issue_id == "CCEM-42"
      assert story.status == "pending"
    end

    test "defaults waves to 1 when not specified" do
      {:ok, session_id} = UpmStore.register_session(%{})
      session = UpmStore.get_session(session_id)
      assert session.total_waves == 1
    end
  end

  describe "get_status/0" do
    test "returns %{active: false, session: nil} when no sessions exist" do
      status = UpmStore.get_status()

      assert status.active == false
      assert status.session == nil
      assert status.events == []
    end

    test "returns %{active: true, session: %{...}} with valid session data" do
      {:ok, _id} = UpmStore.register_session(%{"stories" => ["US-001"], "waves" => 2})

      status = UpmStore.get_status()

      assert status.active == true
      assert status.session != nil
      assert status.session.status == "registered"
    end

    test "returns most recent session by started_at when multiple exist" do
      {:ok, id1} = UpmStore.register_session(%{"stories" => ["US-001"]})
      Process.sleep(10)
      {:ok, id2} = UpmStore.register_session(%{"stories" => ["US-002"]})

      status = UpmStore.get_status()

      # Most recent session should be returned
      assert status.session.id == id2
      assert status.active == true

      # Verify both sessions exist
      sessions = UpmStore.list_sessions()
      assert length(sessions) == 2
      assert hd(sessions).id == id2

      # Verify id1 still accessible
      assert UpmStore.get_session(id1) != nil
    end
  end

  describe "record_event/1" do
    test "stores event and returns :ok" do
      {:ok, session_id} = UpmStore.register_session(%{"stories" => ["US-001"]})

      assert :ok =
               UpmStore.record_event(%{
                 "upm_session_id" => session_id,
                 "event_type" => "wave_start",
                 "data" => %{"wave" => 1}
               })
    end

    test "wave_start event updates session current_wave and status" do
      {:ok, session_id} = UpmStore.register_session(%{"stories" => ["US-001"], "waves" => 3})

      UpmStore.record_event(%{
        "upm_session_id" => session_id,
        "event_type" => "wave_start",
        "data" => %{"wave" => 2}
      })

      session = UpmStore.get_session(session_id)
      assert session.current_wave == 2
      assert session.status == "running"
    end

    test "story_pass event updates story status" do
      {:ok, session_id} = UpmStore.register_session(%{"stories" => ["US-001", "US-002"]})

      UpmStore.record_event(%{
        "upm_session_id" => session_id,
        "event_type" => "story_pass",
        "data" => %{"story_id" => "US-001"}
      })

      session = UpmStore.get_session(session_id)
      passed = Enum.find(session.stories, &(&1.id == "US-001"))
      pending = Enum.find(session.stories, &(&1.id == "US-002"))
      assert passed.status == "passed"
      assert pending.status == "pending"
    end

    test "story_fail event updates story status" do
      {:ok, session_id} = UpmStore.register_session(%{"stories" => ["US-001"]})

      UpmStore.record_event(%{
        "upm_session_id" => session_id,
        "event_type" => "story_fail",
        "data" => %{"story_id" => "US-001"}
      })

      session = UpmStore.get_session(session_id)
      [story] = session.stories
      assert story.status == "failed"
    end

    test "verify_complete event sets session to verified" do
      {:ok, session_id} = UpmStore.register_session(%{"stories" => ["US-001"]})

      UpmStore.record_event(%{
        "upm_session_id" => session_id,
        "event_type" => "verify_complete",
        "data" => %{}
      })

      session = UpmStore.get_session(session_id)
      assert session.status == "verified"
    end

    test "ship event sets session to shipped" do
      {:ok, session_id} = UpmStore.register_session(%{"stories" => ["US-001"]})

      UpmStore.record_event(%{
        "upm_session_id" => session_id,
        "event_type" => "ship",
        "data" => %{}
      })

      session = UpmStore.get_session(session_id)
      assert session.status == "shipped"
    end

    test "events are retrievable via get_events/1" do
      {:ok, session_id} = UpmStore.register_session(%{"stories" => ["US-001"]})

      UpmStore.record_event(%{
        "upm_session_id" => session_id,
        "event_type" => "wave_start",
        "data" => %{"wave" => 1}
      })

      UpmStore.record_event(%{
        "upm_session_id" => session_id,
        "event_type" => "wave_complete",
        "data" => %{}
      })

      events = UpmStore.get_events(session_id)
      assert length(events) == 2
      assert Enum.at(events, 0).event_type == "wave_start"
      assert Enum.at(events, 1).event_type == "wave_complete"
    end
  end

  describe "get_session/1" do
    test "returns nil for unknown session" do
      assert UpmStore.get_session("nonexistent") == nil
    end
  end

  describe "list_sessions/0" do
    test "returns all sessions sorted by started_at desc" do
      {:ok, _id1} = UpmStore.register_session(%{"stories" => ["US-001"]})
      Process.sleep(10)
      {:ok, id2} = UpmStore.register_session(%{"stories" => ["US-002"]})

      sessions = UpmStore.list_sessions()
      assert length(sessions) == 2
      assert hd(sessions).id == id2
    end

    test "returns empty list when no sessions" do
      assert UpmStore.list_sessions() == []
    end
  end

  describe "formation API" do
    test "register_formation/1 creates formation and returns {:ok, id}" do
      assert {:ok, id} =
               UpmStore.register_formation(%{
                 "name" => "fmt-test-001",
                 "squadrons" => ["sq1", "sq2"]
               })

      assert is_binary(id)
    end

    test "register_formation/1 uses provided id" do
      assert {:ok, "my-formation"} =
               UpmStore.register_formation(%{"id" => "my-formation", "name" => "Test Formation"})
    end

    test "get_formation/1 retrieves registered formation" do
      {:ok, id} = UpmStore.register_formation(%{"name" => "fmt-test"})

      formation = UpmStore.get_formation(id)
      assert formation.name == "fmt-test"
      assert formation.status == "registered"
      assert formation.events == []
    end

    test "get_formation/1 returns nil for unknown formation" do
      assert UpmStore.get_formation("nonexistent") == nil
    end

    test "list_formations/0 returns all formations" do
      UpmStore.register_formation(%{"name" => "fmt-1"})
      UpmStore.register_formation(%{"name" => "fmt-2"})

      formations = UpmStore.list_formations()
      assert length(formations) == 2
    end

    test "update_formation/2 updates fields" do
      {:ok, id} = UpmStore.register_formation(%{"name" => "fmt-test"})

      assert :ok = UpmStore.update_formation(id, %{status: "running"})

      formation = UpmStore.get_formation(id)
      assert formation.status == "running"
    end

    test "update_formation/2 returns {:error, :not_found} for unknown formation" do
      assert {:error, :not_found} = UpmStore.update_formation("nonexistent", %{status: "done"})
    end

    test "add_formation_event/2 appends event to formation" do
      {:ok, id} = UpmStore.register_formation(%{"name" => "fmt-test"})

      assert :ok = UpmStore.add_formation_event(id, %{type: "wave_start", wave: 1})
      assert :ok = UpmStore.add_formation_event(id, %{type: "wave_complete", wave: 1})

      formation = UpmStore.get_formation(id)
      assert length(formation.events) == 2
      assert Enum.at(formation.events, 0).type == "wave_start"
      assert Enum.at(formation.events, 1).type == "wave_complete"
    end

    test "add_formation_event/2 returns {:error, :not_found} for unknown formation" do
      assert {:error, :not_found} = UpmStore.add_formation_event("nonexistent", %{type: "test"})
    end

    test "get_active_formation/0 returns most recent active formation" do
      {:ok, _id1} = UpmStore.register_formation(%{"name" => "fmt-old"})
      Process.sleep(10)
      {:ok, id2} = UpmStore.register_formation(%{"name" => "fmt-new"})

      active = UpmStore.get_active_formation()
      assert active.id == id2
    end

    test "get_active_formation/0 returns nil when no active formations" do
      {:ok, id} = UpmStore.register_formation(%{"name" => "fmt-done"})
      UpmStore.update_formation(id, %{status: "completed"})

      assert UpmStore.get_active_formation() == nil
    end
  end

  describe "register_agent/1" do
    test "updates story-agent mapping in session" do
      {:ok, session_id} = UpmStore.register_session(%{"stories" => ["US-001", "US-002"]})

      assert :ok =
               UpmStore.register_agent(%{
                 "upm_session_id" => session_id,
                 "story_id" => "US-001",
                 "agent_id" => "agent-worker-1",
                 "wave" => 1,
                 "title" => "First Story"
               })

      session = UpmStore.get_session(session_id)
      assigned = Enum.find(session.stories, &(&1.id == "US-001"))
      unassigned = Enum.find(session.stories, &(&1.id == "US-002"))

      assert assigned.agent_id == "agent-worker-1"
      assert assigned.status == "in_progress"
      assert unassigned.agent_id == nil
      assert unassigned.status == "pending"
    end

    test "returns {:error, :session_not_found} for unknown session" do
      assert {:error, :session_not_found} =
               UpmStore.register_agent(%{
                 "upm_session_id" => "nonexistent",
                 "story_id" => "US-001",
                 "agent_id" => "agent-1"
               })
    end
  end
end
