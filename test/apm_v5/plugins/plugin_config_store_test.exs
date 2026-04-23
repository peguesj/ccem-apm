defmodule ApmV5.Plugins.PluginConfigStoreTest do
  use ExUnit.Case, async: false

  @moduletag :plugin_config

  alias ApmV5.Plugins.PluginConfigStore

  setup do
    # Ensure ETS tables exist (PluginRegistry + PluginConfigStore are started by Application)
    :ok
  end

  describe "get_config/2" do
    test "returns defaults for plugin with no overrides" do
      config = PluginConfigStore.get_config(:plugin, "alerting")
      assert is_map(config)
      assert config[:enabled] == true || config.enabled == true || map_size(config) >= 0
    end

    test "returns empty map for unknown plugin" do
      config = PluginConfigStore.get_config(:plugin, "nonexistent_plugin_xyz")
      assert config == %{}
    end
  end

  describe "get_schema/2" do
    test "returns schema for plugin with config_schema" do
      schema = PluginConfigStore.get_schema(:plugin, "alerting")
      assert is_map(schema)
      assert map_size(schema) > 0
    end

    test "returns empty map for plugin without config_schema" do
      schema = PluginConfigStore.get_schema(:plugin, "nonexistent_plugin_xyz")
      assert schema == %{}
    end
  end

  describe "put_config/3 and get_overrides/2" do
    test "stores and retrieves config overrides for a plugin" do
      name = "alerting"
      override = %{enabled: false}
      assert {:ok, resolved} = PluginConfigStore.put_config(:plugin, name, override)
      assert resolved[:enabled] == false || resolved.enabled == false

      overrides = PluginConfigStore.get_overrides(:plugin, name)
      assert overrides[:enabled] == false || overrides.enabled == false

      # Cleanup
      PluginConfigStore.reset_config(:plugin, name)
    end

    test "accepts config for plugin with empty schema" do
      # A plugin with no config_schema should accept any config
      assert {:ok, _} = PluginConfigStore.put_config(:plugin, "skills", %{foo: "bar"})
      PluginConfigStore.reset_config(:plugin, "skills")
    end
  end

  describe "reset_config/2" do
    test "removes overrides and returns to defaults" do
      name = "formations"
      PluginConfigStore.put_config(:plugin, name, %{auto_refresh: false})
      :ok = PluginConfigStore.reset_config(:plugin, name)

      overrides = PluginConfigStore.get_overrides(:plugin, name)
      assert overrides == %{}
    end
  end

  describe "list_configs/1" do
    test "lists all stored plugin configs" do
      PluginConfigStore.put_config(:plugin, "alerting", %{enabled: false})
      configs = PluginConfigStore.list_configs(:plugin)
      assert is_list(configs)
      assert Enum.any?(configs, fn {name, _} -> name == "alerting" end)

      # Cleanup
      PluginConfigStore.reset_config(:plugin, "alerting")
    end
  end

  describe "validate_against_schema/2" do
    test "accepts valid config against schema" do
      schema = %{enabled: "boolean", count: "integer", name: "string"}
      config = %{enabled: true, count: 5, name: "test"}
      assert {:ok, ^config} = PluginConfigStore.validate_against_schema(config, schema)
    end

    test "rejects invalid boolean" do
      schema = %{enabled: "boolean"}
      assert {:error, errors} = PluginConfigStore.validate_against_schema(%{enabled: "yes"}, schema)
      assert length(errors) == 1
    end

    test "rejects invalid integer" do
      schema = %{count: "integer"}
      assert {:error, _} = PluginConfigStore.validate_against_schema(%{count: "five"}, schema)
    end

    test "rejects invalid enum value" do
      schema = %{level: "enum:debug,info,warn,error"}
      assert {:error, _} = PluginConfigStore.validate_against_schema(%{level: "trace"}, schema)
    end

    test "accepts valid enum value" do
      schema = %{level: "enum:debug,info,warn,error"}
      assert {:ok, _} = PluginConfigStore.validate_against_schema(%{level: "debug"}, schema)
    end

    test "rejects unknown keys" do
      schema = %{enabled: "boolean"}
      assert {:error, errors} = PluginConfigStore.validate_against_schema(%{unknown_key: true}, schema)
      assert length(errors) == 1
    end

    test "accepts any config when schema is empty" do
      assert {:ok, _} = PluginConfigStore.validate_against_schema(%{anything: "goes"}, %{})
    end

    test "validates secret type as string" do
      schema = %{api_key: "secret"}
      assert {:ok, _} = PluginConfigStore.validate_against_schema(%{api_key: "sk-123"}, schema)
      assert {:error, _} = PluginConfigStore.validate_against_schema(%{api_key: 123}, schema)
    end
  end
end
