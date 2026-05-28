defmodule ApmV5.Test.EtsFixtures do
  @moduledoc """
  ETS-backed fixture helpers for contract tests (api-s6p / CP-266).

  Provides seed helpers that call into live GenServers to insert test data
  so contract tests can exercise actions requiring pre-existing state
  (agents, sessions, approval gates).

  ## Usage

      setup do
        ApmV5.Test.EtsFixtures.reset()
        :ok
      end

      test "GET /api/v2/agents/:id", %{conn: conn} do
        %{id: agent_id} = ApmV5.Test.EtsFixtures.seed_agent()
        conn = get(conn, "/api/v2/agents/\#{agent_id}")
        assert conn.status == 200
      end

  ## Design notes

  All helpers are synchronous (GenServer.call under the hood via the
  public registry APIs) and return the seeded data map so callers can
  reference the generated IDs directly.
  """

  alias ApmV5.AgentRegistry
  alias ApmV5.AgUi.ApprovalGate

  @doc """
  Seeds a single agent into AgentRegistry ETS.

  Accepts an optional `overrides` map merged over the default fixture
  attrs. Returns the stored agent map including the generated `id`.

  ## Examples

      iex> %{id: id} = ApmV5.Test.EtsFixtures.seed_agent()
      iex> is_binary(id)
      true

      iex> %{id: id} = ApmV5.Test.EtsFixtures.seed_agent(%{status: "active"})
      iex> ApmV5.AgentRegistry.get_agent(id).status
      "active"
  """
  @spec seed_agent(map()) :: map()
  def seed_agent(overrides \\ %{}) do
    agent_id = "fixture-agent-#{unique_id()}"

    attrs =
      %{
        status: "active",
        role: "test",
        project_name: "fixture-project",
        tier: 1,
        wave: 1,
        task_subject: "Contract test fixture"
      }
      |> Map.merge(overrides)

    :ok = AgentRegistry.register_agent(agent_id, attrs)

    # Return the stored agent map so callers have the full normalised shape
    AgentRegistry.get_agent(agent_id)
  end

  @doc """
  Seeds a single session into AgentRegistry ETS.

  Returns the session map with the generated `session_id`.
  """
  @spec seed_session(map()) :: map()
  def seed_session(overrides \\ %{}) do
    session_id = "fixture-session-#{unique_id()}"

    attrs =
      %{
        session_id: session_id,
        project: "fixture-project",
        status: "active"
      }
      |> Map.merge(overrides)

    :ok = AgentRegistry.register_session(attrs)

    # Return normalised session map
    AgentRegistry.get_session(session_id) ||
      Map.put(attrs, :session_id, session_id)
  end

  @doc """
  Seeds a pending approval gate via ApprovalGate.request_approval/2.

  Returns a map with at least `:gate_id` and `:agent_id`.
  """
  @spec seed_pending_approval(map()) :: map()
  def seed_pending_approval(overrides \\ %{}) do
    agent_id = Map.get(overrides, :agent_id, "fixture-approval-agent-#{unique_id()}")

    params =
      %{
        "agent_id" => agent_id,
        "tool_name" => "Bash",
        "tool_input" => %{"command" => "echo fixture"},
        "session_id" => "fixture-session-#{unique_id()}"
      }
      |> Map.merge(string_keys(overrides))

    {:ok, gate_id} = ApprovalGate.request_approval(agent_id, params)

    %{gate_id: gate_id, agent_id: agent_id, params: params}
  end

  @doc """
  Resets all ETS state: clears agents, sessions, notifications and all
  approval gates. Call in a `setup` block to ensure test isolation.
  """
  @spec reset() :: :ok
  def reset do
    # Clear AgentRegistry ETS tables via public GenServer API
    if pid = Process.whereis(AgentRegistry) do
      if Process.alive?(pid), do: AgentRegistry.clear_all()
    end

    # Clear ApprovalGate ETS table directly (reject leaves records, delete_all removes them)
    if :ets.whereis(:ag_ui_approval_gates) != :undefined do
      :ets.delete_all_objects(:ag_ui_approval_gates)
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp unique_id do
    System.unique_integer([:positive, :monotonic])
    |> Integer.to_string()
    |> String.pad_leading(6, "0")
  end

  defp string_keys(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
end
