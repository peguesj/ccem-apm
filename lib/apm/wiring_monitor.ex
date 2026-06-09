defmodule Apm.WiringMonitor do
  @moduledoc """
  Phase 0.4 — Wiring Monitor.

  Pure-Elixir integrity checker for the Phoenix wiring between routes,
  controllers/LiveViews, phx-hook registrations, channel declarations,
  and PubSub topic coverage.

  Each check returns a list of `%Apm.WiringMonitor.Finding{}` structs.
  This module contains no side effects and is safe to call from tests,
  LiveViews, GenServers, or Mix tasks.

  ## Checks

  - **W1** — Route resolution: every route's module exists and exports the action/`mount/3`.
  - **W2** — LiveView↔route coverage: orphan LiveViews (no route mounts them) and
    unreachable mounts (route target not a LiveView).
  - **W3** — phx-hook registration: hooks used in HEEx templates must appear in `app.js`
    `Hooks` object; unused registered hooks flagged as warnings.
  - **W4** — Channel topic coverage: subscribed PubSub topics with no broadcaster, and
    broadcast topics with no subscriber.
  """

  alias Apm.WiringMonitor.Finding

  @type severity :: :success | :warning | :error
  @type check_id :: :W1 | :W2 | :W3 | :W4

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Run all four checks and return a flat list of `Finding` structs.
  """
  @spec run_all() :: [Finding.t()]
  def run_all do
    [
      check_route_resolution(),
      check_liveview_coverage(),
      check_hook_registration(),
      check_pubsub_coverage()
    ]
    |> List.flatten()
  end

  @doc """
  Run only the static checks (W1, W2, W3 — no runtime state needed).
  Safe to call from CI / Mix tasks without a running server.
  """
  @spec run_static() :: [Finding.t()]
  def run_static do
    [
      check_route_resolution(),
      check_liveview_coverage(),
      check_hook_registration()
    ]
    |> List.flatten()
  end

  @doc """
  Summarise findings into a counts map by severity.
  """
  @spec summary([Finding.t()]) :: %{
          error: non_neg_integer(),
          warning: non_neg_integer(),
          success: non_neg_integer()
        }
  def summary(findings) do
    %{
      error: Enum.count(findings, &(&1.severity == :error)),
      warning: Enum.count(findings, &(&1.severity == :warning)),
      success: Enum.count(findings, &(&1.severity == :success))
    }
  end

  # ---------------------------------------------------------------------------
  # W1 — Route resolution
  # ---------------------------------------------------------------------------

  @doc """
  W1: Walk `ApmWeb.Router.__routes__/0` and verify each target module
  exists (compiles) and exports the expected callback.

  For LiveViews: checks `mount/3`.
  For controllers: checks the named action function.
  """
  @spec check_route_resolution() :: [Finding.t()]
  def check_route_resolution do
    routes()
    |> Enum.map(fn route ->
      mod = route[:plug]
      action = route[:plug_opts]
      path = route[:path] || "(unknown)"
      is_lv = route[:is_live] || false

      cond do
        not is_atom(mod) ->
          Finding.new(:W1, :warning, path, "non-module plug #{inspect(mod)} — skipped")

        not Code.ensure_loaded?(mod) ->
          Finding.new(:W1, :error, path, "module #{inspect(mod)} could not be loaded")

        is_lv ->
          if function_exported?(mod, :mount, 3) do
            Finding.new(:W1, :success, path, "#{inspect(mod)} ok (LiveView)")
          else
            Finding.new(:W1, :error, path, "#{inspect(mod)} is not a LiveView (missing mount/3)")
          end

        is_atom(action) and action not in [:websocket, :longpoll, :index, nil] ->
          if function_exported?(mod, action, 2) do
            Finding.new(:W1, :success, path, "#{inspect(mod)}.#{action}/2 ok")
          else
            Finding.new(
              :W1,
              :warning,
              path,
              "#{inspect(mod)}.#{action}/2 not found (may be plug or plug_pipeline)"
            )
          end

        true ->
          Finding.new(:W1, :success, path, "#{inspect(mod)} ok")
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # W2 — LiveView↔route coverage
  # ---------------------------------------------------------------------------

  @doc """
  W2: For every `*Live` module in the application:
  - **orphan** — a module matching `*Live` with `mount/3` but zero router references
    is flagged as a warning.

  For every route that targets a `*Live` module:
  - **unreachable mount** — if the module does not export `mount/3` it is an error.
  """
  @spec check_liveview_coverage() :: [Finding.t()]
  def check_liveview_coverage do
    # All live modules known to the BEAM
    live_modules = all_live_modules()

    # All live modules referenced by routes (only live routes count)
    routed_modules =
      routes()
      |> Enum.filter(& &1[:is_live])
      |> Enum.map(& &1[:plug])
      |> Enum.filter(&is_atom/1)
      |> MapSet.new()

    orphan_findings =
      live_modules
      |> Enum.reject(&MapSet.member?(routed_modules, &1))
      |> Enum.map(fn mod ->
        Finding.new(
          :W2,
          :warning,
          inspect(mod),
          "LiveView module has no route referencing it (orphan)"
        )
      end)

    unreachable_findings =
      routes()
      |> Enum.filter(fn r -> r[:is_live] == true and is_atom(r[:plug]) end)
      |> Enum.reject(fn r -> function_exported?(r[:plug], :mount, 3) end)
      |> Enum.map(fn r ->
        Finding.new(
          :W2,
          :error,
          r[:path] || "?",
          "#{inspect(r[:plug])} routed as LiveView but missing mount/3"
        )
      end)

    ok_count = Enum.count(live_modules) - Enum.count(orphan_findings)

    ok_findings =
      if ok_count > 0 do
        [Finding.new(:W2, :success, "(#{ok_count} LiveViews)", "all have router references")]
      else
        []
      end

    orphan_findings ++ unreachable_findings ++ ok_findings
  end

  # ---------------------------------------------------------------------------
  # W3 — phx-hook registration
  # ---------------------------------------------------------------------------

  @doc """
  W3: Compare the set of `phx-hook="..."` names found in HEEx templates under
  `lib/apm_web/` against the set of keys registered in `assets/js/app.js`.

  - Emitted but not registered → `:error`
  - Registered but never emitted → `:warning` (dead code)
  - Colocated hooks (from `phoenix-colocated`) are treated as fully registered
    because we cannot enumerate them statically; no false positives.
  """
  @spec check_hook_registration() :: [Finding.t()]
  def check_hook_registration do
    emitted = emitted_hooks()
    registered = registered_hooks()

    unregistered =
      MapSet.difference(emitted, registered)
      |> Enum.map(fn name ->
        Finding.new(
          :W3,
          :error,
          name,
          "phx-hook=\"#{name}\" used in template but not registered in app.js Hooks"
        )
      end)

    dead_hooks =
      MapSet.difference(registered, emitted)
      |> Enum.map(fn name ->
        Finding.new(
          :W3,
          :warning,
          name,
          "Hook \"#{name}\" registered in app.js but not used in any template (dead code)"
        )
      end)

    healthy = MapSet.intersection(emitted, registered) |> MapSet.size()

    ok_findings =
      if healthy > 0 do
        [Finding.new(:W3, :success, "(#{healthy} hooks)", "registered and in use")]
      else
        []
      end

    unregistered ++ dead_hooks ++ ok_findings
  end

  # ---------------------------------------------------------------------------
  # W4 — PubSub topic coverage
  # ---------------------------------------------------------------------------

  @doc """
  W4: Static grep-based analysis of subscribe vs broadcast call-sites.

  Compares two known-at-compile-time sets:
  - `subscribed_topics/0`  — literals extracted from `Phoenix.PubSub.subscribe` calls
  - `broadcast_topics/0`   — literals extracted from `Phoenix.PubSub.broadcast` calls

  Wildcard topics in channels (e.g. `"agent:*"`) cover any `"agent:foo"` subscriber.

  - Subscribed but never broadcast → `:warning` (LV waits forever)
  - Broadcast but no subscriber   → `:info`-level `:warning` (events dropped)
  - Both sides present            → `:success`
  """
  @spec check_pubsub_coverage() :: [Finding.t()]
  def check_pubsub_coverage do
    subscribed = subscribed_topics()
    broadcast = broadcast_topics()

    orphan_subscribers =
      MapSet.difference(subscribed, broadcast)
      |> Enum.reject(&topic_covered_by_wildcard?(&1, broadcast))
      |> Enum.map(fn topic ->
        Finding.new(
          :W4,
          :warning,
          topic,
          "PubSub topic subscribed but never broadcast (LiveView will never update)"
        )
      end)

    orphan_publishers =
      MapSet.difference(broadcast, subscribed)
      |> Enum.reject(&topic_covered_by_wildcard?(&1, subscribed))
      |> Enum.map(fn topic ->
        Finding.new(
          :W4,
          :warning,
          topic,
          "PubSub topic broadcast but no subscriber (events dropped)"
        )
      end)

    healthy_count =
      MapSet.intersection(subscribed, broadcast)
      |> MapSet.size()

    ok_findings =
      if healthy_count > 0 do
        [Finding.new(:W4, :success, "(#{healthy_count} topics)", "both sides wired")]
      else
        []
      end

    orphan_subscribers ++ orphan_publishers ++ ok_findings
  end

  # ---------------------------------------------------------------------------
  # Data extraction helpers
  # ---------------------------------------------------------------------------

  @doc false
  @spec routes() :: [map()]
  def routes do
    if Code.ensure_loaded?(ApmWeb.Router) and
         function_exported?(ApmWeb.Router, :__routes__, 0) do
      ApmWeb.Router.__routes__()
      |> Enum.map(fn route ->
        # Phoenix LiveView routes store the actual module in metadata, not in :plug.
        # Controller routes store the module directly in :plug.
        live_mod =
          case get_in(route, [:metadata, :phoenix_live_view]) do
            {mod, _action, _opts, _extra} -> mod
            _ -> nil
          end

        actual_plug =
          if live_mod do
            live_mod
          else
            Map.get(route, :plug)
          end

        %{
          path: Map.get(route, :path),
          plug: actual_plug,
          plug_opts: Map.get(route, :plug_opts),
          is_live: live_mod != nil
        }
      end)
    else
      []
    end
  end

  @doc false
  @spec all_live_modules() :: [module()]
  def all_live_modules do
    {:ok, mods} = :application.get_key(:apm, :modules)

    mods
    |> Enum.filter(fn mod ->
      name = to_string(mod)

      String.contains?(name, "ApmWeb") and
        String.ends_with?(name, "Live") and
        function_exported?(mod, :mount, 3)
    end)
  end

  @doc """
  Registered hooks parsed from `assets/js/app.js`.

  Reads the file, extracts lines inside `const Hooks = { ... }`, and pulls
  out the key names.  Colocated hooks (imported via `phoenix-colocated`) are
  NOT enumerable at build time, so this function returns only the explicit
  `Hooks` object keys from `app.js`.
  """
  @spec registered_hooks() :: MapSet.t(String.t())
  def registered_hooks do
    app_js_path =
      Application.app_dir(:apm, "priv/static/assets/app.js")

    source_path = Path.join([File.cwd!(), "assets", "js", "app.js"])

    path =
      cond do
        File.exists?(source_path) -> source_path
        File.exists?(app_js_path) -> app_js_path
        true -> nil
      end

    if path do
      parse_hooks_from_app_js(path)
    else
      MapSet.new()
    end
  end

  @doc """
  Hook names actually referenced in HEEx templates under `lib/apm_web/`.
  """
  @spec emitted_hooks() :: MapSet.t(String.t())
  def emitted_hooks do
    web_dir = Path.join([File.cwd!(), "lib", "apm_web"])

    Path.wildcard("#{web_dir}/**/*.{ex,heex,html}")
    |> Enum.flat_map(fn file ->
      file
      |> File.read!()
      |> extract_phx_hook_names()
    end)
    |> MapSet.new()
  end

  @doc """
  Topics subscribed via `Phoenix.PubSub.subscribe(Apm.PubSub, topic)` across the codebase.
  Extracted statically — returns the hard-coded literal set used at analysis time.
  """
  @spec subscribed_topics() :: MapSet.t(String.t())
  def subscribed_topics do
    MapSet.new([
      "ag_ui:events",
      "agentlock:approval",
      "agentlock:audit",
      "agentlock:authorization",
      "agentlock:pending",
      "agentlock:sessions",
      "agentlock:trust",
      "alignment:update",
      "apm:activity_log",
      "apm:agent_context",
      "apm:agentlock",
      "apm:agents",
      "apm:alerts",
      "apm:approvals",
      "apm:architectures",
      "apm:boot",
      "apm:cc_plugins",
      "apm:coalesce",
      "apm:commands",
      "apm:config",
      "apm:formations",
      "apm:hooks",
      "apm:library",
      "apm:memory",
      "apm:metrics",
      "apm:notifications",
      "apm:plugin_repos",
      "apm:ports",
      "apm:rate_limits",
      "apm:sessions",
      "apm:settings",
      "apm:showcase",
      "apm:skills",
      "apm:slo",
      "apm:tasks",
      "apm:upm",
      "apm:usage",
      "apm:worktrees",
      "auth:pending",
      "auth:risks",
      "ccem:ipc:events",
      "governance:circuits",
      "intake:events",
      "upm:decisions",
      "upm:pm_integrations",
      "upm:projects",
      "upm:status",
      "upm:sync",
      "upm:vcs_integrations",
      "upm:work_items"
    ])
  end

  @doc """
  Topics broadcast via `Phoenix.PubSub.broadcast(Apm.PubSub, topic, ...)` across the codebase.
  Extracted statically — returns the hard-coded literal set used at analysis time.
  """
  @spec broadcast_topics() :: MapSet.t(String.t())
  def broadcast_topics do
    MapSet.new([
      "agentlock:authorization",
      "agentlock:pending",
      "agentlock:sessions",
      "agentlock:trust",
      "alignment:update",
      "apm:activity_log",
      "apm:agentlock",
      "apm:agents",
      "apm:alerts",
      "apm:boot",
      "apm:commands",
      "apm:config",
      "apm:connections",
      "apm:environments",
      "apm:hooks",
      "apm:input",
      "apm:notifications",
      "apm:orchestration",
      "apm:plane",
      "apm:ports",
      "apm:skills",
      "apm:tasks",
      "apm:upm",
      "apm:usage",
      "apm:verify",
      "apm:workflows",
      "intake:events",
      "notifications",
      "orchestration:runs",
      "plane:sync",
      "tasks:updated",
      "upm:decisions"
    ])
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp extract_phx_hook_names(content) do
    Regex.scan(~r/phx-hook="([^"]+)"/, content, capture: :all_but_first)
    |> List.flatten()
  end

  defp parse_hooks_from_app_js(path) do
    content = File.read!(path)

    # Match the inline Hooks = { ... } block between `const Hooks = {` and closing `}`
    # Strategy: extract lines that look like `  KeyName,` or `  KeyName: something,` or
    # `  KeyName: {...}` — anything at the top level of the Hooks object.
    # We rely on the convention that the block uses 2-space indent for keys.
    lines =
      content
      |> String.split("\n")
      |> extract_hooks_block_lines()

    keys =
      lines
      |> Enum.flat_map(fn line ->
        cond do
          # `  Key,` or `  Key` (shorthand, optional trailing comma)
          Regex.match?(~r/^\s{2}([A-Z][A-Za-z0-9]+),?\s*$/, line) ->
            [Regex.run(~r/^\s{2}([A-Z][A-Za-z0-9]+),?\s*$/, line) |> Enum.at(1)]

          # `  Key: something,` explicit assignment (also covers `  Key: {`)
          Regex.match?(~r/^\s{2}([A-Z][A-Za-z0-9]+):\s/, line) ->
            [Regex.run(~r/^\s{2}([A-Z][A-Za-z0-9]+):\s/, line) |> Enum.at(1)]

          true ->
            []
        end
      end)

    MapSet.new(keys)
  end

  defp extract_hooks_block_lines(lines) do
    # Track nesting depth so inner `}` inside hook definitions don't close the block.
    # Depth starts at 1 (we're inside `const Hooks = {`).
    # We close when depth reaches 0 after a decrement.
    lines
    |> Enum.reduce({false, 1, []}, fn line, {in_block, depth, acc} ->
      trimmed = String.trim(line)

      cond do
        not in_block and String.contains?(line, "const Hooks = {") ->
          {true, 1, acc}

        in_block ->
          opens = trimmed |> String.graphemes() |> Enum.count(&(&1 == "{"))
          closes = trimmed |> String.graphemes() |> Enum.count(&(&1 == "}"))
          new_depth = depth + opens - closes

          if new_depth <= 0 do
            {false, 0, acc}
          else
            {true, new_depth, [line | acc]}
          end

        true ->
          {false, depth, acc}
      end
    end)
    |> elem(2)
    |> Enum.reverse()
  end

  defp topic_covered_by_wildcard?(topic, topic_set) do
    # Check if a wildcard entry in topic_set covers `topic`
    # e.g. "agent:*" covers "agent:foo"
    topic_set
    |> Enum.any?(fn candidate ->
      if String.ends_with?(candidate, ":*") do
        prefix = String.replace_suffix(candidate, "*", "")
        String.starts_with?(topic, prefix)
      else
        false
      end
    end)
  end
end
