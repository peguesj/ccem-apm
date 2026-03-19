defmodule ApmV5.PortManagerTest do
  use ExUnit.Case, async: false

  alias ApmV5.PortManager

  setup do
    # Ensure PubSub is running
    case Process.whereis(ApmV5.PubSub) do
      nil -> Phoenix.PubSub.Supervisor.start_link(name: ApmV5.PubSub)
      _pid -> :ok
    end

    # Ensure ConfigLoader is running (PortManager depends on it)
    case Process.whereis(ApmV5.ConfigLoader) do
      nil ->
        case ApmV5.ConfigLoader.start_link([]) do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
        end
      _pid -> :ok
    end

    # Ensure PortManager is running
    case Process.whereis(PortManager) do
      nil ->
        {:ok, _pid} = PortManager.start_link([])
        # Wait for handle_continue :initial_scan to complete (runs lsof)
        Process.sleep(500)
      _pid ->
        :ok
    end

    :ok
  end

  describe "get_port_map/0" do
    test "returns a map" do
      port_map = PortManager.get_port_map()
      assert is_map(port_map)
    end

    test "port map values contain project and namespace" do
      port_map = PortManager.get_port_map()

      case Map.to_list(port_map) do
        [{port, info} | _] ->
          assert is_integer(port)
          assert Map.has_key?(info, :project)
          assert Map.has_key?(info, :namespace)

        [] ->
          # No configured ports is valid — depends on session files
          assert port_map == %{}
      end
    end
  end

  describe "get_port_ranges/0" do
    test "returns namespace ranges" do
      ranges = PortManager.get_port_ranges()

      assert ranges[:web] == 3000..3999
      assert ranges[:api] == 4000..4999
      assert ranges[:service] == 5000..6999
      assert ranges[:tool] == 7000..9999
    end
  end

  describe "scan_active_ports/0" do
    test "returns a map of active ports" do
      active = PortManager.scan_active_ports()
      assert is_map(active)
    end

    test "active ports have pid and command fields" do
      active = PortManager.scan_active_ports()

      case Map.to_list(active) do
        [{port, info} | _] ->
          assert is_integer(port)
          assert is_integer(info.pid)
          assert is_binary(info.command)
          assert info.namespace in [:web, :api, :service, :tool, :other]

        [] ->
          # No active ports is valid in a test environment
          :ok
      end
    end
  end

  describe "detect_clashes/0" do
    test "returns a list" do
      clashes = PortManager.detect_clashes()
      assert is_list(clashes)
    end

    test "clash entries contain port and projects" do
      clashes = PortManager.detect_clashes()

      for clash <- clashes do
        assert is_integer(clash.port)
        assert is_list(clash.projects)
        assert length(clash.projects) > 1
      end
    end
  end

  describe "assign_port/1 with namespace atom" do
    test "assigns a port in the web namespace" do
      result = PortManager.assign_port(:web)
      assert {:ok, port} = result
      assert port in 3000..3999
    end

    test "assigns a port in the api namespace" do
      result = PortManager.assign_port(:api)
      assert {:ok, port} = result
      assert port in 4000..4999
    end

    test "assigns a port in the service namespace" do
      result = PortManager.assign_port(:service)
      assert {:ok, port} = result
      assert port in 5000..6999
    end

    test "assigns a port in the tool namespace" do
      result = PortManager.assign_port(:tool)
      assert {:ok, port} = result
      assert port in 7000..9999
    end
  end

  describe "assign_port/1 with project name string" do
    test "assigns a port in the web namespace for a project" do
      result = PortManager.assign_port("my-project")
      assert {:ok, port} = result
      assert port in 3000..3999
    end
  end

  describe "get_project_configs/0" do
    test "returns a map" do
      configs = PortManager.get_project_configs()
      assert is_map(configs)
    end

    test "project configs have expected structure" do
      configs = PortManager.get_project_configs()

      for {name, config} <- configs do
        assert is_binary(name)
        assert Map.has_key?(config, :root)
        assert Map.has_key?(config, :ports)
        assert Map.has_key?(config, :stack)
        assert is_list(config.ports)
      end
    end
  end

  describe "suggest_remediation/1" do
    test "returns suggestion map for any port" do
      suggestion = PortManager.suggest_remediation(3000)

      assert is_map(suggestion)
      assert suggestion.port == 3000
      assert is_list(suggestion.claimants)
      assert is_list(suggestion.alternatives)
      assert is_binary(suggestion.recommendation)
    end
  end

  describe "reassign_port/2" do
    test "returns {:error, :project_not_found} for unknown project" do
      assert {:error, :project_not_found} = PortManager.reassign_port("nonexistent-proj", 3500)
    end
  end
end
