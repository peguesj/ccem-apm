defmodule ApmV5.AgentIdentity do
  @moduledoc """
  Canonical agent identity schema for CCEM APM.

  ## Protocol alignment

  This module aligns with three complementary standards:

  1. **OpenTelemetry GenAI Semantic Conventions** (semconv 1.40.0, `gen_ai.agent.*`)
     — provides `agent_id`, `agent_name`, `agent_description`, `agent_version`.
     Source: https://opentelemetry.io/docs/specs/semconv/gen-ai/gen-ai-agent-spans/

  2. **AG-UI Protocol** (ag-ui-protocol/ag-ui, March 2026)
     — `run_id` / `thread_id` map to CCEM's `formation_id` / `session_id` for
     event-stream lineage tracing via RUN_STARTED / RUN_FINISHED events.

  3. **FIPA Agent Identifier** (`name@platform`) pattern
     — informs the structured semantic ID format: `{role}.{scope}.{seq}` which
     replaces raw hash suffixes and carries provenance in the ID itself.

  ## Semantic ID format

  ```
  {role_slug}.{scope}.{seq}
  ```

  Examples:
  - `orchestrator.fmt-20260330.001`
  - `squadron-lead.alpha.fmt-20260330.002`
  - `swarm-agent.foundation.alpha.fmt-20260330.003`
  - `persistent-service.plane-pm-align.singleton`
  - `individual.ccem.a4fdb530`   ← legacy fallback: keeps last 8 chars of raw ID

  The `scope` encodes context:
  - For formation members: `{squadron}.{formation_id_short}`
  - For persistent services: `{service_slug}.singleton`
  - For legacy/unknown: `{project_slug}.{short_hash}`

  ## Provenance fields (CCEM extensions)

  Beyond OTel, CCEM adds:
  - `invoked_by`      — agent_id or skill name that spawned this agent
  - `definition_path` — path to the skill/agent definition file
  - `formation_scope` — `{formation_id}/{squadron}/{swarm}/{cluster}` breadcrumb
  - `authorization`   — AgentLock policy hint (risk_level, trust_level)
  - `upm_context`     — UPM story/wave linkage
  """

  @type role() ::
    :orchestrator
    | :squadron_lead
    | :swarm_agent
    | :cluster_agent
    | :individual
    | :persistent_service
    | :quality_agent
    | :unknown

  @type t() :: %__MODULE__{
    # OTel gen_ai.agent.* fields
    agent_id:          String.t(),
    agent_name:        String.t(),
    agent_description: String.t() | nil,
    agent_version:     String.t() | nil,

    # CCEM role + hierarchy
    role:              String.t(),
    agent_type:        String.t(),
    display_name:      String.t(),
    formation_id:      String.t() | nil,
    squadron:          String.t() | nil,
    swarm:             String.t() | nil,
    cluster:           String.t() | nil,
    wave:              integer() | nil,
    formation_scope:   String.t() | nil,

    # Provenance
    invoked_by:        String.t() | nil,
    parent_agent_id:   String.t() | nil,
    definition_path:   String.t() | nil,
    session_id:        String.t() | nil,
    project:           String.t() | nil,

    # UPM
    story_id:          String.t() | nil,
    plane_issue_id:    String.t() | nil,
    work_item_title:   String.t() | nil,
    upm_session_id:    String.t() | nil,
    upm_context:       map(),

    # AgentLock
    authorization:     map()
  }

  defstruct [
    :agent_id,
    :agent_name,
    :agent_description,
    :agent_version,
    :role,
    :agent_type,
    :display_name,
    :formation_id,
    :squadron,
    :swarm,
    :cluster,
    :wave,
    :formation_scope,
    :invoked_by,
    :parent_agent_id,
    :definition_path,
    :session_id,
    :project,
    :story_id,
    :plane_issue_id,
    :work_item_title,
    :upm_session_id,
    upm_context: %{},
    authorization: %{}
  ]

  @doc """
  Builds a normalized `%AgentIdentity{}` from a raw registration params map.

  Accepts both atom and string keys. The `agent_id` field in the result is
  always the caller-supplied ID (backward compat). The `agent_name` field is
  resolved via the following priority:

    1. Explicit `agent_name` param
    2. Explicit `name` param
    3. Synthesized semantic name from role + formation

  The `display_name` is always a human-readable string suitable for UI labels
  (never a raw hash).
  """
  @spec build(String.t(), map()) :: t()
  def build(agent_id, params) when is_binary(agent_id) do
    p = normalize_keys(params)

    role       = get_p(p, "role") || get_p(p, "formation_role") || "individual"
    agent_type = normalize_agent_type(get_p(p, "agent_type") || role)
    formation_id = get_p(p, "formation_id")
    squadron   = get_p(p, "squadron")
    swarm      = get_p(p, "swarm")
    cluster    = get_p(p, "cluster")
    wave       = parse_int(get_p(p, "wave") || get_p(p, "wave_number"))
    project    = get_p(p, "project_name") || get_p(p, "project")

    # OTel gen_ai.agent.name — explicit > synthesized > fallback to id
    explicit_name = get_p(p, "agent_name") || get_p(p, "name")
    agent_name =
      if meaningful?(explicit_name, agent_id),
        do: explicit_name,
        else: synthesize_name(agent_type, formation_id, squadron, wave, agent_id)

    agent_description = get_p(p, "agent_description") || get_p(p, "agent_definition") || get_p(p, "role")
    agent_version     = get_p(p, "agent_version")

    invoked_by      = get_p(p, "invoked_by") || get_p(p, "parent_agent_id")
    parent_agent_id = get_p(p, "parent_agent_id") || get_p(p, "parent_id")
    definition_path = get_p(p, "definition_path") || get_p(p, "path")
    session_id      = get_p(p, "session_id")

    formation_scope = build_formation_scope(formation_id, squadron, swarm, cluster)

    display_name = build_display_name(agent_name, agent_type, formation_id, squadron, project)

    upm_ctx = %{}
    |> maybe_add("story_id",       get_p(p, "story_id"))
    |> maybe_add("plane_issue_id", get_p(p, "plane_issue_id"))
    |> maybe_add("work_item",      get_p(p, "work_item_title"))
    |> maybe_add("upm_session_id", get_p(p, "upm_session_id"))
    |> maybe_add("wave",           wave)

    auth_ctx = %{}
    |> maybe_add("risk_level",   get_p(p, "risk_level"))
    |> maybe_add("trust_level",  get_p(p, "trust_level"))

    %__MODULE__{
      agent_id:          agent_id,
      agent_name:        agent_name,
      agent_description: agent_description,
      agent_version:     agent_version,
      role:              role,
      agent_type:        agent_type,
      display_name:      display_name,
      formation_id:      formation_id,
      squadron:          squadron,
      swarm:             swarm,
      cluster:           cluster,
      wave:              wave,
      formation_scope:   formation_scope,
      invoked_by:        invoked_by,
      parent_agent_id:   parent_agent_id,
      definition_path:   definition_path,
      session_id:        session_id,
      project:           project,
      story_id:          get_p(p, "story_id"),
      plane_issue_id:    get_p(p, "plane_issue_id"),
      work_item_title:   get_p(p, "work_item_title"),
      upm_session_id:    get_p(p, "upm_session_id"),
      upm_context:       upm_ctx,
      authorization:     auth_ctx
    }
  end

  @doc """
  Converts an `%AgentIdentity{}` to a plain map suitable for ETS storage and
  JSON serialization. Keys are atoms for consistency with existing AgentRegistry
  map patterns.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = id) do
    %{
      # OTel gen_ai.agent.*
      agent_id:          id.agent_id,
      agent_name:        id.agent_name,
      agent_description: id.agent_description,
      agent_version:     id.agent_version,
      # display / naming
      display_name:      id.display_name,
      name:              id.agent_name,
      # role / hierarchy
      role:              id.role,
      agent_type:        id.agent_type,
      formation_id:      id.formation_id,
      squadron:          id.squadron,
      swarm:             id.swarm,
      cluster:           id.cluster,
      wave:              id.wave,
      wave_number:       id.wave,
      formation_scope:   id.formation_scope,
      # provenance
      invoked_by:        id.invoked_by,
      parent_id:         id.parent_agent_id,
      parent_agent_id:   id.parent_agent_id,
      definition_path:   id.definition_path,
      agent_definition:  id.agent_description,
      path:              id.definition_path,
      session_id:        id.session_id,
      project:           id.project,
      project_name:      id.project,
      # UPM
      story_id:          id.story_id,
      plane_issue_id:    id.plane_issue_id,
      work_item_title:   id.work_item_title,
      upm_session_id:    id.upm_session_id,
      upm_context:       id.upm_context,
      # AgentLock
      authorization:     id.authorization
    }
  end

  # ── Private helpers ──────────────────────────────────────────────────────────

  @valid_agent_types ~w(orchestrator squadron_lead swarm_agent cluster_agent
                        individual persistent_service quality_agent unknown)

  defp normalize_agent_type(type) when is_binary(type) do
    cand = String.replace(type, "-", "_")
    if cand in @valid_agent_types, do: cand, else: "unknown"
  end
  defp normalize_agent_type(type) when is_atom(type), do: normalize_agent_type(to_string(type))
  defp normalize_agent_type(_), do: "unknown"

  # Returns true when name is set, non-empty, and not just the raw agent_id
  defp meaningful?(nil, _id), do: false
  defp meaningful?("", _id), do: false
  defp meaningful?(name, id), do: name != id

  # Synthesizes a human-readable name from structural context
  defp synthesize_name(agent_type, formation_id, squadron, wave, agent_id) do
    type_slug = agent_type |> String.replace("_", "-")
    scope = cond do
      squadron && formation_id ->
        short_formation = formation_id |> String.split("-") |> Enum.take(3) |> Enum.join("-")
        "#{squadron}.#{short_formation}"
      formation_id ->
        formation_id |> String.split("-") |> Enum.take(3) |> Enum.join("-")
      true ->
        String.slice(agent_id, -8, 8)
    end

    wave_part = if wave, do: ".w#{wave}", else: ""
    "#{type_slug}.#{scope}#{wave_part}"
  end

  # Builds a human-readable display name for UI labels — never a raw hash
  defp build_display_name(agent_name, agent_type, formation_id, squadron, project) do
    type_label = agent_type |> String.replace("_", " ") |> String.split() |> Enum.map(&String.capitalize/1) |> Enum.join(" ")

    cond do
      agent_name && agent_name != "" ->
        agent_name

      squadron && formation_id ->
        short_fmt = formation_id |> String.split("-") |> Enum.drop(1) |> Enum.take(2) |> Enum.join("-")
        "#{type_label} · #{squadron} / #{short_fmt}"

      formation_id ->
        short_fmt = formation_id |> String.split("-") |> Enum.drop(1) |> Enum.take(2) |> Enum.join("-")
        "#{type_label} · #{short_fmt}"

      project ->
        "#{type_label} · #{project}"

      true ->
        type_label
    end
  end

  defp build_formation_scope(nil, _sq, _sw, _cl), do: nil
  defp build_formation_scope(fmt_id, squadron, swarm, cluster) do
    [fmt_id, squadron, swarm, cluster]
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("/")
  end

  defp parse_int(nil), do: nil
  defp parse_int(v) when is_integer(v), do: v
  defp parse_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> nil
    end
  end
  defp parse_int(_), do: nil

  defp get_p(map, key), do: Map.get(map, key)

  defp normalize_keys(params) when is_map(params) do
    Map.new(params, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp maybe_add(map, _key, nil), do: map
  defp maybe_add(map, key, value), do: Map.put(map, key, value)
end
