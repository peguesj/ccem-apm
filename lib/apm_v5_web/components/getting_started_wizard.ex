defmodule ApmV5Web.Components.GettingStartedWizard do
  @moduledoc """
  Getting Started Wizard — split-column modal overlay for page-contextual onboarding.

  Split layout: 40% animated SVG illustration panel (left) + 60% slide content (right).
  Slide sets are keyed by `page` attribute, defaulting to "welcome".
  Dismissal is purely client-side via LocalStorage key `ccem_wizard_shown_<page>`.
  Keyboard arrows navigate slides; Escape dismisses.
  No Lottie dependency — uses CSS-animated inline SVG illustrations.
  """

  use Phoenix.Component

  @slide_sets %{
    "welcome" => [
      %{
        title: "Welcome to CCEM APM",
        subtitle: "Your Agentic Performance Monitor",
        body: "CCEM APM gives you real-time visibility into your AI agent fleet. Monitor performance, manage resources, and orchestrate complex multi-agent formations — all from a single dashboard.",
        features: ["Real-time agent fleet status", "Formation orchestration", "Token & performance telemetry"],
        illustration: "monitoring"
      },
      %{
        title: "Monitor Agents",
        subtitle: "Live heartbeats and status",
        body: "Every agent self-registers via the REST API and sends periodic heartbeats. Color-coded status indicators update in real time so you always know what's running.",
        features: ["Self-registration API", "Live heartbeat tracking", "Project-level grouping"],
        illustration: "agents"
      },
      %{
        title: "Formation Orchestration",
        subtitle: "Hierarchical agent deployment",
        body: "Deploy squadrons organized into formations. Each formation executes in waves with automatic gating. Visualize progress in the formation graph view.",
        features: ["Squadron / Swarm / Cluster hierarchy", "Wave-based execution", "Formation graph visualization"],
        illustration: "formation"
      },
      %{
        title: "Real-Time Updates",
        subtitle: "Always current, zero polling",
        body: "The dashboard uses Phoenix LiveView and PubSub to push updates directly to your browser. No manual refresh needed — everything streams live.",
        features: ["Phoenix LiveView WebSocket", "PubSub event streaming", "AG-UI protocol events"],
        illustration: "realtime"
      }
    ],
    "dashboard" => [
      %{
        title: "Dashboard Overview",
        subtitle: "Your command center",
        body: "The main dashboard aggregates your entire agent fleet, active formations, notifications, and telemetry into one real-time view.",
        features: ["Agent fleet summary", "Active formation status", "Notification toasts"],
        illustration: "monitoring"
      },
      %{
        title: "Dependency Graph",
        subtitle: "Agentic hierarchy visualized",
        body: "The dependency graph renders your Session → Formation → Squadron → Swarm → Agent → Task hierarchy using D3.js. Click any node to inspect it.",
        features: ["D3.js force-directed graph", "Click-to-inspect nodes", "Live edge updates"],
        illustration: "formation"
      }
    ],
    "agents" => [
      %{
        title: "Agent Monitoring",
        subtitle: "Track every agent in your fleet",
        body: "The agents view shows every registered agent with live status, heartbeat timing, project assignment, and formation membership.",
        features: ["Live status badges", "Heartbeat timing", "Formation membership"],
        illustration: "agents"
      },
      %{
        title: "Agent Control",
        subtitle: "Connect, disconnect, restart",
        body: "Use the agent control panel to connect, disconnect, restart, or pause agents. Send messages via the contextual chat panel without leaving the view.",
        features: ["Connect / Disconnect / Restart", "Contextual chat panel", "Bulk selection actions"],
        illustration: "actions"
      }
    ],
    "formation" => [
      %{
        title: "Formation Visualization",
        subtitle: "Hierarchical deployment at a glance",
        body: "Formations organize agents into squadrons, swarms, and clusters. The formation graph shows every node in the hierarchy with live status color coding.",
        features: ["Squadron / Swarm / Cluster hierarchy", "Wave progress tracking", "Deep-link from notifications"],
        illustration: "formation"
      },
      %{
        title: "Deploy a Formation",
        subtitle: "Use /formation deploy",
        body: "Run `/formation deploy` in Claude Code to launch a full formation. Agents register automatically and appear in this view within seconds.",
        features: ["Auto-registration via API", "Wave-based gating", "Real-time progress updates"],
        illustration: "realtime"
      }
    ],
    "ag-ui" => [
      %{
        title: "AG-UI Event Stream",
        subtitle: "Open agent-user interaction protocol",
        body: "The AG-UI view streams live protocol events from your agents. Filter by event type, inspect payloads, and watch agent state transitions in real time.",
        features: ["33 AG-UI event types", "Live payload inspector", "Agent state viewer"],
        illustration: "realtime"
      },
      %{
        title: "Event Types",
        subtitle: "Lifecycle, state, activity, and more",
        body: "Events cover the full agent lifecycle: RUN_STARTED, TOOL_CALL, STATE_DELTA, TEXT_MESSAGE, and 29 more. CCEM APM maps APM hooks to AG-UI events automatically.",
        features: ["Lifecycle events", "Tool call tracing", "State delta streaming"],
        illustration: "agents"
      }
    ],
    "showcase" => [
      %{
        title: "Project Showcase",
        subtitle: "GIMME-style interactive diagrams",
        body: "The showcase renders C4-abstracted SVG architecture diagrams for your project. IP-safe by design — no proprietary details exposed in the visual layer.",
        features: ["C4 abstraction layers", "Anime.js animations", "WCAG AA compliant"],
        illustration: "monitoring"
      },
      %{
        title: "Showcase Navigation",
        subtitle: "Switch projects, go fullscreen",
        body: "Use the project picker to switch between showcases. Hit the fullscreen button to cover the APM chrome entirely. Press Esc to exit fullscreen.",
        features: ["Multi-project support", "Fullscreen mode", "Live APM data overlay"],
        illustration: "actions"
      }
    ],
    "ports" => [
      %{
        title: "Port Management",
        subtitle: "Detect and resolve port conflicts",
        body: "The ports view lists every registered port across your projects. Conflict detection highlights clashes with color-coded severity, and smart reassignment resolves them automatically.",
        features: ["Conflict detection", "Utilization heatmap", "Smart port reassignment"],
        illustration: "ports"
      },
      %{
        title: "Port Actions",
        subtitle: "Automated port intelligence",
        body: "Use the action engine port actions to register all ports in bulk, analyze assignments, or trigger smart reassignment across your entire project namespace.",
        features: ["register_all_ports", "analyze_port_assignment", "smart_reassign_ports"],
        illustration: "actions"
      }
    ],
    "actions" => [
      %{
        title: "Action Engine",
        subtitle: "Automated maintenance tasks",
        body: "The action engine runs catalogued maintenance tasks: updating hooks, adding memory pointers, backfilling APM config, analyzing projects, and managing ports.",
        features: ["Async task execution", "Run history log", "Result inspection panel"],
        illustration: "actions"
      },
      %{
        title: "Running Actions",
        subtitle: "One-click execution",
        body: "Click any action card to open the run modal. Provide optional parameters, then submit. The action runs asynchronously and results appear in the recent runs table.",
        features: ["Modal parameter entry", "Async execution", "Result detail view"],
        illustration: "tasks"
      }
    ],
    "tasks" => [
      %{
        title: "Background Tasks",
        subtitle: "Track Claude Code processes",
        body: "The tasks view tracks every background process spawned by Claude Code. See name, definition, invoking process, project, status, PID, and runtime in one table.",
        features: ["Live status updates", "Log viewer", "Stop / Delete controls"],
        illustration: "tasks"
      },
      %{
        title: "Task Logs",
        subtitle: "In-browser log streaming",
        body: "Click Logs on any task to open the log viewer modal. Log lines stream in real time from the background process, making it easy to diagnose issues without leaving the dashboard.",
        features: ["Real-time log streaming", "Modal log viewer", "Scrollable output"],
        illustration: "realtime"
      }
    ],
    "scanner" => [
      %{
        title: "Project Scanner",
        subtitle: "Discover your dev environment",
        body: "The scanner crawls configured directories and detects projects by stack signature. Each project shows its framework, active ports, agent count, and CLAUDE.md sections.",
        features: ["Stack auto-detection", "Active port listing", "Agent count per project"],
        illustration: "agents"
      },
      %{
        title: "Scanner Configuration",
        subtitle: "Set scan paths",
        body: "Configure the scanner path via the path input. Trigger a manual scan or let the 3-second auto-refresh keep the list current as you work.",
        features: ["Configurable scan path", "Manual trigger", "3s auto-refresh"],
        illustration: "monitoring"
      }
    ],
    "skills" => [
      %{
        title: "Skills Registry",
        subtitle: "Health dashboard for your skills",
        body: "The skills registry tracks every installed skill across three health tiers: healthy (score ≥ 80), needs attention (50–79), and critical (<50).",
        features: ["Three-tier health scoring", "Audit All action", "Per-skill fix button"],
        illustration: "agents"
      },
      %{
        title: "Skill Health Scores",
        subtitle: "Computed from metadata quality",
        body: "Health scores combine: valid frontmatter, description quality, trigger coverage, project memory entries, and hook wiring. Fix issues with one click via the action engine.",
        features: ["Frontmatter validation", "Description quality", "Trigger coverage"],
        illustration: "tasks"
      }
    ],
    "notifications" => [
      %{
        title: "Notifications",
        subtitle: "Tabbed event categories",
        body: "The notifications panel groups events into tabs: All, Agents, Formations, Skills, and Ship. Each card shows severity, timestamp, project, and formation context.",
        features: ["Tabbed categories", "Severity badges", "Formation deep-links"],
        illustration: "realtime"
      },
      %{
        title: "Notification Details",
        subtitle: "Click to expand",
        body: "Click any notification card to expand the detail view. See the full payload, story ID, squadron ID, namespace, and project name in a structured layout.",
        features: ["Expandable detail view", "Full payload display", "Context metadata"],
        illustration: "monitoring"
      }
    ],
    "upm" => [
      %{
        title: "UPM — Unified Project Management",
        subtitle: "PM adapter integration hub",
        body: "UPM connects CCEM APM to your project management tools. Sync issues from Plane, Linear, Jira, or Monday. Drift detection flags work items that have fallen out of sync.",
        features: ["Plane / Linear / Jira / Monday adapters", "Drift detection", "Auto-sync every 5 minutes"],
        illustration: "agents"
      },
      %{
        title: "Kanban Board",
        subtitle: "Live work item tracking",
        body: "The UPM board view renders a Kanban board from your synced work items. Columns map to PM states. Click any card to see full issue detail.",
        features: ["Kanban board layout", "PM state columns", "Issue detail panel"],
        illustration: "formation"
      }
    ]
  }

  attr :page, :string, default: "welcome"
  attr :class, :string, default: ""
  attr :dom_id, :string, default: nil

  def wizard(assigns) do
    slides = Map.get(@slide_sets, assigns.page, @slide_sets["welcome"])
    dom_id = assigns.dom_id || "ccem-wizard-#{assigns.page}"
    assigns =
      assigns
      |> assign(:slides, slides)
      |> assign(:slide_count, length(slides))
      |> assign(:dom_id, dom_id)

    ~H"""
    <style>
      @keyframes wizard-block-enter {
        from { opacity: 0; transform: translateX(-20px); }
        to   { opacity: 1; transform: translateX(0); }
      }
      @keyframes wizard-pulse {
        0%, 100% { transform: scale(1); opacity: 1; }
        50%       { transform: scale(1.4); opacity: 0.5; }
      }
      @keyframes wizard-cursor-click {
        0%, 100% { transform: scale(1); }
        50%       { transform: scale(0.85); }
      }
      @keyframes wizard-select-sweep {
        from { width: 0; }
        to   { width: 100%; }
      }
      @keyframes wizard-fade-in {
        from { opacity: 0; transform: translateY(8px); }
        to   { opacity: 1; transform: translateY(0); }
      }
      @keyframes wizard-wave-slide {
        0%   { transform: translateX(-100%); }
        100% { transform: translateX(100%); }
      }
      @keyframes wizard-node-pop {
        0%   { transform: scale(0.5); opacity: 0; }
        60%  { transform: scale(1.15); }
        100% { transform: scale(1); opacity: 1; }
      }
      @keyframes wizard-spin-slow {
        from { transform: rotate(0deg); }
        to   { transform: rotate(360deg); }
      }
      .wizard-block-1 { animation: wizard-block-enter 0.4s ease both; }
      .wizard-block-2 { animation: wizard-block-enter 0.4s 0.1s ease both; }
      .wizard-block-3 { animation: wizard-block-enter 0.4s 0.2s ease both; }
      .wizard-block-4 { animation: wizard-block-enter 0.4s 0.3s ease both; }
      .wizard-pulse-dot { animation: wizard-pulse 1.8s ease-in-out infinite; }
      .wizard-pulse-dot-2 { animation: wizard-pulse 1.8s 0.6s ease-in-out infinite; }
      .wizard-pulse-dot-3 { animation: wizard-pulse 1.8s 1.2s ease-in-out infinite; }
      .wizard-cursor { animation: wizard-cursor-click 1.4s ease-in-out infinite; }
      .wizard-sweep { animation: wizard-select-sweep 1.6s 0.5s ease infinite alternate; }
      .wizard-node-1 { animation: wizard-node-pop 0.4s ease both; }
      .wizard-node-2 { animation: wizard-node-pop 0.4s 0.15s ease both; }
      .wizard-node-3 { animation: wizard-node-pop 0.4s 0.3s ease both; }
      .wizard-node-4 { animation: wizard-node-pop 0.4s 0.45s ease both; }
      .wizard-node-5 { animation: wizard-node-pop 0.4s 0.6s ease both; }
      .wizard-spin { animation: wizard-spin-slow 4s linear infinite; }
      .wizard-feature-item { animation: wizard-fade-in 0.3s ease both; }
      .wizard-feature-item:nth-child(1) { animation-delay: 0.1s; }
      .wizard-feature-item:nth-child(2) { animation-delay: 0.2s; }
      .wizard-feature-item:nth-child(3) { animation-delay: 0.3s; }
      @media (prefers-reduced-motion: reduce) {
        .wizard-block-1, .wizard-block-2, .wizard-block-3, .wizard-block-4,
        .wizard-pulse-dot, .wizard-pulse-dot-2, .wizard-pulse-dot-3,
        .wizard-cursor, .wizard-sweep,
        .wizard-node-1, .wizard-node-2, .wizard-node-3, .wizard-node-4, .wizard-node-5,
        .wizard-spin, .wizard-feature-item { animation: none !important; }
      }
    </style>

    <div
      id={@dom_id}
      data-wizard-page={@page}
      data-wizard-total={@slide_count}
      style="display:none;"
      phx-update="ignore"
      class={[
        "fixed inset-0 z-50 flex items-center justify-center",
        @class
      ]}
      role="dialog"
      aria-modal="true"
      aria-label={"Getting started: #{@page}"}
    >
      <%!-- Backdrop --%>
      <div
        class="absolute inset-0 bg-black/75 backdrop-blur-sm"
        data-wizard-dismiss
        aria-hidden="true"
      ></div>

      <%!-- Modal — split layout --%>
      <div class="relative w-full max-w-4xl mx-4 bg-base-200 rounded-2xl shadow-2xl border border-base-300 overflow-hidden flex flex-col">
        <%!-- Header --%>
        <div class="flex items-center justify-between px-6 py-3 border-b border-base-300 flex-shrink-0">
          <div class="flex items-center gap-3">
            <div class="w-7 h-7 rounded-md bg-primary/15 flex items-center justify-center">
              <svg xmlns="http://www.w3.org/2000/svg" class="w-4 h-4 text-primary" viewBox="0 0 20 20" fill="currentColor">
                <path fill-rule="evenodd" d="M11.3 1.046A1 1 0 0112 2v5h4a1 1 0 01.82 1.573l-7 10A1 1 0 018 18v-5H4a1 1 0 01-.82-1.573l7-10a1 1 0 011.12-.38z" clip-rule="evenodd" />
              </svg>
            </div>
            <div>
              <h2 class="text-sm font-semibold text-base-content leading-none">Getting Started</h2>
              <p class="text-[10px] text-base-content/40 mt-0.5">CCEM APM</p>
            </div>
          </div>
          <div class="flex items-center gap-3">
            <span data-wizard-counter class="text-xs text-base-content/40 font-mono tabular-nums">1 / <%= @slide_count %></span>
            <button
              data-wizard-dismiss
              class="btn btn-ghost btn-sm btn-circle"
              aria-label="Close wizard"
            >
              <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" viewBox="0 0 20 20" fill="currentColor">
                <path fill-rule="evenodd" d="M4.293 4.293a1 1 0 011.414 0L10 8.586l4.293-4.293a1 1 0 111.414 1.414L11.414 10l4.293 4.293a1 1 0 01-1.414 1.414L10 11.414l-4.293 4.293a1 1 0 01-1.414-1.414L8.586 10 4.293 5.707a1 1 0 010-1.414z" clip-rule="evenodd" />
              </svg>
            </button>
          </div>
        </div>

        <%!-- Slide content area --%>
        <div data-wizard-slides class="flex-1 min-h-[320px]">
          <%= for {slide, idx} <- Enum.with_index(@slides) do %>
            <div
              data-wizard-slide={idx}
              class={["wizard-slide flex h-full", if(idx != 0, do: "hidden", else: "")]}
            >
              <%!-- Left column: illustration (40%) --%>
              <div class="w-2/5 flex-shrink-0 bg-base-300/60 border-r border-base-300 flex items-center justify-center p-6">
                <%= illustration(slide.illustration) %>
              </div>

              <%!-- Right column: content (60%) --%>
              <div class="flex-1 flex flex-col justify-center px-8 py-8">
                <h3 class="text-xl font-bold text-base-content mb-1 leading-tight"><%= slide.title %></h3>
                <p class="text-xs text-primary font-medium mb-4 uppercase tracking-wide"><%= slide.subtitle %></p>
                <p class="text-sm text-base-content/70 leading-relaxed mb-6"><%= slide.body %></p>
                <ul class="space-y-2">
                  <%= for feature <- slide.features do %>
                    <li class="wizard-feature-item flex items-center gap-2 text-sm text-base-content/80">
                      <span class="w-4 h-4 rounded-full bg-primary/20 flex items-center justify-center flex-shrink-0">
                        <svg xmlns="http://www.w3.org/2000/svg" class="w-2.5 h-2.5 text-primary" viewBox="0 0 20 20" fill="currentColor">
                          <path fill-rule="evenodd" d="M16.707 5.293a1 1 0 010 1.414l-8 8a1 1 0 01-1.414 0l-4-4a1 1 0 011.414-1.414L8 12.586l7.293-7.293a1 1 0 011.414 0z" clip-rule="evenodd" />
                        </svg>
                      </span>
                      <%= feature %>
                    </li>
                  <% end %>
                </ul>
              </div>
            </div>
          <% end %>
        </div>

        <%!-- Footer --%>
        <div class="flex items-center justify-between px-6 py-3 border-t border-base-300 flex-shrink-0">
          <%!-- Dot indicators --%>
          <div class="flex items-center gap-1.5" role="tablist" aria-label="Wizard slides">
            <%= for idx <- 0..(@slide_count - 1) do %>
              <button
                data-wizard-dot
                class={[
                  "h-2 rounded-full transition-all duration-300 cursor-pointer",
                  if(idx == 0, do: "bg-primary w-6", else: "bg-base-content/20 w-2")
                ]}
                role="tab"
                aria-label={"Slide #{idx + 1}"}
                aria-selected={idx == 0}
              ></button>
            <% end %>
          </div>

          <%!-- Navigation --%>
          <div class="flex items-center gap-2">
            <button data-wizard-skip class="btn btn-ghost btn-sm text-base-content/40 text-xs">
              Skip
            </button>
            <button data-wizard-prev class="btn btn-ghost btn-sm invisible">
              Previous
            </button>
            <button data-wizard-next class="btn btn-primary btn-sm">
              Next
            </button>
          </div>
        </div>
      </div>
    </div>

    <script>
      (function() {
        var page = "<%= @page %>";
        var storageKey = "ccem_wizard_shown_" + page;
        var el = document.querySelector("[data-wizard-page='" + page + "']");
        if (!el) return;

        // Show if not dismissed before
        if (!localStorage.getItem(storageKey)) {
          el.style.display = "flex";
          el.focus && el.focus();
        }

        var slides = el.querySelectorAll("[data-wizard-slide]");
        var dots   = el.querySelectorAll("[data-wizard-dot]");
        var counter = el.querySelector("[data-wizard-counter]");
        var total  = slides.length;
        var current = 0;

        function showSlide(idx) {
          if (idx < 0 || idx >= total) return;
          current = idx;
          slides.forEach(function(s, i) {
            s.classList.toggle("hidden", i !== idx);
          });
          dots.forEach(function(d, i) {
            d.classList.toggle("bg-primary", i === idx);
            d.classList.toggle("w-6", i === idx);
            d.classList.toggle("bg-base-content/20", i !== idx);
            d.classList.toggle("w-2", i !== idx);
            d.setAttribute("aria-selected", i === idx ? "true" : "false");
          });
          if (counter) counter.textContent = (idx + 1) + " / " + total;
          var prev = el.querySelector("[data-wizard-prev]");
          var next = el.querySelector("[data-wizard-next]");
          if (prev) prev.classList.toggle("invisible", idx === 0);
          if (next) next.textContent = idx === total - 1 ? "Done" : "Next";
        }

        function dismiss() {
          localStorage.setItem(storageKey, "true");
          el.style.display = "none";
        }

        // Dismiss buttons
        el.querySelectorAll("[data-wizard-dismiss], [data-wizard-skip]").forEach(function(btn) {
          btn.addEventListener("click", dismiss);
        });

        // Backdrop click
        el.querySelector("[data-wizard-dismiss][aria-hidden]") &&
          el.querySelector("[data-wizard-dismiss][aria-hidden]").addEventListener("click", dismiss);

        // Next
        var nextBtn = el.querySelector("[data-wizard-next]");
        if (nextBtn) nextBtn.addEventListener("click", function() {
          if (current >= total - 1) { dismiss(); } else { showSlide(current + 1); }
        });

        // Prev
        var prevBtn = el.querySelector("[data-wizard-prev]");
        if (prevBtn) prevBtn.addEventListener("click", function() { showSlide(current - 1); });

        // Dot navigation
        dots.forEach(function(dot, i) {
          dot.addEventListener("click", function() { showSlide(i); });
        });

        // Keyboard navigation
        el.addEventListener("keydown", function(e) {
          if (e.key === "ArrowRight" || e.key === "ArrowDown") { showSlide(current + 1); }
          else if (e.key === "ArrowLeft" || e.key === "ArrowUp") { showSlide(current - 1); }
          else if (e.key === "Escape") { dismiss(); }
        });
      })();
    </script>
    """
  end

  # --- Illustration helpers ---

  defp illustration("monitoring") do
    assigns = %{}
    ~H"""
    <svg viewBox="0 0 240 180" class="w-full max-w-[220px]" aria-hidden="true">
      <rect class="wizard-block-1" x="10" y="20" width="220" height="28" rx="5" fill="#6366f1" opacity="0.75"/>
      <rect class="wizard-block-2" x="10" y="58" width="170" height="18" rx="4" fill="#0ea5e9" opacity="0.55"/>
      <rect class="wizard-block-3" x="10" y="86" width="200" height="18" rx="4" fill="#22c55e" opacity="0.45"/>
      <rect class="wizard-block-4" x="10" y="114" width="140" height="18" rx="4" fill="#f59e0b" opacity="0.45"/>
      <circle class="wizard-pulse-dot"   cx="218" cy="34"  r="5" fill="#22c55e"/>
      <circle class="wizard-pulse-dot-2" cx="218" cy="67"  r="4" fill="#0ea5e9"/>
      <circle class="wizard-pulse-dot-3" cx="218" cy="95"  r="4" fill="#22c55e"/>
      <!-- mini chart bars -->
      <rect x="10"  y="148" width="14" height="20" rx="2" fill="#6366f1" opacity="0.5"/>
      <rect x="30"  y="138" width="14" height="30" rx="2" fill="#6366f1" opacity="0.6"/>
      <rect x="50"  y="143" width="14" height="25" rx="2" fill="#6366f1" opacity="0.55"/>
      <rect x="70"  y="134" width="14" height="34" rx="2" fill="#6366f1" opacity="0.65"/>
      <rect x="90"  y="141" width="14" height="27" rx="2" fill="#6366f1" opacity="0.55"/>
      <rect x="110" y="132" width="14" height="36" rx="2" fill="#22c55e" opacity="0.7"/>
    </svg>
    """
  end

  defp illustration("agents") do
    assigns = %{}
    ~H"""
    <svg viewBox="0 0 240 180" class="w-full max-w-[220px]" aria-hidden="true">
      <!-- Root node -->
      <circle class="wizard-node-1" cx="120" cy="30" r="16" fill="#6366f1" opacity="0.85"/>
      <text x="120" y="35" text-anchor="middle" font-size="10" fill="white" font-family="monospace">APM</text>
      <!-- Connectors -->
      <line x1="120" y1="46" x2="60"  y2="80" stroke="#6366f1" stroke-width="1.5" opacity="0.4"/>
      <line x1="120" y1="46" x2="120" y2="80" stroke="#6366f1" stroke-width="1.5" opacity="0.4"/>
      <line x1="120" y1="46" x2="180" y2="80" stroke="#6366f1" stroke-width="1.5" opacity="0.4"/>
      <!-- Child nodes -->
      <circle class="wizard-node-2" cx="60"  cy="90" r="12" fill="#0ea5e9" opacity="0.8"/>
      <circle class="wizard-node-3" cx="120" cy="90" r="12" fill="#22c55e" opacity="0.8"/>
      <circle class="wizard-node-4" cx="180" cy="90" r="12" fill="#f59e0b" opacity="0.8"/>
      <circle class="wizard-pulse-dot"   cx="60"  cy="90" r="5" fill="white" opacity="0.6"/>
      <circle class="wizard-pulse-dot-2" cx="120" cy="90" r="5" fill="white" opacity="0.6"/>
      <circle class="wizard-pulse-dot-3" cx="180" cy="90" r="5" fill="white" opacity="0.6"/>
      <!-- Status bars -->
      <rect class="wizard-block-3" x="30"  y="116" width="60" height="8"  rx="3" fill="#0ea5e9" opacity="0.5"/>
      <rect class="wizard-block-3" x="90"  y="116" width="60" height="8"  rx="3" fill="#22c55e" opacity="0.5"/>
      <rect class="wizard-block-4" x="150" y="116" width="60" height="8"  rx="3" fill="#f59e0b" opacity="0.5"/>
      <rect class="wizard-block-4" x="30"  y="132" width="40" height="6"  rx="3" fill="#0ea5e9" opacity="0.3"/>
      <rect class="wizard-block-4" x="90"  y="132" width="55" height="6"  rx="3" fill="#22c55e" opacity="0.3"/>
      <rect class="wizard-block-4" x="150" y="132" width="35" height="6"  rx="3" fill="#f59e0b" opacity="0.3"/>
    </svg>
    """
  end

  defp illustration("formation") do
    assigns = %{}
    ~H"""
    <svg viewBox="0 0 240 180" class="w-full max-w-[220px]" aria-hidden="true">
      <!-- Formation (top) -->
      <rect class="wizard-node-1" x="80" y="8" width="80" height="22" rx="4" fill="#8b5cf6" opacity="0.85"/>
      <text x="120" y="23" text-anchor="middle" font-size="9" fill="white" font-family="monospace">Formation</text>
      <!-- Squadron row -->
      <line x1="120" y1="30" x2="70"  y2="54" stroke="#8b5cf6" stroke-width="1.5" opacity="0.4"/>
      <line x1="120" y1="30" x2="170" y2="54" stroke="#8b5cf6" stroke-width="1.5" opacity="0.4"/>
      <rect class="wizard-node-2" x="30"  y="54" width="80" height="18" rx="3" fill="#6366f1" opacity="0.8"/>
      <rect class="wizard-node-3" x="130" y="54" width="80" height="18" rx="3" fill="#6366f1" opacity="0.8"/>
      <text x="70"  y="66" text-anchor="middle" font-size="8" fill="white" font-family="monospace">Squadron A</text>
      <text x="170" y="66" text-anchor="middle" font-size="8" fill="white" font-family="monospace">Squadron B</text>
      <!-- Wave progress -->
      <rect x="30"  y="82" width="80" height="6" rx="2" fill="#1e293b" opacity="0.5"/>
      <rect class="wizard-sweep" x="30" y="82" width="60" height="6" rx="2" fill="#22c55e" opacity="0.7"/>
      <rect x="130" y="82" width="80" height="6" rx="2" fill="#1e293b" opacity="0.5"/>
      <rect class="wizard-sweep" x="130" y="82" width="35" height="6" rx="2" fill="#f59e0b" opacity="0.7"/>
      <!-- Agent leaves -->
      <circle class="wizard-node-4" cx="42"  cy="108" r="8" fill="#0ea5e9" opacity="0.75"/>
      <circle class="wizard-node-4" cx="62"  cy="108" r="8" fill="#0ea5e9" opacity="0.75"/>
      <circle class="wizard-node-4" cx="82"  cy="108" r="8" fill="#22c55e" opacity="0.75"/>
      <circle class="wizard-node-5" cx="142" cy="108" r="8" fill="#f59e0b" opacity="0.75"/>
      <circle class="wizard-node-5" cx="162" cy="108" r="8" fill="#f59e0b" opacity="0.75"/>
      <circle class="wizard-pulse-dot"   cx="42"  cy="108" r="3" fill="white" opacity="0.7"/>
      <circle class="wizard-pulse-dot-2" cx="62"  cy="108" r="3" fill="white" opacity="0.7"/>
      <circle class="wizard-pulse-dot-3" cx="82"  cy="108" r="3" fill="white" opacity="0.7"/>
    </svg>
    """
  end

  defp illustration("realtime") do
    assigns = %{}
    ~H"""
    <svg viewBox="0 0 240 180" class="w-full max-w-[220px]" aria-hidden="true">
      <!-- Streaming lines -->
      <rect class="wizard-block-1" x="10" y="24" width="220" height="10" rx="3" fill="#6366f1" opacity="0.6"/>
      <rect class="wizard-block-2" x="10" y="42" width="180" height="10" rx="3" fill="#0ea5e9" opacity="0.5"/>
      <rect class="wizard-block-3" x="10" y="60" width="200" height="10" rx="3" fill="#22c55e" opacity="0.4"/>
      <rect class="wizard-block-4" x="10" y="78" width="160" height="10" rx="3" fill="#8b5cf6" opacity="0.45"/>
      <rect class="wizard-block-1" x="10" y="96" width="220" height="10" rx="3" fill="#f59e0b" opacity="0.4"/>
      <rect class="wizard-block-2" x="10" y="114" width="150" height="10" rx="3" fill="#6366f1" opacity="0.35"/>
      <!-- Live badge -->
      <rect class="wizard-node-1" x="170" y="140" width="56" height="20" rx="8" fill="#22c55e" opacity="0.85"/>
      <circle class="wizard-pulse-dot" cx="181" cy="150" r="4" fill="white"/>
      <text x="193" y="154" font-size="9" fill="white" font-family="sans-serif" font-weight="600">LIVE</text>
      <!-- Arrow sweep -->
      <path class="wizard-block-3" d="M 10 150 L 155 150" stroke="#6366f1" stroke-width="2" opacity="0.4" fill="none" stroke-dasharray="6 3"/>
    </svg>
    """
  end

  defp illustration("actions") do
    assigns = %{}
    ~H"""
    <svg viewBox="0 0 240 180" class="w-full max-w-[220px]" aria-hidden="true">
      <!-- Action cards -->
      <rect class="wizard-node-1" x="10" y="14" width="100" height="50" rx="5" fill="#6366f1" opacity="0.2" stroke="#6366f1" stroke-width="1" stroke-opacity="0.5"/>
      <rect class="wizard-node-2" x="125" y="14" width="100" height="50" rx="5" fill="#0ea5e9" opacity="0.2" stroke="#0ea5e9" stroke-width="1" stroke-opacity="0.5"/>
      <rect class="wizard-node-3" x="10" y="76" width="100" height="50" rx="5" fill="#22c55e" opacity="0.2" stroke="#22c55e" stroke-width="1" stroke-opacity="0.5"/>
      <rect class="wizard-node-4" x="125" y="76" width="100" height="50" rx="5" fill="#f59e0b" opacity="0.2" stroke="#f59e0b" stroke-width="1" stroke-opacity="0.5"/>
      <!-- Labels -->
      <rect x="18" y="24" width="50" height="6" rx="2" fill="#6366f1" opacity="0.6"/>
      <rect x="18" y="36" width="80" height="4" rx="2" fill="#6366f1" opacity="0.3"/>
      <rect x="18" y="46" width="60" height="4" rx="2" fill="#6366f1" opacity="0.25"/>
      <rect x="133" y="24" width="50" height="6" rx="2" fill="#0ea5e9" opacity="0.6"/>
      <rect x="133" y="36" width="80" height="4" rx="2" fill="#0ea5e9" opacity="0.3"/>
      <rect x="18" y="86" width="50" height="6" rx="2" fill="#22c55e" opacity="0.6"/>
      <rect x="133" y="86" width="50" height="6" rx="2" fill="#f59e0b" opacity="0.6"/>
      <!-- Cursor -->
      <g class="wizard-cursor" style="transform-origin: 160px 130px;">
        <path d="M 155 125 L 155 148 L 161 141 L 167 156 L 171 154 L 165 139 L 172 139 Z" fill="white" opacity="0.85"/>
      </g>
    </svg>
    """
  end

  defp illustration("tasks") do
    assigns = %{}
    ~H"""
    <svg viewBox="0 0 240 180" class="w-full max-w-[220px]" aria-hidden="true">
      <!-- Table header -->
      <rect class="wizard-block-1" x="10" y="16" width="220" height="20" rx="3" fill="#6366f1" opacity="0.5"/>
      <!-- Rows -->
      <rect class="wizard-block-2" x="10" y="42" width="220" height="16" rx="2" fill="#1e293b" opacity="0.5"/>
      <rect class="wizard-block-3" x="10" y="64" width="220" height="16" rx="2" fill="#1e293b" opacity="0.4"/>
      <rect class="wizard-block-4" x="10" y="86" width="220" height="16" rx="2" fill="#1e293b" opacity="0.35"/>
      <rect class="wizard-block-4" x="10" y="108" width="220" height="16" rx="2" fill="#1e293b" opacity="0.3"/>
      <!-- Status badges in rows -->
      <rect x="160" y="46" width="44" height="8" rx="3" fill="#22c55e" opacity="0.7"/>
      <rect x="160" y="68" width="44" height="8" rx="3" fill="#f59e0b" opacity="0.7"/>
      <rect x="160" y="90" width="44" height="8" rx="3" fill="#0ea5e9" opacity="0.7"/>
      <rect x="160" y="112" width="44" height="8" rx="3" fill="#ef4444" opacity="0.65"/>
      <!-- Pulse on first row -->
      <circle class="wizard-pulse-dot" cx="22" cy="50" r="4" fill="#22c55e" opacity="0.8"/>
      <circle class="wizard-pulse-dot-2" cx="22" cy="72" r="4" fill="#f59e0b" opacity="0.8"/>
    </svg>
    """
  end

  defp illustration("ports") do
    assigns = %{}
    ~H"""
    <svg viewBox="0 0 240 180" class="w-full max-w-[220px]" aria-hidden="true">
      <!-- Port grid -->
      <%= for {port, idx} <- Enum.with_index([3000, 3032, 4000, 4001, 5173, 8080]) do %>
        <% col = rem(idx, 3) %>
        <% row = div(idx, 3) %>
        <% x = 10 + col * 75 %>
        <% y = 20 + row * 65 %>
        <% color = cond do
          port == 3032 -> "#22c55e"
          port == 4001 -> "#ef4444"
          true -> "#6366f1"
        end %>
        <rect x={x} y={y} width="65" height="50" rx="5"
              fill={color} opacity="0.15"
              stroke={color} stroke-width="1" stroke-opacity="0.5"
              class="wizard-node-1"/>
        <text x={x + 32} y={y + 18} text-anchor="middle" font-size="11" fill={color} font-family="monospace" font-weight="600"><%= port %></text>
        <circle cx={x + 32} cy={y + 34} r="5" fill={color} opacity="0.7" class="wizard-pulse-dot"/>
      <% end %>
    </svg>
    """
  end

  defp illustration(other) when other in ["scanner", "skills", "notifications", "upm"] do
    assigns = %{type: other}
    ~H"""
    <svg viewBox="0 0 240 180" class="w-full max-w-[220px]" aria-hidden="true">
      <!-- Generic scan / radar ring animation -->
      <circle cx="120" cy="90" r="60" fill="none" stroke="#6366f1" stroke-width="1" opacity="0.25"/>
      <circle cx="120" cy="90" r="40" fill="none" stroke="#6366f1" stroke-width="1" opacity="0.35"/>
      <circle cx="120" cy="90" r="20" fill="#6366f1" opacity="0.2"/>
      <!-- Rotating sweep -->
      <g class="wizard-spin" style="transform-origin: 120px 90px;">
        <line x1="120" y1="90" x2="120" y2="30" stroke="#6366f1" stroke-width="2" opacity="0.6"/>
        <line x1="120" y1="90" x2="165" y2="60" stroke="#6366f1" stroke-width="1" opacity="0.3"/>
      </g>
      <!-- Center dot -->
      <circle class="wizard-pulse-dot" cx="120" cy="90" r="6" fill="#22c55e"/>
      <!-- Block rows -->
      <rect class="wizard-block-3" x="10" y="160" width="100" height="8" rx="3" fill="#6366f1" opacity="0.4"/>
      <rect class="wizard-block-4" x="120" y="160" width="80" height="8" rx="3" fill="#0ea5e9" opacity="0.35"/>
    </svg>
    """
  end

  defp illustration(_) do
    assigns = %{}
    ~H"""
    <svg viewBox="0 0 240 180" class="w-full max-w-[220px]" aria-hidden="true">
      <rect class="wizard-block-1" x="10" y="30" width="220" height="28" rx="5" fill="#6366f1" opacity="0.7"/>
      <rect class="wizard-block-2" x="10" y="70" width="180" height="18" rx="4" fill="#0ea5e9" opacity="0.55"/>
      <rect class="wizard-block-3" x="10" y="98" width="200" height="18" rx="4" fill="#22c55e" opacity="0.5"/>
      <circle class="wizard-pulse-dot" cx="218" cy="44" r="5" fill="#22c55e"/>
    </svg>
    """
  end
end
