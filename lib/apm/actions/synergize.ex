defmodule Apm.Actions.Synergize do
  @moduledoc """
  Synergize action — distribute Claude Code configuration to other IDE copilots.

  Supports 9 copilot formats with three modes: :symlink, :copy, :reference.
  """

  @copilots %{
    "github-copilot" => %{name: "GitHub Copilot", file: ".github/copilot-instructions.md"},
    "cursor" => %{name: "Cursor", file: ".cursor/rules"},
    "continue" => %{name: "Continue", file: ".continue/config.json"},
    "cline" => %{name: "Cline", file: ".cline/instructions.md"},
    "codex" => %{name: "Codex CLI", file: "AGENTS.md"},
    "roo-code" => %{name: "Roo Code", file: ".roo/instructions.md"},
    "jetbrains" => %{name: "JetBrains AI", file: ".junie/guidelines.md"},
    "replit" => %{name: "Replit Agent", file: ".replit/agent.md"},
    "antigravity" => %{name: "Antigravity", file: ".antigravity/config.md"}
  }

  @spec run(map()) :: {:ok, map()} | {:error, String.t()}
  def run(params) do
    copilot = Map.get(params, "copilot", "all")
    mode = params |> Map.get("mode", "reference") |> parse_mode()
    root = Map.get(params, "project_root", File.cwd!())

    targets = if copilot == "all", do: Map.keys(@copilots), else: [copilot]

    results =
      Enum.map(targets, fn id ->
        case Map.get(@copilots, id) do
          nil -> {id, {:error, "unknown copilot"}}
          config -> {id, sync(config.file, mode, root)}
        end
      end)
      |> Map.new()

    {:ok, %{results: results, mode: mode, timestamp: DateTime.utc_now()}}
  rescue
    e -> {:error, Exception.message(e)}
  end

  @spec list_copilots() :: [map()]
  def list_copilots, do: @copilots |> Enum.map(fn {id, c} -> Map.put(c, :id, id) end)

  @spec preview(map()) :: {:ok, map()}
  def preview(params) do
    copilot = Map.get(params, "copilot", "all")
    targets = if copilot == "all", do: Map.keys(@copilots), else: [copilot]
    previews = Enum.filter(targets, &Map.has_key?(@copilots, &1)) |> Enum.map(&%{id: &1, config: @copilots[&1]})
    {:ok, %{targets: previews, count: length(previews)}}
  end

  defp parse_mode("symlink"), do: :symlink
  defp parse_mode("copy"), do: :copy
  defp parse_mode(_), do: :reference

  defp sync(file, mode, root) do
    target = Path.join(root, file)
    source = Path.join(root, "CLAUDE.md")
    File.mkdir_p!(Path.dirname(target))

    case mode do
      :symlink ->
        case File.ln_s(source, target) do
          :ok -> {:ok, "symlinked"}
          {:error, :eexist} -> {:ok, "exists"}
          {:error, r} -> {:error, inspect(r)}
        end

      :copy ->
        case File.cp(source, target) do
          :ok -> {:ok, "copied"}
          {:error, r} -> {:error, inspect(r)}
        end

      :reference ->
        content = "# CCEM Synergized Config\n# Source: #{source}\n# See CLAUDE.md for authoritative instructions\n"
        case File.write(target, content) do
          :ok -> {:ok, "reference"}
          {:error, r} -> {:error, inspect(r)}
        end
    end
  end
end
