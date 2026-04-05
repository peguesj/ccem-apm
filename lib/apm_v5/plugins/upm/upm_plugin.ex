defmodule ApmV5.Plugins.Upm.UpmPlugin do
  @moduledoc """
  APM Plugin exposing the `/upm` Unified Project Management workflow orchestrator
  as a first-class APM plugin with 9 actions:

    * `plan`       — generate a PRD from a feature description
    * `build`      — execute wave implementation
    * `verify`     — run double-verify + test matrix
    * `ship`       — SCX ship workflow (commit, PR, tag)
    * `status`     — inspect current prd.json / wave / checkpoint state
    * `sync`       — Plane PM bidirectional sync
    * `integrity`  — checkpoint/story drift detection
    * `usage`      — usage/effort-level report for the project
    * `formation`  — deploy a formation aligned to the active wave

  Workflow logic lives in the underlying `/upm` skill
  (`~/.claude/skills/upm/SKILL.md`). This plugin is a thin Elixir adapter that
  delegates to the skill via in-process handlers or shell-out invocations.
  """

  use ApmV5.Plugins.SkillPluginBridge

  @skill_commands ~w(plan build verify ship status sync integrity usage formation)

  # ── SkillPluginBridge ────────────────────────────────────────────────────────

  @impl ApmV5.Plugins.SkillPluginBridge
  def skill_name, do: "upm"

  @impl ApmV5.Plugins.SkillPluginBridge
  def skill_path, do: Path.expand("~/.claude/skills/upm/SKILL.md")

  @impl ApmV5.Plugins.SkillPluginBridge
  def skill_commands, do: @skill_commands

  @impl ApmV5.Plugins.SkillPluginBridge
  def dispatch_skill_command(command, params) when is_binary(command) and is_map(params) do
    handle_action(command, params, [])
  end

  # ── PluginBehaviour ──────────────────────────────────────────────────────────

  @impl ApmV5.Plugins.PluginBehaviour
  def plugin_name, do: "upm"

  @impl ApmV5.Plugins.PluginBehaviour
  def plugin_description,
    do: "Unified Project Management — plan, build, verify, ship; wraps the /upm skill"

  @impl ApmV5.Plugins.PluginBehaviour
  def plugin_version, do: "1.0.0"

  @impl ApmV5.Plugins.PluginBehaviour
  def list_endpoints do
    [
      %{action: "plan",      description: "Generate prd.json from a feature description",  params: %{feature_description: "string (required)"}},
      %{action: "build",     description: "Execute the active wave of the current prd.json", params: %{wave: "integer (optional)"}},
      %{action: "verify",    description: "Run double-verify + test matrix for current work", params: %{story_ids: "array (optional)"}},
      %{action: "ship",      description: "Run SCX ship workflow (commit, push, PR, tag)", params: %{version: "string (optional)"}},
      %{action: "status",    description: "Report prd.json wave/story/checkpoint state",   params: %{cwd: "string (optional)"}},
      %{action: "sync",      description: "Bidirectional Plane PM sync",                   params: %{project_id: "string (optional)"}},
      %{action: "integrity", description: "Checkpoint/story drift detection",              params: %{cwd: "string (optional)"}},
      %{action: "usage",     description: "Usage/effort-level report for the active project", params: %{project: "string (optional)"}},
      %{action: "formation", description: "Deploy a formation aligned to the active wave", params: %{wave: "integer (optional)", dry_run: "boolean (optional)"}}
    ]
  end

  @impl ApmV5.Plugins.PluginBehaviour
  def plugin_live_module, do: nil

  @impl ApmV5.Plugins.PluginBehaviour
  def nav_items do
    base = "/plugins/upm"

    [
      {"Plan",   "#{base}/plan",   "hero-document-text"},
      {"Build",  "#{base}/build",  "hero-wrench-screwdriver"},
      {"Verify", "#{base}/verify", "hero-check-badge"},
      {"Ship",   "#{base}/ship",   "hero-rocket-launch"},
      {"Status", "#{base}/status", "hero-chart-bar"}
    ]
  end

  @impl ApmV5.Plugins.PluginBehaviour
  def handle_action("plan", %{"feature_description" => desc}, _opts) when is_binary(desc) and desc != "" do
    {:ok,
     %{
       action: "plan",
       feature_description: desc,
       prd_path: default_prd_path(),
       plane_issues: [],
       note: "Plan dispatch delegates to the /upm skill; invoke via the skill for full execution."
     }}
  end

  def handle_action("plan", _params, _opts),
    do: {:error, {:missing_param, "feature_description is required"}}

  def handle_action("status", params, _opts) do
    cwd = Map.get(params, "cwd") || File.cwd!()

    case read_prd(cwd) do
      {:ok, prd, path} ->
        stories = Map.get(prd, "userStories", [])
        done = Enum.count(stories, &Map.get(&1, "passes", false))
        total = length(stories)
        active_wave = infer_active_wave(stories)

        {:ok,
         %{
           action: "status",
           cwd: cwd,
           prd_path: path,
           project: Map.get(prd, "project"),
           branch: Map.get(prd, "branchName"),
           stories_total: total,
           stories_passed: done,
           stories_pending: total - done,
           active_wave: active_wave,
           checkpoint_range: get_in(prd, ["upm", "checkpointRange"])
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def handle_action("build", params, _opts) do
    wave = Map.get(params, "wave")
    {:ok, %{action: "build", wave: wave, note: "Delegate to /upm build via skill invocation."}}
  end

  def handle_action("verify", params, _opts) do
    {:ok, %{action: "verify", story_ids: Map.get(params, "story_ids", []), note: "Delegate to /upm verify via skill invocation."}}
  end

  def handle_action("ship", params, _opts) do
    {:ok, %{action: "ship", version: Map.get(params, "version"), note: "Delegate to /ship skill."}}
  end

  def handle_action("sync", params, _opts) do
    {:ok, %{action: "sync", project_id: Map.get(params, "project_id"), note: "Delegate to Plane sync via PlanePmAlign."}}
  end

  def handle_action("integrity", params, _opts) do
    cwd = Map.get(params, "cwd") || File.cwd!()

    case read_prd(cwd) do
      {:ok, prd, _path} ->
        stories = Map.get(prd, "userStories", [])
        drift =
          Enum.filter(stories, fn s ->
            status = Map.get(s, "status")
            passes = Map.get(s, "passes", false)
            (status == "completed" and not passes) or (status == "pending" and passes)
          end)

        {:ok, %{action: "integrity", drift_count: length(drift), drift_stories: Enum.map(drift, &Map.get(&1, "id"))}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def handle_action("usage", params, _opts) do
    {:ok, %{action: "usage", project: Map.get(params, "project"), note: "See /api/usage/summary for live data."}}
  end

  def handle_action("formation", params, _opts) do
    {:ok, %{action: "formation", wave: Map.get(params, "wave"), dry_run: Map.get(params, "dry_run", true)}}
  end

  def handle_action(action, _params, _opts),
    do: {:error, {:unknown_action, action}}

  # ── Private helpers ─────────────────────────────────────────────────────────

  defp default_prd_path, do: Path.join(File.cwd!(), "prd.json")

  defp read_prd(cwd) do
    candidates = [
      Path.join(cwd, "prd.json"),
      Path.join(cwd, "prd-skill-plugins.json")
    ]

    case Enum.find(candidates, &File.exists?/1) do
      nil -> {:error, :prd_not_found}
      path ->
        with {:ok, body} <- File.read(path),
             {:ok, json} <- Jason.decode(body) do
          {:ok, json, path}
        else
          {:error, reason} -> {:error, {:prd_parse_error, reason}}
        end
    end
  end

  defp infer_active_wave(stories) when is_list(stories) do
    stories
    |> Enum.filter(fn s -> Map.get(s, "passes", false) == false end)
    |> Enum.map(&Map.get(&1, "wave", 0))
    |> Enum.min(fn -> 0 end)
  end
end
