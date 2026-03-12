defmodule ApmV5.Correlation do
  @moduledoc """
  Manages correlation IDs via process dictionary for request tracing.
  """

  @key :apm_correlation_id

  @doc "Generates a new UUID v4 correlation ID."
  @spec generate() :: String.t()
  def generate do
    <<a::48, _::4, b::12, _::2, c::62>> = :crypto.strong_rand_bytes(16)

    # Insert version 4 nibble and variant bits (10xx)
    <<a::48, 4::4, b::12, 2::2, c::62>>
    |> Base.encode16(case: :lower)
    |> format_uuid()
  end

  defp format_uuid(<<a::binary-8, b::binary-4, c::binary-4, d::binary-4, e::binary-12>>) do
    "#{a}-#{b}-#{c}-#{d}-#{e}"
  end

  @doc "Stores a correlation ID in the process dictionary."
  @spec put(String.t()) :: :ok
  def put(correlation_id) do
    Process.put(@key, correlation_id)
    :ok
  end

  @doc "Retrieves the correlation ID from the process dictionary, or nil."
  @spec get() :: String.t() | nil
  def get do
    Process.get(@key)
  end

  @doc "Executes `fun` with `correlation_id` set, restoring the previous value after."
  @spec with_correlation(String.t(), (-> result)) :: result when result: any()
  def with_correlation(correlation_id, fun) do
    previous = get()
    put(correlation_id)

    try do
      fun.()
    after
      case previous do
        nil -> Process.delete(@key)
        val -> Process.put(@key, val)
      end
    end
  end
end
