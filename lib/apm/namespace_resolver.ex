defmodule Apm.NamespaceResolver do
  @moduledoc """
  Converts raw IDs (agent_id, session_id, formation_id, request_id) into
  human-readable scoped labels suitable for display in LiveViews and notifications.

  Label formats:
    agent:   {project}/{role-slug}/{task-slug}    e.g. "ccem/wave-1/stripe-env"
    session: {project}/{branch-short}             e.g. "ccem/main-dev"
    gate:    {tool-slug}:{HHMM}                   e.g. "bash:write/1432"

  ETS table :namespace_cache stores computed labels for fast repeated lookup.
  Falls back to a shortened version of the raw ID when insufficient context.
  """
  use GenServer
  require Logger

  @table :namespace_cache

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Returns human-readable label for an agent_id. Accepts opts: [project:, role:, task_subject:]"
  @spec agent_label(String.t(), keyword()) :: String.t()
  def agent_label(agent_id, opts \\ []) do
    cache_key = {:agent, agent_id}
    case cached(cache_key) do
      nil ->
        label = compute_agent_label(agent_id, opts)
        put_cache(cache_key, label)
        label
      label -> label
    end
  end

  @doc "Returns human-readable label for a session_id. Accepts opts: [project:, branch:]"
  @spec session_label(String.t(), keyword()) :: String.t()
  def session_label(session_id, opts \\ []) do
    cache_key = {:session, session_id}
    case cached(cache_key) do
      nil ->
        label = compute_session_label(session_id, opts)
        put_cache(cache_key, label)
        label
      label -> label
    end
  end

  @doc "Returns human-readable label for a gate/pending request_id."
  @spec gate_label(String.t(), String.t()) :: String.t()
  def gate_label(request_id, tool_name) do
    cache_key = {:gate, request_id}
    case cached(cache_key) do
      nil ->
        label = compute_gate_label(request_id, tool_name)
        put_cache(cache_key, label)
        label
      label -> label
    end
  end

  @doc "Invalidates a cached label (call when entity is updated)."
  @spec invalidate(atom(), String.t()) :: :ok
  def invalidate(type, id) when type in [:agent, :session, :gate] do
    :ets.delete(@table, {type, id})
    :ok
  end

  # GenServer

  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{}}
  end

  # Private

  defp compute_agent_label(agent_id, opts) do
    # Priority 1: display_name or agent_name from AgentRegistry (set by AgentIdentity.build/2)
    registry_name = lookup_agent_name(agent_id)
    if registry_name && registry_name != "" && registry_name != agent_id do
      registry_name
    else
      # Priority 2: synthesize from role + formation context
      # Prefer formation_scope breadcrumb over raw project/task parts
      role = opts[:role] |> format_role()
      task = opts[:task_subject] |> task_slug()

      formation_scope =
        case opts[:formation_id] do
          nil -> nil
          fmt_id ->
            parts = [fmt_id, opts[:squadron]] |> Enum.reject(&is_nil/1)
            Enum.join(parts, "/")
        end

      project = opts[:project] || extract_project_from_id(agent_id)

      parts =
        [project, formation_scope || role, task]
        |> Enum.reject(&is_nil/1)
        |> Enum.reject(&(&1 == ""))

      case parts do
        # Priority 3: never return raw hash — use role slug + last 8 chars
        [] ->
          role_fallback = format_role(opts[:role]) || "agent"
          "#{role_fallback}.#{String.slice(agent_id, -8, 8)}"
        _ ->
          Enum.join(parts, "/")
      end
    end
  end

  # Looks up display_name (preferred) or agent_name from AgentRegistry.
  # display_name is always human-readable (set by AgentIdentity.build/2);
  # agent_name is the OTel gen_ai.agent.name field.
  # Never returns a raw hash-based agent_id.
  defp lookup_agent_name(agent_id) do
    if Process.whereis(Apm.AgentRegistry) do
      case Apm.AgentRegistry.get_agent(agent_id) do
        %{display_name: dn} when is_binary(dn) and dn != "" and dn != agent_id -> dn
        %{agent_name: name} when is_binary(name) and name != "" and name != agent_id -> name
        _ -> nil
      end
    end
  rescue
    _ -> nil
  end

  defp compute_session_label(session_id, opts) do
    project = opts[:project] || "unknown"
    branch = opts[:branch] |> branch_short()

    parts = [project, branch] |> Enum.reject(&is_nil/1) |> Enum.reject(&(&1 == ""))
    case parts do
      [] -> short_id(session_id)
      _ -> Enum.join(parts, "/")
    end
  end

  defp compute_gate_label(request_id, tool_name) do
    time_part = extract_time_from_id(request_id)
    tool_slug =
      tool_name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]/, "-")
      |> String.slice(0, 12)
    "#{tool_slug}/#{time_part}"
  end

  defp extract_project_from_id(id) do
    # Formation IDs like "fmt-agentlock-notif-20260328-001-alpha-b1-001"
    # Extract meaningful prefix; fallback to nil
    cond do
      String.contains?(id, "ccem") -> "ccem"
      String.contains?(id, "lcc") -> "lcc"
      String.contains?(id, "viki") -> "viki"
      String.contains?(id, "fmt-") ->
        id |> String.split("-") |> Enum.drop(1) |> Enum.take(2) |> Enum.join("-")
      true -> nil
    end
  end

  defp format_role(nil), do: nil
  defp format_role(role) when is_atom(role), do: role |> Atom.to_string() |> format_role()
  defp format_role(role) do
    role
    |> String.replace("_", "-")
    |> String.replace("squadron_lead", "sq-lead")
    |> String.replace("swarm_agent", "swarm")
    |> String.replace("cluster_agent", "cluster")
    |> String.replace("individual", "agent")
    |> String.slice(0, 10)
  end

  defp task_slug(nil), do: nil
  defp task_slug(subject) do
    subject
    |> String.downcase()
    |> String.replace(~r/^us-\d+:\s*/, "")
    |> String.split(~r/[\s\-_:,]+/)
    |> Enum.reject(&(String.length(&1) < 3))
    |> Enum.reject(&(&1 in ~w(the and for with from that this)))
    |> Enum.take(3)
    |> Enum.join("-")
    |> String.slice(0, 20)
  end

  defp branch_short(nil), do: nil
  defp branch_short(branch) do
    branch
    |> String.replace(~r/^(main|master|ralph|feat|fix|chore)\//, "")
    |> String.split("-")
    |> Enum.take(3)
    |> Enum.join("-")
    |> String.slice(0, 20)
  end

  defp extract_time_from_id(_id) do
    # Extract current time as HHMM fallback
    now = Time.utc_now()
    "#{String.pad_leading("#{now.hour}", 2, "0")}#{String.pad_leading("#{now.minute}", 2, "0")}"
  end

  defp short_id(id), do: id |> String.slice(-8, 8)

  defp cached(key) do
    :ets.lookup(@table, key)
    |> case do
      [{^key, value}] -> value
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp put_cache(key, value) do
    :ets.insert(@table, {key, value})
  rescue
    ArgumentError -> :ok
  end
end
