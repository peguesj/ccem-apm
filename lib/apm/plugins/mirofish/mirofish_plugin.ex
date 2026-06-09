defmodule Apm.Plugins.Mirofish.MirofishPlugin do
  @moduledoc """
  APM Plugin for Miro (collaborative whiteboard) — integrates Miro REST API v2
  with the CCEM agentic framework for research + coalescence workflows.

  Formation agents can post findings, sticky notes, frames, and diagrams to a
  shared Miro board. The `coalesce_findings` bulk action arranges a list of
  `{title, body}` findings as a grid of sticky notes — ideal for distilling
  research squadron output into a visual workspace.

  ## Authentication

  Set a Miro developer access token via:

    - `MIRO_ACCESS_TOKEN` env var, or
    - `~/.config/mirofish/token` file (single line)

  See `references/miro-api.md` for the full endpoint inventory.
  """

  @behaviour Apm.Plugins.PluginBehaviour

  alias Apm.Plugins.Mirofish.MiroClient

  @grid_cols 4
  @grid_stride 260
  @default_sticky_width 200

  # ── PluginBehaviour: metadata ───────────────────────────────────────────────

  @impl true
  def plugin_name, do: "mirofish"

  @impl true
  def plugin_description,
    do: "Miro board integration for research + coalescence workflows"

  @impl true
  def plugin_version, do: "1.0.0"

  @impl true
  def plugin_scope, do: :ccem

  @impl true
  def list_endpoints do
    [
      %{
        action: "list_boards",
        description: "List boards accessible to the access token",
        params: %{limit: "integer (optional, default 50)", query: "string (optional)"}
      },
      %{
        action: "get_board",
        description: "Get a single board by ID",
        params: %{board_id: "string (required)"}
      },
      %{
        action: "create_board",
        description: "Create a new Miro board",
        params: %{
          name: "string (required)",
          description: "string (optional)",
          policy: "map (optional)"
        }
      },
      %{
        action: "create_sticky",
        description: "Create a sticky note on a board",
        params: %{
          board_id: "string (required)",
          content: "string (required)",
          x: "number (optional, default 0)",
          y: "number (optional, default 0)",
          color: "string (optional, default light_yellow)",
          shape: "string (optional, square|rectangle)"
        }
      },
      %{
        action: "create_frame",
        description: "Create a frame on a board",
        params: %{
          board_id: "string (required)",
          title: "string (required)",
          x: "number (optional, default 0)",
          y: "number (optional, default 0)",
          width: "number (optional, default 800)",
          height: "number (optional, default 600)"
        }
      },
      %{
        action: "create_text",
        description: "Create a text item on a board",
        params: %{
          board_id: "string (required)",
          content: "string (required)",
          x: "number (optional, default 0)",
          y: "number (optional, default 0)"
        }
      },
      %{
        action: "list_items",
        description: "List items on a board",
        params: %{board_id: "string (required)", limit: "integer (optional, default 50)"}
      },
      %{
        action: "delete_item",
        description: "Delete an item from a board",
        params: %{board_id: "string (required)", item_id: "string (required)"}
      },
      %{
        action: "coalesce_findings",
        description: "Create a grid of sticky notes from a list of findings — one per finding",
        params: %{
          board_id: "string (required)",
          findings: "list of {title, body, position?} maps (required)",
          origin_x: "number (optional, default 0)",
          origin_y: "number (optional, default 0)",
          color: "string (optional, default light_yellow)"
        }
      }
    ]
  end

  # ── PluginBehaviour: dispatch ───────────────────────────────────────────────

  @impl true
  def handle_action(action, params, _opts \\ []) do
    dispatch(action, normalize_keys(params))
  end

  # ── Action handlers ─────────────────────────────────────────────────────────

  defp dispatch("list_boards", params) do
    opts =
      []
      |> put_opt(:limit, params["limit"])
      |> put_opt(:query, params["query"])

    MiroClient.list_boards(opts)
  end

  defp dispatch("get_board", %{"board_id" => id}) when is_binary(id) and id != "" do
    MiroClient.get_board(id)
  end

  defp dispatch("create_board", params) do
    case params["name"] do
      name when is_binary(name) and name != "" ->
        body =
          %{"name" => name}
          |> maybe_put("description", params["description"])
          |> maybe_put("policy", params["policy"])

        MiroClient.create_board(body)

      _ ->
        {:error, {:missing_param, "name"}}
    end
  end

  defp dispatch("create_sticky", %{"board_id" => board_id, "content" => content} = p)
       when is_binary(board_id) and is_binary(content) do
    payload = sticky_payload(content, p)
    MiroClient.create_sticky(board_id, payload)
  end

  defp dispatch("create_frame", %{"board_id" => board_id, "title" => title} = p)
       when is_binary(board_id) and is_binary(title) do
    payload = %{
      "data" => %{"title" => title, "format" => "custom", "type" => "freeform"},
      "position" => %{
        "x" => to_num(p["x"], 0),
        "y" => to_num(p["y"], 0),
        "origin" => "center"
      },
      "geometry" => %{
        "width" => to_num(p["width"], 800),
        "height" => to_num(p["height"], 600)
      }
    }

    MiroClient.create_frame(board_id, payload)
  end

  defp dispatch("create_text", %{"board_id" => board_id, "content" => content} = p)
       when is_binary(board_id) and is_binary(content) do
    payload = %{
      "data" => %{"content" => content},
      "position" => %{"x" => to_num(p["x"], 0), "y" => to_num(p["y"], 0)}
    }

    MiroClient.create_text(board_id, payload)
  end

  defp dispatch("list_items", %{"board_id" => board_id} = p) when is_binary(board_id) do
    opts = put_opt([], :limit, p["limit"])
    MiroClient.list_items(board_id, opts)
  end

  defp dispatch("delete_item", %{"board_id" => bid, "item_id" => iid})
       when is_binary(bid) and is_binary(iid) do
    MiroClient.delete_item(bid, iid)
  end

  defp dispatch("coalesce_findings", %{"board_id" => board_id, "findings" => findings})
       when is_binary(board_id) and is_list(findings) do
    coalesce(board_id, findings, %{})
  end

  defp dispatch("coalesce_findings", %{"board_id" => board_id, "findings" => findings} = p)
       when is_binary(board_id) and is_list(findings) do
    coalesce(board_id, findings, p)
  end

  defp dispatch(action, _params)
       when action in [
              "get_board",
              "create_sticky",
              "create_frame",
              "create_text",
              "list_items",
              "delete_item",
              "coalesce_findings"
            ] do
    {:error, {:invalid_params, action}}
  end

  defp dispatch(action, _params) do
    {:error, {:unknown_action, action}}
  end

  # ── Coalesce logic ──────────────────────────────────────────────────────────

  defp coalesce(_board_id, [], _opts) do
    {:ok, %{created: 0, items: []}}
  end

  defp coalesce(board_id, findings, opts) do
    origin_x = to_num(opts["origin_x"], 0)
    origin_y = to_num(opts["origin_y"], 0)
    color = opts["color"] || "light_yellow"

    {results, errors} =
      findings
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {finding, idx}, {ok_acc, err_acc} ->
        finding = normalize_keys(finding)
        title = to_string(finding["title"] || "")
        body = to_string(finding["body"] || "")
        content = format_finding(title, body)
        {x, y} = grid_position(idx, origin_x, origin_y, finding)

        payload =
          sticky_payload(content, %{
            "x" => x,
            "y" => y,
            "color" => color,
            "shape" => "rectangle"
          })

        case MiroClient.create_sticky(board_id, payload) do
          {:ok, item} -> {[item | ok_acc], err_acc}
          {:error, reason} -> {ok_acc, [%{index: idx, reason: reason} | err_acc]}
        end
      end)

    items = Enum.reverse(results)

    {:ok,
     %{
       created: length(items),
       items: items,
       errors: Enum.reverse(errors)
     }}
  end

  defp grid_position(idx, origin_x, origin_y, finding) do
    case finding["position"] do
      %{"x" => x, "y" => y} ->
        {to_num(x, 0), to_num(y, 0)}

      _ ->
        col = rem(idx, @grid_cols)
        row = div(idx, @grid_cols)
        {origin_x + col * @grid_stride, origin_y + row * @grid_stride}
    end
  end

  defp format_finding("", body), do: body
  defp format_finding(title, ""), do: title
  defp format_finding(title, body), do: "#{title}\n\n#{body}"

  # ── Payload helpers ─────────────────────────────────────────────────────────

  defp sticky_payload(content, p) do
    %{
      "data" => %{
        "content" => content,
        "shape" => p["shape"] || "square"
      },
      "style" => %{"fillColor" => p["color"] || "light_yellow"},
      "position" => %{
        "x" => to_num(p["x"], 0),
        "y" => to_num(p["y"], 0),
        "origin" => "center"
      },
      "geometry" => %{"width" => to_num(p["width"], @default_sticky_width)}
    }
  end

  defp put_opt(opts, _k, nil), do: opts
  defp put_opt(opts, _k, ""), do: opts
  defp put_opt(opts, k, v), do: Keyword.put(opts, k, v)

  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, _k, ""), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)

  defp to_num(nil, default), do: default
  defp to_num(v, _default) when is_number(v), do: v

  defp to_num(v, default) when is_binary(v) do
    case Float.parse(v) do
      {n, _} -> n
      _ -> default
    end
  end

  defp to_num(_, default), do: default

  defp normalize_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {to_string(k), v}
    end)
  end

  defp normalize_keys(other), do: other
end
