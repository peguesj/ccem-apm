defmodule ApmV5.Uptime do
  @moduledoc "Shared uptime calculation helper."

  @spec seconds() :: non_neg_integer()
  def seconds do
    start = Application.get_env(:apm_v5, :server_start_time, System.monotonic_time(:second))
    max(System.monotonic_time(:second) - start, 0)
  end

  @spec formatted() :: String.t()
  def formatted do
    total = seconds()
    h = div(total, 3600)
    m = div(rem(total, 3600), 60)
    s = rem(total, 60)

    "#{String.pad_leading(to_string(h), 2, "0")}:#{String.pad_leading(to_string(m), 2, "0")}:#{String.pad_leading(to_string(s), 2, "0")}"
  end

  @spec formatted_short() :: String.t()
  def formatted_short do
    total = seconds()
    h = div(total, 3600)
    m = div(rem(total, 3600), 60)

    "#{String.pad_leading(to_string(h), 2, "0")}:#{String.pad_leading(to_string(m), 2, "0")}"
  end
end
