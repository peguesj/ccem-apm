defmodule ApmV5.Plugins.SkillPluginBridgeTest do
  use ExUnit.Case, async: true

  alias ApmV5.Plugins.SkillPluginBridge

  defmodule FakePlugin do
    use ApmV5.Plugins.SkillPluginBridge

    @impl ApmV5.Plugins.SkillPluginBridge
    def skill_name, do: "fake-skill"

    @impl ApmV5.Plugins.SkillPluginBridge
    def skill_path, do: "/tmp/fake-skill/SKILL.md"

    @impl ApmV5.Plugins.SkillPluginBridge
    def skill_commands, do: ["plan", "build", "verify"]

    @impl ApmV5.Plugins.SkillPluginBridge
    def dispatch_skill_command("plan", params), do: {:ok, %{dispatched: :plan, params: params}}
    def dispatch_skill_command(cmd, _params), do: {:error, {:unknown_command, cmd}}

    @impl ApmV5.Plugins.PluginBehaviour
    def plugin_name, do: "fake_plugin"

    @impl ApmV5.Plugins.PluginBehaviour
    def plugin_description, do: "Fake skill plugin for tests"

    @impl ApmV5.Plugins.PluginBehaviour
    def plugin_version, do: "0.0.1"

    @impl ApmV5.Plugins.PluginBehaviour
    def list_endpoints, do: []

    @impl ApmV5.Plugins.PluginBehaviour
    def handle_action(_action, _params, _opts), do: {:error, :not_implemented}
  end

  describe "use SkillPluginBridge macro" do
    test "auto-implements plugin_scope/0 as :ccem" do
      assert FakePlugin.plugin_scope() == :ccem
    end

    test "auto-implements default_enabled?/0 as true" do
      assert FakePlugin.default_enabled?() == true
    end

    test "auto-implements nav_items/0 derived from skill_commands/0" do
      nav = FakePlugin.nav_items()
      assert length(nav) == 3
      assert {"Plan", "/plugins/fake_plugin/plan", nil} in nav
      assert {"Build", "/plugins/fake_plugin/build", nil} in nav
      assert {"Verify", "/plugins/fake_plugin/verify", nil} in nav
    end
  end

  describe "dispatch_skill_command/3" do
    test "delegates to plugin module's dispatch_skill_command/2" do
      assert {:ok, %{dispatched: :plan}} =
               SkillPluginBridge.dispatch_skill_command(FakePlugin, "plan", %{foo: "bar"})
    end

    test "returns {:error, :not_implemented} when plugin doesn't export callback" do
      defmodule NoDispatch do
        def plugin_name, do: "x"
      end

      assert {:error, :not_implemented} =
               SkillPluginBridge.dispatch_skill_command(NoDispatch, "anything", %{})
    end
  end

  describe "dispatch_async/3" do
    test "returns :ok immediately and runs the task" do
      assert :ok = SkillPluginBridge.dispatch_async(FakePlugin, "plan", %{key: "val"})
    end
  end
end
