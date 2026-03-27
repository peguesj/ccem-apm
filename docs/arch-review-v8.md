# CCEM APM v8.0.0 — Architecture Review

**Reviewer**: Claude Sonnet 4.6 (Elixir/OTP Architect)
**Date**: 2026-03-25
**Branch**: `ralph/ccem-v8-0-0-modularization`
**Scope**: Plugin engine, integration engine, ETS registry design, supervision tree

---

## 1. PluginBehaviour Contract Assessment

### Verdict: Mostly idiomatic — three friction points

The core of the behaviour (`plugin_name/0`, `plugin_description/0`, `plugin_version/0`, `list_endpoints/0`, `handle_action/3`) is clean and idiomatic. The optional callbacks added in v8 (`supervisor_children/0`, `live_views/0`, `on_enable/0`, `on_disable/0`, `default_enabled?/0`) introduce a few concerns.

#### `supervisor_children/0` — Wrong abstraction level

Returning a raw `[Supervisor.child_spec()]` list from a stateless behaviour module creates an ownership problem: **who starts and supervises these children?** Currently the PluginRegistry does not act on the return value — it only stores plugin metadata in ETS. The children are never started. Existing implementations (`RalphPlugin`, `FormationsPlugin`, `UatPlugin`) all return `[]`, which papers over the issue.

The OTP-correct pattern for a plugin with supervised processes is a **dedicated plugin supervisor module** — not a list of child specs returned from the plugin module. The `supervisor_children/0` approach also prevents dynamic enable/disable from working correctly: you cannot add/remove children from a running supervisor via a callback return value without a `DynamicSupervisor`.

**Recommendation**: Replace `supervisor_children/0` with an optional `plugin_supervisor/0 :: module() | nil` callback. If non-nil, the PluginSupervisor starts that module as a child. The plugin supervisor module is responsible for its own children. This decouples the registry from child lifecycle management.

#### `live_views/0` — Router coupling is a compile-time problem

`live_views/0` returns `{path, module, opts}` tuples, implying the router would call this at startup and add routes dynamically. Phoenix Router routes are **compiled at build time** — `Phoenix.Router` does not support runtime route injection. Calling `live_views/0` from any router pipeline would require a complete application restart plus recompile to take effect, which is no different from a static list in the router.

The correct Phoenix pattern for plugin-driven LiveView UI is a **catch-all route** that reads from the registry at request time, or a **namespace-scoped mount** in the router that delegates to a PluginLive dispatcher. The `live_views/0` callback creates a false affordance.

**Recommendation**: Remove `live_views/0` from the behaviour. Document the convention that plugins mounting LiveViews should use a scoped path prefix (e.g., `/plugins/:plugin_name/*`) served by a single `PluginLive` dispatcher, which uses the registry at runtime to resolve the module.

#### `on_enable/0` / `on_disable/0` — Missing error propagation context

These return `:ok | {:error, term()}` but the PluginRegistry has no code path that calls them. Without a calling convention, they are orphaned callbacks. Furthermore, `on_enable/0` has no way to receive the current runtime configuration or context — it takes no arguments. If `on_enable` needs to start a connection pool or subscribe to an external channel, it needs config.

**Recommendation**: Align `on_enable/1` with the IntegrationBehaviour's `connect/1` signature: `on_enable(config :: map()) :: :ok | {:error, term()}`. Add explicit call sites in PluginRegistry's (future) `enable_plugin/2` and `disable_plugin/1` functions.

#### `inspector_section/1` — Pattern is workable but fragile

Returning a `map()` with a `:html` key containing a pre-rendered HTML fragment is a LiveView anti-pattern. LiveView components should use `~H` sigil templates, not raw HTML strings. A raw HTML blob bypasses XSS sanitization (Phoenix.HTML.safe_to_string must be called, which is frequently forgotten) and prevents LiveView from tracking changes.

The correct pattern for plugin-injected UI in a LiveView is a **component module callback**: `inspector_component() :: module()` returning a `Phoenix.Component` module. The LiveView calls `<.live_component module={mod} id="inspector" assigns={@assigns} />`.

