defmodule ApmV5.AgUi.A2A.Envelope do
  @moduledoc """
  A2A message envelope with structured addressing.

  ## US-030 Acceptance Criteria (DoD):
  - Struct with id, from_agent_id, to, message_type, payload, correlation_id, timestamp, ttl_ms
  - Address types: {:agent, id}, {:formation, id}, {:squadron, id}, {:topic, str}, :broadcast
  - Envelope validation
  - mix compile --warnings-as-errors passes
  """

  @enforce_keys [:from_agent_id, :to, :message_type, :payload]
  defstruct [
    :id,
    :from_agent_id,
    :to,
    :message_type,
    :payload,
    :correlation_id,
    :timestamp,
    :ttl_ms
  ]

  @type address ::
          {:agent, String.t()}
          | {:formation, String.t()}
          | {:squadron, String.t()}
          | {:topic, String.t()}
          | :broadcast

  @type t :: %__MODULE__{
          id: String.t(),
          from_agent_id: String.t(),
          to: address(),
          message_type: String.t(),
          payload: map(),
          correlation_id: String.t() | nil,
          timestamp: String.t(),
          ttl_ms: non_neg_integer()
        }

  @doc "Creates a new envelope with auto-generated ID and timestamp."
  @spec new(map()) :: {:ok, t()} | {:error, String.t()}
  def new(attrs) when is_map(attrs) do
    from = attrs[:from_agent_id] || attrs["from_agent_id"]
    to = parse_address(attrs[:to] || attrs["to"])
    msg_type = attrs[:message_type] || attrs["message_type"] || "generic"
    payload = attrs[:payload] || attrs["payload"] || %{}

    cond do
      is_nil(from) -> {:error, "from_agent_id is required"}
      is_nil(to) -> {:error, "invalid address"}
      true ->
        {:ok,
         %__MODULE__{
           id: ApmV5.Correlation.generate(),
           from_agent_id: from,
           to: to,
           message_type: msg_type,
           payload: payload,
           correlation_id: attrs[:correlation_id] || attrs["correlation_id"],
           timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
           ttl_ms: attrs[:ttl_ms] || attrs["ttl_ms"] || 60_000
         }}
    end
  end

  @doc "Validates an envelope."
  @spec valid?(t()) :: boolean()
  def valid?(%__MODULE__{from_agent_id: from, to: to}) do
    not is_nil(from) and valid_address?(to)
  end

  def valid?(_), do: false

  @doc "Checks if a message has expired based on TTL."
  @spec expired?(t()) :: boolean()
  def expired?(%__MODULE__{timestamp: ts, ttl_ms: ttl}) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} ->
        age_ms = DateTime.diff(DateTime.utc_now(), dt, :millisecond)
        age_ms > ttl

      _ ->
        true
    end
  end

  @doc "Serializes envelope to a JSON-friendly map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = env) do
    %{
      id: env.id,
      from_agent_id: env.from_agent_id,
      to: serialize_address(env.to),
      message_type: env.message_type,
      payload: env.payload,
      correlation_id: env.correlation_id,
      timestamp: env.timestamp,
      ttl_ms: env.ttl_ms
    }
  end

  # -- Private ----------------------------------------------------------------

  defp parse_address({:agent, id}) when is_binary(id), do: {:agent, id}
  defp parse_address({:formation, id}) when is_binary(id), do: {:formation, id}
  defp parse_address({:squadron, id}) when is_binary(id), do: {:squadron, id}
  defp parse_address({:topic, t}) when is_binary(t), do: {:topic, t}
  defp parse_address(:broadcast), do: :broadcast
  defp parse_address("broadcast"), do: :broadcast

  defp parse_address(%{"type" => "agent", "id" => id}), do: {:agent, id}
  defp parse_address(%{"type" => "formation", "id" => id}), do: {:formation, id}
  defp parse_address(%{"type" => "squadron", "id" => id}), do: {:squadron, id}
  defp parse_address(%{"type" => "topic", "id" => id}), do: {:topic, id}
  defp parse_address(%{"type" => "broadcast"}), do: :broadcast
  defp parse_address(_), do: nil

  defp valid_address?({:agent, _}), do: true
  defp valid_address?({:formation, _}), do: true
  defp valid_address?({:squadron, _}), do: true
  defp valid_address?({:topic, _}), do: true
  defp valid_address?(:broadcast), do: true
  defp valid_address?(_), do: false

  defp serialize_address({type, id}), do: %{type: to_string(type), id: id}
  defp serialize_address(:broadcast), do: %{type: "broadcast"}
end
