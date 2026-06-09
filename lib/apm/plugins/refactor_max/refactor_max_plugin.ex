defmodule Apm.Plugins.RefactorMax.RefactorMaxPlugin do
  @moduledoc """
  APM Plugin exposing the `/refactor-max` methodology as structured actions:

    * `scan_code_smells`       — heuristic code-smell scan of a target path
    * `generate_refactor_plan` — emits a phased refactor plan as JSON
    * `execute_refactor`       — delegates execution to FormationStore (if available)
    * `verify_refactor`        — runs `mix compile` + `mix test`
    * `list_refactors`         — returns recent refactor run metadata
    * `get_refactor`           — fetch a specific refactor run

  Wraps the `/refactor-max` skill (`~/.claude/skills/refactor-max/SKILL.md`).
  """

  use Apm.Plugins.SkillPluginBridge

  require Logger

  @skill_commands ~w(scan_code_smells generate_refactor_plan execute_refactor verify_refactor list_refactors get_refactor)

  @long_module_threshold 400

  # ── SkillPluginBridge ────────────────────────────────────────────────────────

  @impl Apm.Plugins.SkillPluginBridge
  def skill_name, do: "refactor-max"

  @impl Apm.Plugins.SkillPluginBridge
  def skill_path, do: Path.expand("~/.claude/skills/refactor-max/SKILL.md")

  @impl Apm.Plugins.SkillPluginBridge
  def skill_commands, do: @skill_commands

  @impl Apm.Plugins.SkillPluginBridge
  def dispatch_skill_command(command, params),
    do: handle_action(command, params, [])

  # ── PluginBehaviour ──────────────────────────────────────────────────────────

  @impl Apm.Plugins.PluginBehaviour
  def plugin_name, do: "refactor_max"

  @impl Apm.Plugins.PluginBehaviour
  def plugin_description,
    do: "Refactor-Max methodology — scan code smells, plan phased refactors, execute & verify"

  @impl Apm.Plugins.PluginBehaviour
  def plugin_version, do: "1.0.0"

  @impl Apm.Plugins.PluginBehaviour
  def list_endpoints do
    [
      %{
        action: "scan_code_smells",
        description: "Heuristic code-smell scan of a target path",
        params: %{target_path: "string (required)"}
      },
      %{
        action: "generate_refactor_plan",
        description: "Produce a phased refactor plan from scan results",
        params: %{target_path: "string (required)", smells: "array (optional)"}
      },
      %{
        action: "execute_refactor",
        description: "Execute a generated refactor plan via FormationStore",
        params: %{plan: "map (required)"}
      },
      %{
        action: "verify_refactor",
        description: "Run mix compile + mix test; report results",
        params: %{target_path: "string (optional)"}
      },
      %{action: "list_refactors", description: "List recent refactor runs", params: %{}},
      %{
        action: "get_refactor",
        description: "Get a specific refactor run",
        params: %{id: "string (required)"}
      }
    ]
  end

  @impl Apm.Plugins.PluginBehaviour
  def nav_items do
    base = "/plugins/refactor_max"

    [
      {"Scan", "#{base}/scan", "hero-magnifying-glass"},
      {"Plan", "#{base}/plan", "hero-clipboard-document-list"},
      {"Execute", "#{base}/execute", "hero-play"},
      {"Verify", "#{base}/verify", "hero-check-circle"}
    ]
  end

  @impl Apm.Plugins.PluginBehaviour
  def plugin_live_module, do: nil

  @impl Apm.Plugins.PluginBehaviour
  def handle_action("scan_code_smells", %{"target_path" => path}, _opts) when is_binary(path) do
    case scan_smells(path) do
      {:ok, smells} -> {:ok, %{smells: smells, count: length(smells), target_path: path}}
      {:error, reason} -> {:error, reason}
    end
  end

  def handle_action("scan_code_smells", _params, _opts),
    do: {:error, {:missing_param, "target_path is required"}}

  def handle_action("generate_refactor_plan", %{"target_path" => path} = params, _opts) do
    smells =
      case Map.get(params, "smells") do
        list when is_list(list) ->
          list

        _ ->
          case scan_smells(path) do
            {:ok, s} -> s
            _ -> []
          end
      end

    plan = build_plan(smells, path)
    {:ok, %{plan: plan, target_path: path, smell_count: length(smells)}}
  end

  def handle_action("generate_refactor_plan", _params, _opts),
    do: {:error, {:missing_param, "target_path is required"}}

  def handle_action("execute_refactor", %{"plan" => plan}, _opts) when is_map(plan) do
    formation_module = Apm.FormationStore

    if Code.ensure_loaded?(formation_module) and
         function_exported?(formation_module, :deploy_formation, 1) do
      case apply(formation_module, :deploy_formation, [plan]) do
        {:ok, formation} -> {:ok, %{status: "deployed", formation: formation}}
        {:error, reason} -> {:error, reason}
        other -> {:ok, %{status: "dispatched", result: inspect(other)}}
      end
    else
      {:ok,
       %{
         status: "stubbed",
         note: "FormationStore.deploy_formation/1 unavailable — plan accepted",
         plan: plan
       }}
    end
  end

  def handle_action("execute_refactor", _params, _opts),
    do: {:error, {:missing_param, "plan is required"}}

  def handle_action("verify_refactor", params, _opts) do
    path = Map.get(params, "target_path", File.cwd!())

    {compile_out, compile_exit} =
      System.cmd("mix", ["compile", "--warnings-as-errors"], cd: path, stderr_to_stdout: true)

    {test_out, test_exit} =
      if compile_exit == 0 do
        System.cmd("mix", ["test", "--max-failures", "5"], cd: path, stderr_to_stdout: true)
      else
        {"skipped", -1}
      end

    {:ok,
     %{
       compile: %{exit: compile_exit, passed: compile_exit == 0, tail: tail(compile_out, 40)},
       tests: %{exit: test_exit, passed: test_exit == 0, tail: tail(test_out, 40)},
       overall: compile_exit == 0 and test_exit == 0
     }}
  end

  def handle_action("list_refactors", _params, _opts) do
    {:ok, %{refactors: [], count: 0, note: "Refactor run persistence not yet implemented."}}
  end

  def handle_action("get_refactor", %{"id" => id}, _opts) do
    {:error, {:not_found, id}}
  end

  def handle_action("get_refactor", _params, _opts),
    do: {:error, {:missing_param, "id is required"}}

  def handle_action(action, _params, _opts),
    do: {:error, {:unknown_action, action}}

  # ── Private helpers ─────────────────────────────────────────────────────────

  defp scan_smells(path) do
    cond do
      not File.exists?(path) ->
        {:error, {:not_found, path}}

      File.dir?(path) ->
        {:ok, scan_directory(path)}

      true ->
        {:ok, scan_file(path)}
    end
  end

  defp scan_directory(dir) do
    dir
    |> Path.join("**/*.ex")
    |> Path.wildcard()
    |> Enum.flat_map(&scan_file/1)
  end

  defp scan_file(file) do
    case File.read(file) do
      {:ok, content} ->
        lines = String.split(content, "\n")
        line_count = length(lines)
        smells = []

        smells =
          if line_count > @long_module_threshold do
            [
              %{
                severity: :high,
                kind: :long_module,
                file: file,
                detail: "Module has #{line_count} lines (> #{@long_module_threshold})"
              }
              | smells
            ]
          else
            smells
          end

        smells =
          lines
          |> Enum.with_index(1)
          |> Enum.reduce(smells, fn {line, idx}, acc ->
            cond do
              String.match?(line, ~r/#\s*TODO\b/i) ->
                [
                  %{
                    severity: :low,
                    kind: :todo_comment,
                    file: file,
                    line: idx,
                    detail: String.trim(line)
                  }
                  | acc
                ]

              String.match?(line, ~r/#\s*FIXME\b/i) ->
                [
                  %{
                    severity: :medium,
                    kind: :fixme_comment,
                    file: file,
                    line: idx,
                    detail: String.trim(line)
                  }
                  | acc
                ]

              true ->
                acc
            end
          end)

        smells

      _ ->
        []
    end
  end

  defp build_plan(smells, target_path) do
    grouped = Enum.group_by(smells, &Map.get(&1, :severity, :low))

    phases = [
      %{
        phase: 1,
        name: "High-severity fixes",
        items: Map.get(grouped, :high, []),
        gate: "mix compile --warnings-as-errors"
      },
      %{
        phase: 2,
        name: "Medium-severity cleanup",
        items: Map.get(grouped, :medium, []),
        gate: "mix test"
      },
      %{
        phase: 3,
        name: "Low-severity hygiene",
        items: Map.get(grouped, :low, []),
        gate: "mix format --check-formatted"
      }
    ]

    %{
      target_path: target_path,
      phases: phases,
      total_items: length(smells),
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp tail(text, n) when is_binary(text) do
    text
    |> String.split("\n")
    |> Enum.take(-n)
    |> Enum.join("\n")
  end
end
