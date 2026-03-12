defmodule ApmV5Web.V2.ApiV2JSON do
  @moduledoc """
  Helper functions for v2 API standardized response envelopes,
  cursor-based pagination encoding/decoding, and error formatting.
  """

  @default_limit 50
  @max_limit 200

  @doc "Wrap data in the standard envelope with pagination meta."
  def envelope(data, meta \\ %{}, links \\ %{}) do
    %{data: data, meta: meta, links: links}
  end

  @doc "Standard error response."
  def error_response(code, message) do
    %{error: %{code: code, message: message}}
  end

  @doc "Parse limit from query params, clamped to 1..200."
  def parse_limit(params) do
    case params["limit"] do
      nil -> @default_limit
      val when is_binary(val) ->
        case Integer.parse(val) do
          {n, _} -> n |> max(1) |> min(@max_limit)
          :error -> @default_limit
        end
      val when is_integer(val) -> val |> max(1) |> min(@max_limit)
      _ -> @default_limit
    end
  end

  @doc "Decode a Base64-encoded JSON cursor into a map. Returns nil on invalid."
  def decode_cursor(nil), do: nil
  def decode_cursor(""), do: nil

  def decode_cursor(encoded) do
    with {:ok, json} <- Base.url_decode64(encoded, padding: false),
         {:ok, map} <- Jason.decode(json) do
      map
    else
      _ -> nil
    end
  end

  @doc "Encode a cursor map as Base64 JSON."
  def encode_cursor(nil), do: nil

  def encode_cursor(map) when is_map(map) do
    map |> Jason.encode!() |> Base.url_encode64(padding: false)
  end

  @doc """
  Apply cursor-based pagination to a list of items.
  Items must be sorted descending by the sort key already.
  Returns {page_items, next_cursor, has_more}.
  """
  def paginate(items, cursor, limit, id_key \\ :id, ts_key \\ :timestamp) do
    filtered =
      case cursor do
        nil ->
          items

        %{"id" => cursor_id, "timestamp" => cursor_ts} ->
          Enum.drop_while(items, fn item ->
            item_id = to_string(get_field(item, id_key))
            item_ts = to_string(get_field(item, ts_key))
            # Drop items until we pass the cursor point
            {item_ts, item_id} >= {cursor_ts, cursor_id}
          end)

        _ ->
          items
      end

    page = Enum.take(filtered, limit)
    has_more = length(filtered) > limit

    next_cursor =
      if has_more do
        last = List.last(page)
        encode_cursor(%{"id" => to_string(get_field(last, id_key)), "timestamp" => to_string(get_field(last, ts_key))})
      else
        nil
      end

    {page, next_cursor, has_more}
  end

  defp get_field(map, key) when is_atom(key), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp get_field(map, key) when is_binary(key), do: Map.get(map, key) || Map.get(map, String.to_existing_atom(key))
end
