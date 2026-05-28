defmodule ApmV5.AgUi.A2A.AgentSkill do
  @moduledoc """
  A2A v0.3.0 AgentSkill — a single capability declaration within an AgentCard.

  Spec field reference:
    - `id`           — unique skill identifier (e.g., "agent-register")
    - `name`         — human-readable skill name
    - `description`  — what the skill does
    - `inputModes`   — accepted media types (default: ["text/plain"])
    - `outputModes`  — produced media types (default: ["application/json"])
    - `tags`         — discoverability tags (e.g., ["lifecycle", "agentlock"])
    - `examples`     — example invocations or endpoint paths

  Story `coord-a1` from v9.2.1 hotfix sprint.
  """

  @type t() :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          description: String.t(),
          inputModes: [String.t()],
          outputModes: [String.t()],
          tags: [String.t()],
          examples: [String.t()]
        }

  @derive Jason.Encoder
  defstruct id: "",
            name: "",
            description: "",
            inputModes: ["text/plain"],
            outputModes: ["application/json"],
            tags: [],
            examples: []

  @doc "Constructs a new AgentSkill from keyword args."
  @spec new(keyword()) :: t()
  def new(attrs) do
    struct!(__MODULE__, attrs)
  end

  @doc """
  Builds an AgentSkill from a raw map (atom or string keys).
  Used when AgentIdentity.skills contains map literals.
  """
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{
      id: fetch(map, :id, ""),
      name: fetch(map, :name, ""),
      description: fetch(map, :description, ""),
      inputModes: fetch(map, :inputModes, ["text/plain"]) |> List.wrap(),
      outputModes: fetch(map, :outputModes, ["application/json"]) |> List.wrap(),
      tags: fetch(map, :tags, []) |> List.wrap(),
      examples: fetch(map, :examples, []) |> List.wrap()
    }
  end

  defp fetch(map, key, default) do
    Map.get(map, key) || Map.get(map, to_string(key)) || default
  end
end