**Recommendation**: Change `inspector_section/1` to `inspector_component() :: module() | nil`. The returned module must implement `Phoenix.LiveComponent`. This is a P1 change before any plugins implement real UI.

#### `default_enabled?/0` — Correct but incomplete

The callback is fine. The gap is that the PluginRegistry never reads it — registration always succeeds unconditionally. The registry needs an `enabled` field in its ETS metadata and must check `default_enabled?()` (with a fallback to `true` when the optional callback is absent) at registration time.

---

## 2. IntegrationBehaviour Design Assessment

### Verdict: Over-engineered in one area, under-specified in another

#### `connect/1` / `disconnect/0` lifecycle — Correct framing, wrong executor

`connect/1` and `disconnect/0` are the right lifecycle primitives. The problem is the same as `supervisor_children/0` above: **these are pure module-level callbacks with no process to own the connection state**. If `connect/1` opens a WebSocket or a connection pool, that state must live in a process — but the IntegrationBehaviour is a plain module, not a GenServer.

The IntegrationRegistry calls `safe_status(module)` at registration time, which invokes `module.status()`. If the integration has not connected yet (because `connect/1` hasn't been called), this returns `:disconnected`, which is correct but disconnects the concept of registration from lifecycle management.

**Recommendation**: Integrations that maintain external connections should be GenServer-backed. The `IntegrationBehaviour` should optionally require a `start_link/1` callback (marking it as a supervised process), and the `IntegrationRegistry` should start it as a child of the (yet-to-be-created) `IntegrationSupervisor`. Connection lifecycle management (`connect/1`, `disconnect/0`) belongs in the integration's own `init/1` and `terminate/2` callbacks, not as standalone module functions.

For stateless integrations (REST adapters that just translate calls), the current pattern is fine.

#### `on_connect_callback/1` and `on_disconnect_callback/0` — Redundant

These duplicate what `connect/1` and `disconnect/0` already do. If they represent "post-connect" hooks, that logic belongs inside the integration's own `connect/1` implementation. There is no external caller that would invoke `on_connect_callback` separately from `connect`.

**Recommendation**: Remove `on_connect_callback/1` and `on_disconnect_callback/0`. Move post-connect logic into `connect/1` and `disconnect/0` respectively.

#### `protocol/0` — Useful for the dashboard, but too restrictive

`:ag_ui | :oauth2 | :webhook | :rest | :custom` is an atom enum. This is idiomatic for exhaustive pattern matching in Phoenix controllers/LiveViews, but `:custom` is a catch-all that will absorb everything non-standard. As more integrations are added (Linear, GitHub, A2A), this list will expand.

**Recommendation**: Keep the type for dashboard categorization but expand to a `String.t()` in the long run, or use a more extensible atom convention like `:ag_ui | :rest | :websocket | :grpc | :custom`. A typespec with `@type protocol_type :: atom()` (documented) is more forward-compatible.

#### Reconnection/backoff — Not addressed

Neither `connect/1` nor `disconnect/0` has any provision for reconnection logic, exponential backoff, or circuit-breaking. For the AgentLock and AG-UI integrations (which are always-on), this is deferred to the integration's own GenServer. That is the correct decision — backoff logic belongs in a supervised GenServer, not a behaviour callback.

**Recommended minimal contract** (removing over-engineered parts):

```elixir
@callback integration_name() :: String.t()
@callback integration_description() :: String.t()
@callback integration_version() :: String.t()
@callback protocol() :: :ag_ui | :rest | :websocket | :custom
@callback connect(config :: map()) :: {:ok, term()} | {:error, term()}
@callback disconnect() :: :ok
@callback status() :: :connected | :disconnected | :degraded | :initializing
@callback list_endpoints() :: [map()]
@callback handle_event(event_type :: String.t(), payload :: map(), opts :: keyword()) ::
            {:ok, map()} | {:error, term()}
@callback supervisor_children() :: [Supervisor.child_spec()]

@optional_callbacks [inspector_section: 1, supervisor_children: 0]
# Remove: on_connect_callback/1, on_disconnect_callback/0
```

---

## 3. PluginRegistry ETS Design

### Verdict: Functionally correct, three improvements needed

#### `:ets.tab2list/1` + `Enum.sort_by/2` — Acceptable but inefficient at scale

`tab2list/1` copies the entire ETS table to a list on each call. For a plugin registry holding 5–15 entries, this is negligible. At the current scale this is fine. The concern is that `list_plugins/0` is a public API callable from LiveViews on every render cycle.

If the plugin count grows significantly (e.g., user-installed plugins in v9+), an `:ordered_set` ETS table keyed by plugin name would return entries in sorted order without a post-sort. However, ETS `:ordered_set` uses binary ordering on the key, which for `String.t()` keys matches alphabetical sort — the exact sort order `list_plugins/0` uses today. Switching to `:ordered_set` would allow removing the `Enum.sort_by` call.

**Recommendation (P2)**: Change ETS type to `:ordered_set` and remove `Enum.sort_by`. The net result is the same output with slightly better read performance for large registries.

#### `Code.ensure_loaded/1` placement — Correct but return value ignored

`Code.ensure_loaded(module)` returns `{:module, module}` on success or `{:error, reason}` on failure (e.g., module not found). The current code ignores the return value entirely:

```elixir
# Current — return value ignored
Code.ensure_loaded(module)

with true <- function_exported?(module, :plugin_name, 0),
     ...
```

If `Code.ensure_loaded/1` returns `{:error, :nofile}`, `function_exported?/3` will return `false` and the registration will fail with the opaque `:invalid_plugin_behaviour` error. The caller cannot distinguish "module doesn't exist" from "module exists but doesn't implement the behaviour."

**Recommendation (P1)**:

```elixir
defp do_register(module) do
  with {:module, ^module} <- Code.ensure_loaded(module),
       true <- function_exported?(module, :plugin_name, 0),
       true <- function_exported?(module, :plugin_description, 0),
       true <- function_exported?(module, :plugin_version, 0),
       true <- function_exported?(module, :list_endpoints, 0),
       true <- function_exported?(module, :handle_action, 3) do
    ...
  else
    {:error, reason} -> {:error, {:module_load_failed, module, reason}}
    false -> {:error, :invalid_plugin_behaviour}
  end
end
```

#### `function_exported?/3` guards vs `@behaviour` — Runtime check is not a compile-time guarantee

The `function_exported?/3` guard in `do_register/1` and `do_register/1` in `IntegrationRegistry` re-implements what `@behaviour` + `@impl true` does at compile time. The runtime check is a safety net for externally loaded plugins, but for the bundled default plugins it is redundant. The bundled plugins (`@default_plugins`) already declare `@behaviour ApmV5.Plugins.PluginBehaviour`, which will cause a compile-time warning if a required callback is missing.

**Recommendation (P3)**: Document in both registries that the `function_exported?` guard is specifically for runtime-loaded (external/user) plugins. Add a comment making this intent explicit.

#### `try/rescue` in `call_plugin_action/3` — Correct defensive pattern

The `try/rescue` around `mod.handle_action/3` is correct for a plugin boundary — plugins are untrusted code. No change recommended.

---

## 4. Supervision Tree OTP Boundaries

### Verdict: Four structural problems in application.ex

#### Problem 1: PluginRegistry before AuthSupervisor — dependency ordering violation

In `application.ex`, `ApmV5.Plugins.PluginRegistry` is started before `ApmV5.Supervisors.AuthSupervisor`. The PlanePlugin calls `ApmV5.PlaneClient` (HTTP, no GenServer deps), so this works today. But `FormationsPlugin` calls `ApmV5.UpmStore` and `ApmV5.AgentRegistry`, both of which are in `CoreSupervisor` (started earlier). The UatPlugin calls `ApmV5.Intake.Store` which is under `IntakeSupervisor` (started earlier).

Current accidental ordering happens to work, but it is fragile. If any plugin's `plugin_name/0` (called during registration) touches a process not yet started, you get a silent failure.

**Recommendation (P1)**: PluginRegistry should be started **after** all store/registry GenServers it depends on. The correct placement is after `ApmV5.ClaudeUsageStore` and before `ApmV5.Supervisors.AuthSupervisor`. Add a comment in `application.ex` documenting the ordering dependency.

#### Problem 2: No PluginSupervisor

The PluginRegistry is a GenServer that stores metadata in ETS. Plugin children (`supervisor_children/0`) are never started. For the current plugins that return `[]`, this is fine. For future plugins with GenServer-backed state (e.g., a `PortsPlugin` that wraps `PortManager`), there must be a dedicated `PluginSupervisor` that:

1. Is a `DynamicSupervisor` (to support enable/disable at runtime)
2. Is started **before** PluginRegistry in the supervision tree (so children can be started when plugins register)
3. Receives `supervisor_children/0` return values from PluginRegistry's `do_register/1`

**Recommendation (P1)**: Introduce `ApmV5.Supervisors.PluginSupervisor` as a `DynamicSupervisor`. PluginRegistry calls `DynamicSupervisor.start_child/2` for each child spec returned by `supervisor_children/0` during registration.

Proposed supervision tree addition:
```
application.ex children:
  ...
  ApmV5.Supervisors.CoreSupervisor,
  ...stores...
  ApmV5.Plugins.PluginSupervisor,   # DynamicSupervisor — BEFORE PluginRegistry
  ApmV5.Plugins.PluginRegistry,     # starts children via PluginSupervisor
  ApmV5.Integrations.IntegrationSupervisor,  # DynamicSupervisor — BEFORE IntegrationRegistry
  ApmV5.Integrations.IntegrationRegistry,
  ApmV5.Supervisors.AuthSupervisor,
  ...
```

#### Problem 3: IntegrationRegistry is not in the supervision tree

`ApmV5.Integrations.IntegrationRegistry` exists in `lib/apm_v5/integrations/integration_registry.ex` but is **absent from `application.ex`**. It will never start. This is a Wave 1 stub (the module comment says `@default_integrations []`), but it must be added before Wave 3 extraction of AG-UI and AgentLock integrations can proceed.

**Recommendation (P1)**: Add `ApmV5.Integrations.IntegrationRegistry` to `application.ex` after `ApmV5.Plugins.PluginRegistry`.

#### Problem 4: Flat top-level list — ~20 direct children of the root supervisor

The root `ApmV5.Supervisor` in `application.ex` currently has approximately 22 direct children. OTP best practice is to keep supervisor children to 5–10 max for clarity and to allow meaningful restart strategies. The existing `CoreSupervisor`, `AgUiSupervisorGroup`, and `AuthSupervisor` sub-supervisors are good starts. The remaining flat GenServers should be grouped.

Suggested sub-supervisors for v8:
- `ApmV5.Supervisors.ObservabilitySupervisor` — MetricsCollector, SloEngine, AnalyticsStore, HealthCheckRunner
- `ApmV5.Supervisors.DevOpsSupervisor` — BackgroundTasksStore, ProjectScanner, ActionEngine, SkillHookDeployer, SkillTracker, ConversationWatcher
- `ApmV5.Supervisors.PluginSupervisor` (DynamicSupervisor, as above)
- `ApmV5.Supervisors.IntegrationSupervisor` (DynamicSupervisor, as above)

#### AuthSupervisor placement — Correct

`AuthSupervisor` at the tail of the list (just before `ApmV5Web.Endpoint`) is correct: auth depends on PubSub, CoreSupervisor stores, and AG-UI, all of which are started earlier.

#### AgUiSupervisorGroup — Structural concern

`AgUiSupervisorGroup` contains `ApmV5.AgUiSupervisor` as its first child, which is itself a supervisor. This creates a three-level nesting: `Application → AgUiSupervisorGroup → AgUiSupervisor → [children]`. This is valid OTP but the extra wrapper level (`AgUiSupervisorGroup`) adds complexity without a clear benefit over using `AgUiSupervisor` directly at the top level. The group exists to collect all AG-UI GenServers, including bridge/tracker/health modules that are not in `AgUiSupervisor`.

**Recommendation (P3)**: Flatten `AgUiSupervisorGroup` — absorb all its children into `AgUiSupervisor` directly. Remove `AgUiSupervisorGroup` as a layer.

---

## 5. Plugin vs Integration Split — OTP Correctness

### Verdict: The split is correct; one boundary case to watch

The Plugin/Integration dichotomy is the right OTP boundary. Plugins are **internal APM features** (self-contained, no external network dependency at the boundary contract level). Integrations are **external protocol bridges** (bidirectional, connection lifecycle, potentially long-running persistent connections). The distinction maps cleanly to different supervision strategies:

- Plugins: `:one_for_one` under a static or `DynamicSupervisor`
- Integrations: Connection-aware, may need `:rest_for_one` if an integration's child processes are sequentially dependent (e.g., connect then subscribe)

#### The boundary case: PlanePlugin

`PlanePlugin` wraps `ApmV5.PlaneClient` which makes HTTP calls. It has no supervised processes and no persistent connection — it is stateless. This is correct as a Plugin. However, if future iterations add a Plane webhook receiver (inbound events from Plane), that would cross into Integration territory. The naming of the module path (`lib/apm_v5/plugins/plane/plane_plugin.ex`) would need to change to `integrations/plane/`.

This is not a problem today but should be documented as a known boundary.

#### Single behaviour with `type/0` — Wrong direction

Using a single behaviour with `type/0 :: :plugin | :integration` would conflate two meaningfully different contracts. Plugins don't need `connect/1`, `disconnect/0`, or `status/0`. Integrations don't need `default_enabled?/0` in the same way (integrations are either connected or not, not "enabled/disabled" as a feature toggle). The split into two behaviours is the correct design.

#### Module dependency awkwardness

`FormationsPlugin` delegates directly to `ApmV5.UpmStore` and `ApmV5.AgentRegistry` via direct `alias` and function calls. This is a **direct dependency on a Foundation module**, which is by design — plugins are allowed to call Foundation modules. The awkwardness arises when the plugin is "disabled": the Foundation module (`UpmStore`) is still running, but the plugin's REST surface is gone. Disabling a plugin does not and should not stop its underlying GenServers (they may be shared with other parts of the system).

This is the correct behavior. It just needs to be documented explicitly in the PluginBehaviour `@moduledoc`.

---

## 6. Anti-Patterns Found

### Missing `@spec` annotations

**`PluginBehaviour`**: Callbacks have `@callback` type specs (correct). No missing specs.

**`PlanePlugin`**: No `@spec` on private helpers (`extract_results/1`, `normalize_issues/1`, `normalize_issue/1`). Private functions don't require specs but given the CLAUDE.md standards, they should have them for Dialyzer.

**`FormationsPlugin`**: Public `handle_action/3` has `@spec` (correct). No issues.

**`PluginRegistry`**: `do_register/1` has no `@spec`. It is private but is called in `handle_info` and `handle_call` — Dialyzer will infer the type but an explicit `@spec do_register(module()) :: :ok | {:error, term()}` is appropriate.

**`IntegrationRegistry`**: `safe_status/1` has `@spec safe_status(module()) :: atom()` (correct). `do_register/1` has `@spec do_register(module()) :: :ok | {:error, term()}` (correct).

### Unhandled error in `FormationsPlugin.handle_action("update_formation")`

```elixir
# Current
case UpmStore.update_formation(id, attrs) do
  {:ok, formation} -> {:ok, formation}
  {:error, reason} -> {:error, reason}
  nil -> {:error, {:not_found, "Formation #{id} not found"}}
end
```

`UpmStore.update_formation/2` returning `nil` in a `case` match is not a tagged tuple pattern — it will only match if the function actually returns bare `nil`, not `{:ok, nil}`. If `UpmStore.update_formation/2` returns `{:ok, nil}` (indicating update of a non-existent record with no error), this clause will not match and a `CaseClauseError` will be raised. This needs verification against the `UpmStore` implementation.

### `try/rescue` around `module.status()` in `IntegrationRegistry.safe_status/1`

Using `rescue` for control flow is an anti-pattern in Elixir. If `status/0` might raise, the integration module should handle that internally and return a tagged value. The current pattern is acceptable as a defensive measure for untrusted external modules, but it should be documented as such. Consider using `apply/3` and matching on `{:EXIT, _}` via a `Task` for stricter isolation.

### `inspect_section/1` returns `map()` — missing XSS guard

The `@callback inspector_section(assigns :: map()) :: map()` has no specification that the `:html` value is `Phoenix.HTML.safe()`. Any plugin that returns a raw string in `:html` will be vulnerable to XSS if rendered without `raw/1`. **This is a security concern.** The callback should either specify `Phoenix.HTML.safe()` as the type for the `:html` value, or be replaced with the component pattern described in Section 1.

### Blocking `:inets.start()` / `:ssl.start()` in `Application.start/2`

```elixir
:inets.start()
:ssl.start()
```

These are synchronous calls in the application start callback. Both `:inets` and `:ssl` are OTP applications that should be listed in `extra_applications` in `mix.exs` and started by OTP's application controller, not manually. Manual starts like this create a race: if they fail, the application start may proceed in an undefined state. The current `extra_applications: [:logger, :runtime_tools]` in `mix.exs` should include `:inets` and `:ssl`.

### `ApmV5.AgUi.LifecycleMapper.init_tables()` called before supervision tree

```elixir
ApmV5.AgUi.LifecycleMapper.init_tables()
```

This creates ETS tables outside the supervision tree. If the process calling `Application.start/2` dies (which it won't in normal operation, but can in tests), those ETS tables are owned by the wrong process and will be garbage collected. ETS tables with `:public` access should be created by a named, supervised GenServer and owned by that process. This is a known OTP pitfall.

---

## 7. Concrete Recommendations

### P1 — Must fix before v8.0.0 ships

**P1.1 — Add PluginSupervisor (DynamicSupervisor) to the tree**

Create `lib/apm_v5/supervisors/plugin_supervisor.ex`:
```elixir
defmodule ApmV5.Supervisors.PluginSupervisor do
  @moduledoc "DynamicSupervisor for plugin-owned child processes."
  use DynamicSupervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @spec start_plugin_children([Supervisor.child_spec()]) :: [:ok | {:error, term()}]
  def start_plugin_children(child_specs) do
    Enum.map(child_specs, &DynamicSupervisor.start_child(__MODULE__, &1))
  end
end
```

Add to `application.ex` before `ApmV5.Plugins.PluginRegistry`.

**P1.2 — Add IntegrationRegistry to supervision tree**

In `application.ex`, add after `ApmV5.Plugins.PluginRegistry`:
```elixir
ApmV5.Integrations.IntegrationRegistry,
```

Also create a corresponding `ApmV5.Supervisors.IntegrationSupervisor` (DynamicSupervisor) and add it before `IntegrationRegistry`.

**P1.3 — Fix Code.ensure_loaded/1 return value handling**

In both `PluginRegistry.do_register/1` and `IntegrationRegistry.do_register/1`, pattern match the return:
```elixir
with {:module, ^module} <- Code.ensure_loaded(module),
     true <- function_exported?(module, :plugin_name, 0),
     ...
else
  {:error, reason} -> {:error, {:module_load_failed, module, reason}}
  false -> {:error, :invalid_plugin_behaviour}
end
```

**P1.4 — Replace `inspector_section/1` with `inspector_component/0`**

Change in `PluginBehaviour`:
```elixir
# Remove:
@callback inspector_section(assigns :: map()) :: map()

# Add:
@doc """
Optional. Returns a Phoenix.LiveComponent module to embed in the inspector panel.
The component will receive the current plugin assigns. Return nil if not implemented.
"""
@callback inspector_component() :: module() | nil
@optional_callbacks [inspector_component: 0, supervisor_children: 0, live_views: 0, ...]
```

Apply the same change to `IntegrationBehaviour`.

**P1.5 — Move `:inets` and `:ssl` to `extra_applications`**

In `mix.exs`:
```elixir
def application do
  [
    mod: {ApmV5.Application, []},
    extra_applications: [:logger, :runtime_tools, :inets, :ssl]
  ]
end
```

Remove the manual `Application.start/2` calls.

### P2 — Should fix in v8.0.0 or v8.1.0

**P2.1 — Switch ETS table type to `:ordered_set`**

In both `PluginRegistry.init/1` and `IntegrationRegistry.init/1`:
```elixir
table = :ets.new(@table, [:named_table, :public, :ordered_set, read_concurrency: true])
```

Remove `Enum.sort_by` from `list_plugins/0` and `list_integrations/0`.

**P2.2 — Remove `on_connect_callback/1` and `on_disconnect_callback/0` from IntegrationBehaviour**

They are redundant with `connect/1` and `disconnect/0`. Removing them now before any integrations implement them costs nothing.

**P2.3 — Remove `live_views/0` from PluginBehaviour**

Replace with documented convention: plugins using LiveViews mount under `/plugins/:plugin_name/` via a single `PluginRouteLive` dispatcher that reads from the registry at runtime.

**P2.4 — Add `enabled` field to ETS metadata in PluginRegistry**

Read `default_enabled?()` during registration (with `function_exported?/3` guard fallback to `true`). Store `enabled: boolean()` in the metadata map. Add `enable_plugin/1` and `disable_plugin/1` public API functions.

**P2.5 — Group remaining flat children in application.ex**

Introduce `ObservabilitySupervisor` and `DevOpsSupervisor` sub-supervisors to reduce root supervisor children from ~22 to ~10.

### P3 — Nice to have / future work

**P3.1 — Document `function_exported?` intent in registries**

Add a comment clarifying the guards are for runtime-loaded (user/external) plugins; bundled plugins are already validated by the compiler via `@behaviour`.

**P3.2 — Add `@spec` to `PlanePlugin` private helpers**

Add `@spec` to `extract_results/1`, `normalize_issues/1`, `normalize_issue/1` for Dialyzer coverage.

**P3.3 — Flatten `AgUiSupervisorGroup`**

Absorb all children directly into `AgUiSupervisor` and remove the `AgUiSupervisorGroup` wrapper layer.

**P3.4 — Fix `LifecycleMapper.init_tables/0` ETS ownership**

Move ETS table creation into a supervised GenServer `init/1` to ensure proper process ownership and cleanup on process death.

**P3.5 — Verify FormationsPlugin nil match in `update_formation`**

Audit `ApmV5.UpmStore.update_formation/2` return contract. If it returns `{:ok, nil}` for not-found, update the `case` clause to match `{:ok, nil}` instead of bare `nil`.

---

## Summary Matrix

| Area | Status | Priority |
|------|--------|----------|
| PluginBehaviour core callbacks | Correct | — |
| `supervisor_children/0` never consumed | Gap | P1 (PluginSupervisor) |
| `live_views/0` Phoenix incompatibility | Anti-pattern | P2 (remove) |
| `inspector_section/1` XSS risk | Security | P1 (replace with component) |
| `on_enable/0` has no call site | Gap | P2 (add call sites + config arg) |
| `default_enabled?` not read at registration | Gap | P2 |
| IntegrationBehaviour redundant callbacks | Over-engineered | P2 (remove) |
| `Code.ensure_loaded` return ignored | Bug | P1 |
| ETS `:set` vs `:ordered_set` | Minor perf | P2 |
| IntegrationRegistry not in supervision tree | Bug | P1 |
| No PluginSupervisor | Architecture gap | P1 |
| ~22 flat root supervisor children | Code quality | P2 |
| `:inets`/`:ssl` manual start in Application | Anti-pattern | P1 |
| `LifecycleMapper.init_tables()` before tree | OTP anti-pattern | P3 |
| AgUiSupervisorGroup extra nesting | Code quality | P3 |
| Missing `@spec` on private helpers | Code quality | P3 |
| `update_formation` nil match risk | Potential bug | P3 (audit) |
