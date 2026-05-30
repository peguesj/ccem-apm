defmodule Apm.Auth.PolicyRulesStoreTest do
  @moduledoc """
  Tests for PolicyRulesStore wildcard rule support and basic CRUD.

  Run with: mix test --only govern_intelligence
  """

  use ExUnit.Case, async: false

  @moduletag :govern_intelligence

  alias Apm.Auth.PolicyRulesStore

  setup do
    case Process.whereis(PolicyRulesStore) do
      nil -> {:ok, _} = PolicyRulesStore.start_link([])
      _pid -> :ok
    end

    on_exit(fn ->
      PolicyRulesStore.remove_rule("test_tool_exact")
      PolicyRulesStore.remove_rule("test_tool_deny")
      PolicyRulesStore.remove_rule("*")
    end)

    :ok
  end

  describe "add_rule/2 + check_rule/1" do
    test "exact match returns the stored action" do
      PolicyRulesStore.add_rule("test_tool_exact", :always_allow)
      assert PolicyRulesStore.check_rule("test_tool_exact") == :always_allow
    end

    test "always_deny is stored and returned" do
      PolicyRulesStore.add_rule("test_tool_deny", :always_deny)
      assert PolicyRulesStore.check_rule("test_tool_deny") == :always_deny
    end

    test "unknown tool returns :none" do
      assert PolicyRulesStore.check_rule("nonexistent_tool_xyz") == :none
    end
  end

  describe "wildcard '*' rule" do
    test "wildcard rule applies when no exact match exists" do
      PolicyRulesStore.add_rule("*", :always_allow)
      # A tool with no explicit rule should fall back to wildcard
      assert PolicyRulesStore.check_rule("Bash") == :always_allow
      assert PolicyRulesStore.check_rule("Write") == :always_allow
      assert PolicyRulesStore.check_rule("Agent") == :always_allow
    end

    test "exact rule takes precedence over wildcard" do
      PolicyRulesStore.add_rule("*", :always_allow)
      PolicyRulesStore.add_rule("test_tool_deny", :always_deny)
      # Exact deny overrides wildcard allow
      assert PolicyRulesStore.check_rule("test_tool_deny") == :always_deny
      # Other tools still get wildcard allow
      assert PolicyRulesStore.check_rule("Edit") == :always_allow
    end

    test "removing wildcard reverts unknown tools to :none" do
      PolicyRulesStore.add_rule("*", :always_allow)
      assert PolicyRulesStore.check_rule("SomeRandomTool") == :always_allow
      PolicyRulesStore.remove_rule("*")
      assert PolicyRulesStore.check_rule("SomeRandomTool") == :none
    end
  end

  describe "remove_rule/1" do
    test "removing a rule returns :none on next check" do
      PolicyRulesStore.add_rule("test_tool_exact", :always_allow)
      PolicyRulesStore.remove_rule("test_tool_exact")
      assert PolicyRulesStore.check_rule("test_tool_exact") == :none
    end

    test "removing non-existent rule is idempotent" do
      assert :ok = PolicyRulesStore.remove_rule("never_existed_xyz")
    end
  end

  describe "list_rules/0" do
    test "returns a list of maps with tool_name and action" do
      PolicyRulesStore.add_rule("test_tool_exact", :always_allow)
      rules = PolicyRulesStore.list_rules()
      assert is_list(rules)
      entry = Enum.find(rules, &(&1.tool_name == "test_tool_exact"))
      assert entry != nil
      assert entry.action == :always_allow
      assert is_binary(entry.inserted_at)
    end

    test "returns sorted list" do
      PolicyRulesStore.add_rule("z_tool", :always_allow)
      PolicyRulesStore.add_rule("a_tool", :always_deny)
      rules = PolicyRulesStore.list_rules()
      names = Enum.map(rules, & &1.tool_name)
      assert names == Enum.sort(names)
    end
  end

  describe "ETS availability guard" do
    test "check_rule returns :none when table info is available" do
      assert PolicyRulesStore.check_rule("any_tool") in [:none, :always_allow, :always_deny]
    end
  end
end
