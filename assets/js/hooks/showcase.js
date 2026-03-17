/**
 * ShowcaseHook — LiveView JS hook bridging ShowcaseLive to ShowcaseEngine.
 *
 * Modes:
 * - Engine mode (default): loads ShowcaseEngine class, receives real-time data via push_event
 * - Iframe mode: when data-static-path is set (migrated project), renders an iframe pointing
 *   to the static HTML so the layout is pixel-identical to the standalone viewer
 *
 * Events:
 * - handleEvent("showcase:data")           → engine.updateApmState(data)
 * - handleEvent("showcase:agents")         → engine.updateAgentState(data.agents)
 * - handleEvent("showcase:orch")           → engine.updateOrchState(data)
 * - handleEvent("showcase:project-changed")→ switch mode + reinit
 * - DOM "showcase:fullscreen"              → toggle fullscreen overlay (Esc to exit)
 */

const ShowcaseHook = {
  mounted() {
    this.engine = null;
    this.iframe = null;
    this._escHandler = null;
    this.project = this.el.dataset.project || "ccem";
    this.version = this.el.dataset.version || "5.5.0";
    this.features = [];

    // Target the phx-update="ignore" inner div so LiveView morphdom
    // never patches the engine-owned DOM on re-renders.
    this.engineContainer = this.el.querySelector("#showcase-engine-root") || this.el;

    try {
      this.features = JSON.parse(this.el.dataset.features || "[]");
    } catch (e) {
      console.warn("[ShowcaseHook] Failed to parse features:", e);
    }

    // Fullscreen toggle — fired by the fullscreen button via JS.dispatch
    this.el.addEventListener("showcase:fullscreen", () => this._toggleFullscreen());

    // Inject showcase fonts only here, not globally on every APM page
    this._loadFonts();

    // Start in the correct mode based on data-static-path
    const staticPath = this.el.dataset.staticPath;
    if (staticPath) {
      this._loadIframe(staticPath);
    } else {
      this._loadEngine();
    }

    // LiveView pushes real-time APM state
    this.handleEvent("showcase:data", (data) => {
      if (this.engine) this.engine.updateApmState(data);
    });

    // LiveView pushes agent list updates
    this.handleEvent("showcase:agents", (data) => {
      if (this.engine) this.engine.updateAgentState(data.agents || []);
    });

    // LiveView pushes orchestration state
    this.handleEvent("showcase:orch", (data) => {
      if (this.engine) this.engine.updateOrchState(data);
    });

    // LiveView pushes activity data (agents at work + action log)
    this.handleEvent("showcase:activity", (data) => {
      if (this.engine) this.engine.updateActivityData(data);
    });

    // Template changed via LiveView push_event
    this.handleEvent("showcase:template-changed", ({ template }) => {
      if (this.engine) this.engine.applyTemplate(template);
    });

    // Project changed via push_patch — switch mode and reinit
    this.handleEvent("showcase:project-changed", (data) => {
      this.project = data.project || this.project;
      this.version = data.version || this.version;
      if (data.features) this.features = data.features;

      // data-static-path is updated by morphdom before push_event is delivered
      const staticPath = this.el.dataset.staticPath || data.staticPath || "";

      if (staticPath) {
        // Iframe mode — teardown engine and load iframe
        this._teardown();
        this._loadIframe(staticPath);
      } else if (this.engine && typeof this.engine.updateProject === "function") {
        // Engine already mounted — update in-place to avoid full DOM teardown flash
        this.engine.updateProject(data);
      } else {
        // Engine not yet mounted (e.g. switching away from iframe mode) — full init
        this._teardown();
        this._initEngine();
      }
    });
  },

  destroyed() {
    this._teardown();
    if (this._escHandler) {
      document.removeEventListener("keydown", this._escHandler);
      this._escHandler = null;
    }
  },

  _teardown() {
    if (this.engine) {
      this.engine.destroy();
      this.engine = null;
    }
    this.iframe = null;
    this.engineContainer.innerHTML = "";
  },

  _loadEngine() {
    // ShowcaseEngine is served as a static asset — load once, then init
    if (typeof window.ShowcaseEngine === "function") {
      this._initEngine();
      return;
    }
    const script = document.createElement("script");
    script.src = "/showcase/showcase-engine.js";
    script.onload = () => this._initEngine();
    script.onerror = () => {
      console.error("[ShowcaseHook] Failed to load showcase-engine.js");
      this.engineContainer.innerHTML =
        '<div style="display:flex;align-items:center;justify-content:center;height:100%;color:rgba(255,255,255,0.3);font-size:12px;font-family:monospace">Failed to load showcase engine</div>';
    };
    document.head.appendChild(script);
  },

  _initEngine() {
    if (typeof window.ShowcaseEngine !== "function") {
      console.error("[ShowcaseHook] ShowcaseEngine not found on window");
      return;
    }

    this.engine = new window.ShowcaseEngine(this.engineContainer, {
      features: this.features,
      version: this.version,
      project: this.project,
      basePath: "/showcase"
    });

    this.engine.init();

    // Wire pushEvent bridge so the inspector can push events back to LiveView
    this.engine.setPushEventFn((event, payload) => this.pushEvent(event, payload));

    // Handle server-pushed feature inspection (e.g. from notifications or deep-links)
    this.handleEvent("showcase:inspect-feature", ({ feature }) => {
      if (this.engine) this.engine.setSelectedFeature(feature);
    });
  },

  _loadFonts() {
    const id = "showcase-fonts";
    if (document.getElementById(id)) return;
    const link = document.createElement("link");
    link.id = id;
    link.rel = "stylesheet";
    link.href = "https://fonts.googleapis.com/css2?family=Inter:wght@300;400;500;600;700&family=Fira+Code:wght@400;500&display=swap";
    document.head.appendChild(link);

    // Load showcase-specific scoped styles (Tailwind utility overrides, animations, etc.)
    const cssId = "showcase-scoped-styles";
    if (!document.getElementById(cssId)) {
      const styleLink = document.createElement("link");
      styleLink.id = cssId;
      styleLink.rel = "stylesheet";
      styleLink.href = "/showcase/showcase-styles.css";
      document.head.appendChild(styleLink);
    }
  },

  _loadIframe(src) {
    this.engineContainer.innerHTML = "";
    const iframe = document.createElement("iframe");
    iframe.src = src;
    iframe.style.cssText = "width:100%;height:100%;border:none;display:block;";
    this.engineContainer.appendChild(iframe);
    this.iframe = iframe;
  },

  _toggleFullscreen() {
    const isFullscreen = this.el.classList.toggle("showcase-fullscreen");

    // Toggle the button icons (button lives outside the hook container)
    const btn = document.getElementById("showcase-fullscreen-btn");
    if (btn) {
      const expandEl = btn.querySelector("[data-expand]");
      const collapseEl = btn.querySelector("[data-collapse]");
      if (expandEl) expandEl.style.display = isFullscreen ? "none" : "";
      if (collapseEl) collapseEl.style.display = isFullscreen ? "" : "none";
    }

    if (isFullscreen) {
      // Add an exit overlay button inside the engine container (phx-update=ignore zone)
      const exitBtn = document.createElement("button");
      exitBtn.id = "showcase-exit-fullscreen";
      exitBtn.title = "Exit fullscreen";
      exitBtn.textContent = "✕";
      exitBtn.style.cssText =
        "position:absolute;top:12px;right:12px;z-index:10000;" +
        "background:rgba(0,0,0,0.55);color:#fff;border:1px solid rgba(255,255,255,0.18);" +
        "border-radius:6px;padding:3px 10px;cursor:pointer;font-size:13px;font-family:monospace;" +
        "backdrop-filter:blur(4px);";
      exitBtn.onclick = () => this._toggleFullscreen();
      this.engineContainer.appendChild(exitBtn);

      this._escHandler = (e) => {
        if (e.key === "Escape") this._toggleFullscreen();
      };
      document.addEventListener("keydown", this._escHandler);
    } else {
      const exitBtn = document.getElementById("showcase-exit-fullscreen");
      if (exitBtn) exitBtn.remove();

      if (this._escHandler) {
        document.removeEventListener("keydown", this._escHandler);
        this._escHandler = null;
      }
    }
  }
};

export default ShowcaseHook;
