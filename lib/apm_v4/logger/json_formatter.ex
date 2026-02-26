defmodule ApmV4.Logger.JsonFormatter do
  @moduledoc """
  Custom Logger formatter that outputs structured JSON lines.

  Each log line is a JSON object with keys: level, msg, ts, correlation_id,
  module, and function.

  ## Usage in config

      config :logger, :json_formatter,
        format: {ApmV4.Logger.JsonFormatter, :format},
        metadata: [:module, :function]
  """

  alias ApmV4.Correlation

  @doc "Formats a log event as a JSON string."
  @spec format(atom(), String.t(), Logger.Formatter.time(), keyword()) :: iodata()
  def format(level, message, timestamp, metadata) do
    json =
      %{
        level: to_string(level),
        msg: IO.iodata_to_binary(message),
        ts: format_timestamp(timestamp),
        correlation_id: Correlation.get(),
        module: metadata[:module] |> inspect_if_present(),
        function: metadata[:function]
      }
      |> Jason.encode!()

    [json, "\n"]
  rescue
    _ -> "#{inspect({level, message, timestamp, metadata})}\n"
  end

  defp format_timestamp({date, {h, m, s, _ms}}) do
    {year, month, day} = date

    NaiveDateTime.new!(year, month, day, h, m, s)
    |> NaiveDateTime.to_iso8601()
    |> Kernel.<>("Z")
  end

  defp inspect_if_present(nil), do: nil
  defp inspect_if_present(mod) when is_atom(mod), do: inspect(mod)
  defp inspect_if_present(other), do: to_string(other)
end
