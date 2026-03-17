/**
 * ShowcaseEngine — Containerized CCEM showcase rendering engine.
 *
 * Refactored from showcase/client/showcase.js for LiveView integration.
 * Key differences from standalone:
 * - All DOM queries scoped to container element (no document.getElementById)
 * - No polling — data flows in via update*() methods from LiveView hook
 * - Exported as window.ShowcaseEngine class
 * - FEATURES provided via config (per-project)
 */

(function () {
  "use strict";

  // ─── Constants ──────────────────────────────────────────────────────────────────

  const WAVE_COLORS = {
    1: { hex: '#10b981', stroke: '#34d399', fill: '#10b981', text: 'text-emerald-400', bg: 'bg-emerald-500/10', ring: 'ring-emerald-500/30', pill: 'text-emerald-400 bg-emerald-500/10 ring-emerald-500/30', border: 'border-emerald-500/20', bar: 'bg-emerald-500' },
    2: { hex: '#3b82f6', stroke: '#60a5fa', fill: '#3b82f6', text: 'text-blue-400', bg: 'bg-blue-500/10', ring: 'ring-blue-500/30', pill: 'text-blue-400 bg-blue-500/10 ring-blue-500/30', border: 'border-blue-500/20', bar: 'bg-blue-500' },
    3: { hex: '#a855f7', stroke: '#c084fc', fill: '#a855f7', text: 'text-purple-400', bg: 'bg-purple-500/10', ring: 'ring-purple-500/30', pill: 'text-purple-400 bg-purple-500/10 ring-purple-500/30', border: 'border-purple-500/20', bar: 'bg-purple-500' },
    4: { hex: '#f59e0b', stroke: '#fbbf24', fill: '#f59e0b', text: 'text-amber-400', bg: 'bg-amber-500/10', ring: 'ring-amber-500/30', pill: 'text-amber-400 bg-amber-500/10 ring-amber-500/30', border: 'border-amber-500/20', bar: 'bg-amber-500' },
    5: { hex: '#ef4444', stroke: '#f87171', fill: '#ef4444', text: 'text-rose-400', bg: 'bg-rose-500/10', ring: 'ring-rose-500/30', pill: 'text-rose-400 bg-rose-500/10 ring-rose-500/30', border: 'border-rose-500/20', bar: 'bg-rose-500' },
  };

  const WAVE_LABELS = { 1: 'Foundation', 2: 'Core', 3: 'Dashboard', 4: 'Tools', 5: 'Integration' };

  // ─── Template Registry ───────────────────────────────────────────────────────

  const TEMPLATES = {
    "engine": {
      id: "engine",
      label: "Architecture View",
      description: "SVG architecture diagram with feature roadmap",
      leftContent: "features",
      centerContent: "architecture",
      rightContent: "inspector"
    },
    "formation": {
      id: "formation",
      label: "Formation View",
      description: "Formation hierarchy with wave/story breakdown",
      leftContent: "formation-tree",
      centerContent: "narrative",
      rightContent: "resource-inspector"
    }
  };

  const STATUS_COLORS = {
    green:   { dot: 'bg-emerald-500 shadow-emerald-500/60 shadow-sm', text: 'text-emerald-400' },
    amber:   { dot: 'bg-yellow-500 shadow-yellow-500/60 shadow-sm', text: 'text-yellow-400' },
    red:     { dot: 'bg-red-500 shadow-red-500/60 shadow-sm', text: 'text-red-400' },
    unknown: { dot: 'bg-zinc-600', text: 'text-zinc-500' },
  };

  class ShowcaseEngine {
    constructor(container, config) {
      this.container = container;
      this.config = config || {};
      this.features = config.features || [];
      this.version = config.version || 'v5.5.0';
      this.project = config.project || 'ccem';
      this.basePath = config.basePath || '/showcase';

      // State
      this.apmState = { connected: false, status: null, agents: [], lastPoll: null, apmConn: 'off', projectConn: 'off' };
      this.orchState = { phase: 'ship', formationId: null, wave: 5, totalWaves: 5, agentsActive: 0, agentsTotal: 0, tsc: 'PASS', lastEvent: null, storiesDone: this.features.length, storiesTotal: this.features.length };
      this.liveMap = new Map();
      this.viewMode = 'card';
      this.waveFilter = null;
      this.progressFilter = 'all';
      this.roadmapOpen = false;
      this.archTab = 'system';
      this.npmSvgCache = null;
      this.selectedFeatureId = null;
      this.activeTemplate = config.template || 'engine';
      this.selectedNarrativeFeature = null;
      this._templateDropdownOpen = false;

      // Contextual inspector state — set when a feature card is clicked
      this.selectedFeature = null;

      // Activity tab state
      this.activityData = { agents: {}, log: [] };
      this._activityGraphInitialized = false;
      this._activityLogExpanded = false;

      // Unique instance ID for scoped element IDs
      this._instanceId = Math.random().toString(36).slice(2, 8);

      // pushEvent bridge — wired by the LiveView hook via setPushEventFn()
      this.pushEventFn = null;

      // Dirty-check caches — prevents redundant innerHTML thrashing on 5s heartbeat
      this._lastApmHash = null;
      this._lastOrchHash = null;
      this._lastAgentsHash = null;
    }

    // ─── Lifecycle ──────────────────────────────────────────────────────────────

    init() {
      this._buildSkeleton();
      this._renderAll();
    }

    destroy() {
      // Remove the persistent delegated listener on features-container before clearing innerHTML.
      if (this._featureClickBound && this._featureClickHandler) {
        const featuresContainer = this._q('[data-sc="features-container"]');
        if (featuresContainer) {
          featuresContainer.removeEventListener('click', this._featureClickHandler);
        }
        this._featureClickHandler = null;
        this._featureClickBound = false;
      }

      if (this._activitySimulation) {
        this._activitySimulation.stop();
        this._activitySimulation = null;
      }

      this.container.innerHTML = '';
      // Null out all references so closures captured in event listeners
      // (added via addEventListener inside innerHTML) don't hold this alive.
      this.container = null;
      this.features = null;
      this.apmState = null;
      this.orchState = null;
      this.liveMap = null;
      this.npmSvgCache = null;
      this.selectedFeatureId = null;
      this.selectedFeature = null;
      this.pushEventFn = null;
    }

    // ─── Data Update Methods (called from LiveView hook) ────────────────────────

    updateApmState(data) {
      if (!this.container) return;
      const hash = JSON.stringify([data.connected, data.apmConn, data.projectConn, data.status]);
      if (hash === this._lastApmHash) return;  // No change — skip full re-render
      this._lastApmHash = hash;

      if (data.connected !== undefined) this.apmState.connected = data.connected;
      if (data.status) this.apmState.status = data.status;
      if (data.apmConn) this.apmState.apmConn = data.apmConn;
      if (data.projectConn) this.apmState.projectConn = data.projectConn;
      this.apmState.lastPoll = new Date();
      this._renderOrchestrationStatus();
      this._renderRightColumn();
      this._renderCenterColumn();
    }

    updateAgentState(agents) {
      if (!this.container) return;
      const hash = JSON.stringify((agents || []).map(a => a.id + a.status));
      if (hash === this._lastAgentsHash) return;
      this._lastAgentsHash = hash;

      this.apmState.agents = agents || [];
      this.orchState.agentsTotal = this.apmState.agents.length;
      this.orchState.agentsActive = this.apmState.agents.filter(a => a.status === 'active' || a.status === 'working').length;
      this._renderOrchestrationStatus();
      this._renderRightColumn();
    }

    updateOrchState(data) {
      if (!this.container) return;
      const hash = JSON.stringify([data.phase, data.wave, data.tsc, data.formation_id]);
      if (hash === this._lastOrchHash) return;
      this._lastOrchHash = hash;

      if (data.phase) this.orchState.phase = data.phase;
      if (data.formationId || data.formation_id) this.orchState.formationId = data.formationId || data.formation_id;
      if (data.wave !== undefined) this.orchState.wave = data.wave;
      if (data.totalWaves !== undefined || data.total_waves !== undefined) this.orchState.totalWaves = data.totalWaves || data.total_waves;
      if (data.agentsActive !== undefined) this.orchState.agentsActive = data.agentsActive;
      if (data.agentsTotal !== undefined) this.orchState.agentsTotal = data.agentsTotal;
      if (data.tsc) this.orchState.tsc = data.tsc;
      this._renderOrchestrationStatus();
    }

    updateActivityData(data) {
      if (!this.container) return;
      this.activityData = data;
      if (this.archTab === 'activity') {
        this._renderArchitecture();
      }
    }

    reinit(data) {
      if (data.features) this.features = data.features;
      if (data.version) this.version = data.version;
      if (data.project) this.project = data.project;
      this.orchState.storiesDone = this.features.length;
      this.orchState.storiesTotal = this.features.length;
      this._renderAll();
    }

    /**
     * updateProject — in-place project switch, no DOM skeleton teardown.
     *
     * Updates config, features, version, and project, then surgically
     * re-renders only the orchestration status bar and feature cards.
     * The container skeleton, event listeners, and center/right panels
     * are left untouched, eliminating the full-visual-flash on project switch.
     */
    updateProject(data) {
      if (!this.container) return;
      if (data.features) this.features = data.features;
      if (data.version) this.version = data.version;
      if (data.project) this.project = data.project;
      if (data.config) this.config = Object.assign({}, this.config, data.config);
      // Keep orchState story counters in sync with new feature set
      this.orchState.storiesDone = this.features.length;
      this.orchState.storiesTotal = this.features.length;
      // Bust dirty-check caches so renders are not skipped
      this._lastOrchHash = null;
      this._lastAgentsHash = null;
      // Surgical in-place update — only touch header bar and left column
      this._renderOrchestrationStatus();
      this._renderFeatureCards();
    }

    /**
     * setPushEventFn — wire the LiveView pushEvent bridge.
     * Called from the ShowcaseHook after engine init so the inspector
     * can push events back to the LiveView (e.g. "inspector:view-formation").
     */
    setPushEventFn(fn) {
      this.pushEventFn = fn;
    }

    /**
     * setSelectedFeature — select a feature for contextual inspector display.
     * Called by the LiveView hook when the server pushes "showcase:inspect-feature",
     * or directly by the engine when a feature card is clicked.
     */
    setSelectedFeature(feature) {
      if (!this.container) return;
      this.selectedFeature = feature || null;
      this._renderInspector();
    }

    // ─── Internal ───────────────────────────────────────────────────────────────

    _q(selector) {
      return this.container.querySelector(selector);
    }

    _resolveStatus(featureId) {
      const live = this.liveMap.get(featureId);
      if (!live) return 'done';
      if (live.passes) return 'done';
      if (live.status === 'in_progress') return 'in-progress';
      return 'planned';
    }

    _buildSkeleton() {
      this.container.innerHTML = `
        <div class="flex flex-col h-full bg-zinc-950 text-zinc-100 antialiased overflow-hidden">
          <!-- Orchestration Status Bar -->
          <div class="border-b border-zinc-800/60 bg-zinc-900/80 px-4 py-2 flex-shrink-0" data-sc="orchestration-bar"></div>

          <!-- 3-Column Layout -->
          <div class="flex-1 grid grid-cols-[320px_1fr_300px] gap-0 divide-x divide-zinc-800 overflow-hidden min-h-0">
            <!-- Left: Feature Cards -->
            <aside class="h-full overflow-y-auto p-5">
              <div class="space-y-4" data-sc="features-container"></div>
            </aside>

            <!-- Center: Architecture -->
            <main class="h-full overflow-y-auto p-5 space-y-6">
              <div data-sc="architecture-container"></div>
            </main>

            <!-- Right: Inspector Panel -->
            <aside class="h-full overflow-y-auto p-5">
              <div class="space-y-4" data-sc="inspector-container"></div>
            </aside>
          </div>

          <!-- Roadmap Modal -->
          <div data-sc="roadmap-modal"></div>

          <!-- Bottom Bar -->
          <div class="flex-shrink-0 border-t border-zinc-800" data-sc="bottom-bar"></div>
        </div>
      `;
    }

    _renderAll() {
      if (!this.container) return;
      this._renderOrchestrationStatus();
      this._renderLeftColumn();
      this._renderCenterColumn();
      this._renderRightColumn();
      this._renderBottomBar();
    }

    // ─── Template System ─────────────────────────────────────────────────────────

    applyTemplate(templateId) {
      if (!TEMPLATES[templateId]) return;
      this.activeTemplate = templateId;
      this._templateDropdownOpen = false;
      // Reset narrative selection when switching to formation template
      if (templateId === 'formation') {
        this.selectedNarrativeFeature = this.features[0] || null;
      }
      this._buildSkeleton();
      this._renderAll();
    }

    _renderLeftColumn() {
      const tmpl = TEMPLATES[this.activeTemplate] || TEMPLATES['engine'];
      if (tmpl.leftContent === 'formation-tree') {
        this._renderFormationTree();
      } else {
        this._renderFeatureCards();
      }
    }

    _renderCenterColumn() {
      const tmpl = TEMPLATES[this.activeTemplate] || TEMPLATES['engine'];
      if (tmpl.centerContent === 'narrative') {
        this._renderNarrative(this.selectedNarrativeFeature);
      } else {
        this._renderArchitecture();
      }
    }

    _renderRightColumn() {
      this._renderInspector();
    }

    // ─── Orchestration Status Bar ───────────────────────────────────────────────

    _renderOrchestrationStatus() {
      if (!this.container) return;
      const bar = this._q('[data-sc="orchestration-bar"]');
      if (!bar) return;

      const connDot = (conn) => conn === 'live' ? 'bg-emerald-400 shadow-emerald-400/60 shadow-sm animate-pulse' : conn === 'polling' ? 'bg-emerald-400/70 shadow-sm' : 'bg-zinc-600';
      const connText = (conn) => conn === 'live' ? 'text-emerald-400' : conn === 'polling' ? 'text-emerald-400/70' : 'text-zinc-600';
      const connLabel = (conn) => conn === 'live' ? 'sse' : conn === 'polling' ? 'rest' : 'off';

      const phases = ['plan', 'build', 'verify', 'ship'];
      const activeIdx = this.orchState.phase !== 'idle' ? phases.indexOf(this.orchState.phase) : -1;
      const phaseColors = { plan: 'text-blue-400', build: 'text-emerald-400', verify: 'text-purple-400', ship: 'text-pink-400' };
      const phaseBg = { plan: 'bg-blue-500/10 ring-blue-500/20', build: 'bg-emerald-500/10 ring-emerald-500/20', verify: 'bg-purple-500/10 ring-purple-500/20', ship: 'bg-pink-500/10 ring-pink-500/20' };

      const stepper = phases.map((step, i) => {
        const isActive = step === this.orchState.phase;
        const isDone = activeIdx > i && this.orchState.phase !== 'idle';
        const cls = isActive ? `font-bold ring-1 ${phaseColors[step]} ${phaseBg[step]}` : isDone ? 'text-zinc-500 line-through' : 'text-zinc-700';
        return `<span class="text-[10px] font-mono px-1.5 py-0.5 rounded transition ${cls}">${step}</span>${i < phases.length - 1 ? `<span class="text-[10px] mx-0.5 ${isDone || isActive ? 'text-zinc-600' : 'text-zinc-800'}">&#x203A;</span>` : ''}`;
      }).join('');

      const fmtId = this.orchState.formationId ? (this.orchState.formationId.length > 18 ? this.orchState.formationId.slice(-14) : this.orchState.formationId) : '\u2014';
      const wavePct = this.orchState.totalWaves ? Math.round(((this.orchState.wave - 1) / this.orchState.totalWaves) * 100) : 0;
      const storyPct = this.orchState.storiesTotal ? Math.round((this.orchState.storiesDone / this.orchState.storiesTotal) * 100) : 0;
      const tscCls = this.orchState.tsc === 'PASS' ? 'text-emerald-400 bg-emerald-500/10 ring-emerald-500/20' : this.orchState.tsc === 'FAIL' ? 'text-red-400 bg-red-500/10 ring-red-500/20' : 'text-zinc-700';

      bar.innerHTML = `
        <div class="flex items-center overflow-x-auto gap-0">
          <span class="inline-flex items-center gap-1.5">
            <span class="h-1.5 w-1.5 rounded-full flex-shrink-0 ${connDot(this.apmState.apmConn)}"></span>
            <span class="font-mono text-[10px] ${connText(this.apmState.apmConn)}">APM<span class="ml-1 text-zinc-700">:${connLabel(this.apmState.apmConn)}</span></span>
          </span>
          <span class="mx-2.5 text-zinc-800 text-[10px]">&middot;</span>
          <span class="inline-flex items-center gap-1.5">
            <span class="h-1.5 w-1.5 rounded-full flex-shrink-0 ${connDot(this.apmState.projectConn)}"></span>
            <span class="font-mono text-[10px] ${connText(this.apmState.projectConn)}">Project<span class="ml-1 text-zinc-700">:${connLabel(this.apmState.projectConn)}</span></span>
          </span>
          <span class="h-4 w-px bg-zinc-800 mx-3 flex-shrink-0"></span>
          ${stepper}
          <span class="h-4 w-px bg-zinc-800 mx-3 flex-shrink-0"></span>
          <span class="text-[10px] font-mono text-zinc-400"><span class="text-zinc-600">fmt:</span>${fmtId}</span>
          <span class="mx-2 text-zinc-800 text-[10px]">&#x203A;</span>
          <span class="inline-flex items-center gap-1.5">
            <span class="text-[10px] font-mono text-zinc-300">W<span class="text-yellow-400">${this.orchState.wave || '\u2014'}</span>${this.orchState.totalWaves != null ? `<span class="text-zinc-600">/${this.orchState.totalWaves}</span>` : ''}</span>
            ${this.orchState.totalWaves != null ? `<span class="h-1 w-12 rounded-full bg-zinc-800 overflow-hidden"><span class="h-full block bg-yellow-500/60 transition-all duration-500" style="width:${wavePct}%"></span></span>` : ''}
          </span>
          <span class="mx-2 text-zinc-800 text-[10px]">&#x203A;</span>
          <span class="inline-flex items-center gap-1 text-[10px] font-mono ${this.orchState.agentsActive > 0 ? 'text-emerald-400' : 'text-zinc-600'}">
            ${this.orchState.agentsActive > 0 ? '<span class="h-1.5 w-1.5 rounded-full bg-emerald-400 animate-pulse"></span>' : ''}
            ${this.orchState.agentsActive > 0 ? `<span class="text-emerald-400">${this.orchState.agentsActive}</span><span class="text-zinc-600">/${this.orchState.agentsTotal} agents</span>` : this.orchState.agentsTotal > 0 ? `<span class="text-zinc-500">${this.orchState.agentsTotal} agents</span>` : '<span class="text-zinc-700">agents:\u2014</span>'}
          </span>
          <span class="mx-2 text-zinc-800 text-[10px]">&#x203A;</span>
          ${this.orchState.tsc ? `<span class="text-[10px] font-mono font-bold rounded px-1.5 py-0.5 ring-1 ${tscCls}">tsc:${this.orchState.tsc}</span>` : '<span class="text-[10px] font-mono text-zinc-700">tsc:\u2014</span>'}
          ${this.orchState.storiesTotal > 0 ? `
            <span class="mx-2 text-zinc-800 text-[10px]">&#x203A;</span>
            <span class="inline-flex items-center gap-1.5 text-[10px] font-mono">
              <span class="text-zinc-600">stories:</span>
              <span class="${this.orchState.storiesDone === this.orchState.storiesTotal ? 'text-emerald-400' : 'text-zinc-400'}">${this.orchState.storiesDone}</span>
              <span class="text-zinc-700">/${this.orchState.storiesTotal}</span>
              <span class="h-1 w-8 rounded-full bg-zinc-800 overflow-hidden"><span class="h-full block bg-zinc-500/60 transition-all" style="width:${storyPct}%"></span></span>
            </span>
          ` : ''}
          <span class="ml-auto flex-shrink-0 text-[9px] font-mono text-zinc-800 pl-4 mr-3">
            ${this.apmState.apmConn === 'live' ? 'SSE:APM' : this.apmState.apmConn === 'polling' ? 'REST:APM' : 'APM:offline'}
          </span>
          <div class="relative flex-shrink-0 mr-2" data-sc="template-switcher">
            <button type="button" data-sc-action="toggle-template-dropdown" class="rounded border border-zinc-700/60 bg-zinc-800/50 px-2.5 py-1 text-[10px] font-mono text-zinc-400 hover:bg-zinc-700/60 hover:text-zinc-200 transition flex items-center gap-1">
              ${TEMPLATES[this.activeTemplate]?.label || 'Template'} &#x25BE;
            </button>
            ${this._templateDropdownOpen ? `
              <div data-sc="template-dropdown" class="absolute right-0 top-full mt-1 z-50 min-w-[180px] rounded-lg border border-zinc-700 bg-zinc-900 shadow-xl">
                ${Object.values(TEMPLATES).map(t => `
                  <button type="button" data-sc-action="select-template" data-sc-template="${t.id}"
                    class="w-full text-left px-3 py-2 text-[10px] font-mono hover:bg-zinc-800 transition ${this.activeTemplate === t.id ? 'text-zinc-200 bg-zinc-800/60' : 'text-zinc-400'}">
                    <span class="block font-semibold ${this.activeTemplate === t.id ? 'text-zinc-100' : ''}">${t.label}</span>
                    <span class="block text-zinc-600 text-[9px]">${t.description}</span>
                  </button>
                `).join('')}
              </div>
            ` : ''}
          </div>
          <button type="button" data-sc-action="toggle-roadmap" class="flex-shrink-0 rounded border border-zinc-700/60 bg-zinc-800/50 px-2.5 py-1 text-[10px] font-mono text-zinc-400 hover:bg-zinc-700/60 hover:text-zinc-200 transition">
            Roadmap &#x2197;
          </button>
        </div>
      `;

      bar.querySelector('[data-sc-action="toggle-roadmap"]')?.addEventListener('click', () => {
        this.roadmapOpen = !this.roadmapOpen;
        this._renderRoadmapModal();
      });

      bar.querySelector('[data-sc-action="toggle-template-dropdown"]')?.addEventListener('click', () => {
        this._templateDropdownOpen = !this._templateDropdownOpen;
        this._renderOrchestrationStatus();
      });

      bar.querySelectorAll('[data-sc-action="select-template"]').forEach(btn => {
        btn.addEventListener('click', () => {
          const id = btn.dataset.scTemplate;
          this.applyTemplate(id);
        });
      });

      // Close dropdown on outside click
      if (this._templateDropdownOpen) {
        const closeHandler = (e) => {
          if (!bar.querySelector('[data-sc="template-switcher"]')?.contains(e.target)) {
            this._templateDropdownOpen = false;
            this._renderOrchestrationStatus();
            document.removeEventListener('click', closeHandler, true);
          }
        };
        // Use capture + setTimeout so the button click itself doesn't immediately close
        setTimeout(() => document.addEventListener('click', closeHandler, true), 0);
      }
    }

    // ─── Roadmap Modal ──────────────────────────────────────────────────────────

    _renderRoadmapModal() {
      const el = this._q('[data-sc="roadmap-modal"]');
      if (!el) return;
      if (!this.roadmapOpen) { el.innerHTML = ''; return; }

      const byWave = {};
      this.features.forEach(f => { byWave[f.wave] = [...(byWave[f.wave] || []), f]; });
      const waves = Object.keys(byWave).map(Number).sort((a, b) => a - b);
      const totalDone = this.features.filter(f => this._resolveStatus(f.id) === 'done').length;
      const pct = Math.round((totalDone / this.features.length) * 100);

      const self = this;

      function waveIcon(wave, allDone) {
        const c = WAVE_COLORS[wave] || WAVE_COLORS[1];
        const check = allDone ? `<path d="M9 14l3.5 3.5L19 10" stroke="white" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" fill="none"/>` : `<text x="14" y="19" text-anchor="middle" fill="${c.stroke}" font-size="11" font-weight="bold" font-family="monospace">${wave}</text>`;
        const pulse = allDone ? '' : `<circle cx="14" cy="14" r="12" fill="transparent" stroke="${c.stroke}" stroke-width="2" opacity="0.4"><animate attributeName="r" from="12" to="14" dur="2s" repeatCount="indefinite"/><animate attributeName="opacity" from="0.4" to="0" dur="2s" repeatCount="indefinite"/></circle>`;
        return `<svg width="28" height="28" viewBox="0 0 28 28" class="flex-shrink-0"><circle cx="14" cy="14" r="12" fill="${allDone ? c.fill : 'transparent'}" stroke="${c.stroke}" stroke-width="2"/>${check}${pulse}</svg>`;
      }

      function storyDot(passes, wave, delay) {
        const c = WAVE_COLORS[wave] || WAVE_COLORS[1];
        const pulse = passes ? '' : `<circle cx="6" cy="6" r="5" fill="transparent" stroke="${c.stroke}" stroke-width="1.5" opacity="0"><animate attributeName="opacity" values="0;0.5;0" dur="${2 + delay * 0.3}s" repeatCount="indefinite" begin="${delay * 0.2}s"/></circle>`;
        return `<svg width="12" height="12" viewBox="0 0 12 12" class="flex-shrink-0 mt-0.5"><circle cx="6" cy="6" r="5" fill="${passes ? c.fill : '#27272a'}" stroke="${passes ? c.stroke : '#3f3f46'}" stroke-width="1.5"/>${pulse}</svg>`;
      }

      const waveGroups = waves.map(w => {
        const stories = byWave[w];
        const c = WAVE_COLORS[w] || WAVE_COLORS[1];
        const allDone = stories.every(s => self._resolveStatus(s.id) === 'done');
        const doneCt = stories.filter(s => self._resolveStatus(s.id) === 'done').length;

        const storyRows = stories.map((s, i) => {
          const passes = self._resolveStatus(s.id) === 'done';
          return `<div class="flex items-start gap-2">${storyDot(passes, w, i)}<div class="flex items-baseline gap-1.5 min-w-0"><span class="text-[10px] font-mono text-zinc-600 flex-shrink-0">${s.id}</span><span class="text-[11px] truncate ${passes ? 'text-zinc-300 line-through decoration-zinc-600' : 'text-zinc-400'}">${s.title}</span></div></div>`;
        }).join('');

        const connector = w < Math.max(...waves) ? `<div class="w-px flex-1 min-h-[16px]" style="background:linear-gradient(to bottom,${c.stroke}40,transparent)"></div>` : '';

        return `
          <div class="flex gap-4">
            <div class="flex flex-col items-center gap-0 flex-shrink-0">${waveIcon(w, allDone)}${connector}</div>
            <div class="flex-1 pb-5">
              <div class="flex items-center gap-2 mb-2">
                <span class="text-[11px] font-bold font-mono ${c.text}">WAVE ${w}</span>
                <span class="text-[10px] font-mono text-zinc-600">${doneCt}/${stories.length}</span>
                ${allDone ? `<span class="text-[9px] font-mono font-bold px-1.5 py-0.5 rounded ring-1 ${c.text} ${c.bg}" style="border-color:${c.stroke}40">SHIPPED</span>` : ''}
              </div>
              <div class="space-y-1.5">${storyRows}</div>
            </div>
          </div>
        `;
      }).join('');

      el.innerHTML = `
        <div class="fixed inset-0 z-[60] overflow-y-auto bg-black/70 backdrop-blur-sm" data-sc-action="close-roadmap">
          <div class="flex min-h-full items-center justify-center p-4">
            <div class="relative w-full max-w-lg rounded-2xl border border-zinc-700/60 bg-zinc-950 shadow-2xl shadow-black/80 overflow-hidden" data-sc-stop>
              <div class="flex items-center justify-between px-5 py-3.5 border-b border-zinc-800">
                <div class="flex items-center gap-3">
                  <span class="text-sm font-bold text-zinc-100">Feature Roadmap</span>
                  <span class="text-[10px] font-mono text-zinc-500">${totalDone}/${this.features.length} stories</span>
                </div>
                <button type="button" data-sc-action="close-roadmap-btn" class="text-zinc-600 hover:text-zinc-300 transition text-lg leading-none">&times;</button>
              </div>
              <div class="px-5 pt-3 pb-0">
                <div class="flex items-center gap-2 mb-1">
                  <span class="text-[10px] font-mono text-zinc-500">overall progress</span>
                  <span class="text-[10px] font-mono text-zinc-400 ml-auto">${pct}%</span>
                </div>
                <div class="h-1.5 w-full rounded-full bg-zinc-800 overflow-hidden">
                  <div class="h-full rounded-full bg-gradient-to-r from-emerald-500 to-emerald-400 transition-all duration-700" style="width:${pct}%"></div>
                </div>
              </div>
              <div class="px-5 py-4 overflow-y-auto max-h-[70vh]">${waveGroups}</div>
              <div class="px-5 py-2.5 border-t border-zinc-800/60 flex items-center justify-between">
                <span class="text-[9px] font-mono text-zinc-700">main</span>
                <span class="text-[9px] font-mono text-zinc-700">Live &middot; PubSub</span>
              </div>
            </div>
          </div>
        </div>
      `;

      // Event delegation for close
      el.querySelector('[data-sc-action="close-roadmap"]')?.addEventListener('click', (e) => {
        if (!e.target.closest('[data-sc-stop]')) {
          this.roadmapOpen = false;
          this._renderRoadmapModal();
        }
      });
      el.querySelector('[data-sc-action="close-roadmap-btn"]')?.addEventListener('click', () => {
        this.roadmapOpen = false;
        this._renderRoadmapModal();
      });
    }

    // ─── Feature Cards (Left Panel) ─────────────────────────────────────────────

    _renderFeatureCards() {
      const container = this._q('[data-sc="features-container"]');
      if (!container) return;

      const waves = [...new Set(this.features.map(f => f.wave))].sort((a, b) => a - b);
      const withStatus = this.features.map(f => ({ ...f, liveStatus: this._resolveStatus(f.id) }));
      const filtered = withStatus.filter(f => {
        if (this.waveFilter !== null && f.wave !== this.waveFilter) return false;
        if (this.progressFilter === 'done' && f.liveStatus !== 'done') return false;
        if (this.progressFilter === 'in-progress' && f.liveStatus !== 'in-progress') return false;
        if (this.progressFilter === 'planned' && f.liveStatus !== 'planned') return false;
        return true;
      });
      const totalDone = withStatus.filter(f => f.liveStatus === 'done').length;

      const statusLabel = { done: 'DONE', 'in-progress': 'IN PROGRESS', planned: 'planned' };
      const statusColor = { done: 'text-emerald-400 bg-emerald-500/10 ring-emerald-500/20', 'in-progress': 'text-blue-400 bg-blue-500/10 ring-blue-500/20', planned: 'text-zinc-600 bg-zinc-800/40 ring-zinc-700/30' };
      const statusDot = { done: '\u25CF', 'in-progress': '\u25D1', planned: '\u25CB' };

      let html = `
        <div class="sticky top-0 z-10 bg-zinc-950/95 backdrop-blur-sm pb-2 border-b border-zinc-800/60 mb-3 flex-shrink-0">
          <div class="mb-2 flex items-center justify-between">
            <div>
              <h2 class="text-[11px] font-bold text-zinc-300">Feature Roadmap</h2>
              <p class="text-[9px] text-zinc-600 font-mono">${totalDone}/${this.features.length} stories &middot; ${waves.length} waves</p>
            </div>
            <div class="flex items-center gap-0.5 rounded-lg border border-zinc-700/60 bg-zinc-800/40 p-0.5">
              <button type="button" data-sc-view="card" class="flex items-center gap-1.5 px-2.5 py-1 rounded-md text-[10px] font-medium transition ${this.viewMode === 'card' ? 'bg-zinc-700 text-zinc-200 shadow-sm' : 'text-zinc-500 hover:text-zinc-300'}">Cards</button>
              <button type="button" data-sc-view="hierarchy" class="flex items-center gap-1.5 px-2.5 py-1 rounded-md text-[10px] font-medium transition ${this.viewMode === 'hierarchy' ? 'bg-zinc-700 text-zinc-200 shadow-sm' : 'text-zinc-500 hover:text-zinc-300'}">Hierarchy</button>
            </div>
          </div>
          <div class="flex flex-wrap gap-1 mb-1.5">
            <button type="button" data-sc-wave="" class="text-[9px] font-mono px-2 py-0.5 rounded-full ring-1 transition ${this.waveFilter === null ? 'text-zinc-200 bg-zinc-700 ring-zinc-600' : 'text-zinc-500 bg-transparent ring-zinc-700 hover:text-zinc-300'}">All waves</button>
            ${waves.map(w => {
              const c = WAVE_COLORS[w];
              const active = this.waveFilter === w;
              return `<button type="button" data-sc-wave="${w}" class="text-[9px] font-semibold px-2 py-0.5 rounded-full ring-1 transition ${active ? c.pill : 'text-zinc-600 ring-zinc-700 hover:text-zinc-300'}">W${w}</button>`;
            }).join('')}
          </div>
          <div class="flex gap-1">${['all', 'done', 'in-progress', 'planned'].map(id => {
            const label = { all: 'All', done: 'Done', 'in-progress': 'Active', planned: 'Planned' }[id];
            return `<button type="button" data-sc-progress="${id}" class="text-[9px] px-2 py-0.5 rounded-full ring-1 transition ${this.progressFilter === id ? 'text-zinc-200 bg-zinc-700 ring-zinc-600' : 'text-zinc-600 ring-zinc-700/60 hover:text-zinc-400'}">${label}</button>`;
          }).join('')}</div>
        </div>
      `;

      if (filtered.length === 0) {
        html += '<p class="text-[10px] font-mono text-zinc-700 text-center py-8">No stories match the current filters.</p>';
      } else if (this.viewMode === 'card') {
        html += '<div class="space-y-2.5">';
        filtered.forEach(f => {
          const c = WAVE_COLORS[f.wave];
          const pkgs = (f.packages || []).map(pkg => `<span class="inline-flex items-center gap-1 rounded bg-zinc-800 px-1.5 py-0.5 text-[9px] text-zinc-400">${pkg.name || pkg}${pkg.stars ? ` <span class="text-zinc-600">${pkg.stars}</span>` : ''}</span>`).join('');
          const isSelected = this.selectedFeature && this.selectedFeature.id === f.id;
          html += `
            <div data-sc-feature-id="${f.id}" class="rounded-lg border ${isSelected ? c.border + ' ring-1 ' + c.ring : f.liveStatus === 'done' ? c.border : 'border-zinc-800'} bg-zinc-900/60 p-3 space-y-2 cursor-pointer hover:border-zinc-700 transition-colors">
              <div class="flex items-center gap-2">
                <span class="text-[9px] font-bold px-1.5 py-0.5 rounded ring-1 ${c.pill}">W${f.wave}</span>
                <span class="text-[9px] font-mono text-zinc-600">${f.id}</span>
                <span class="ml-auto text-[9px] font-mono font-bold px-1.5 py-0.5 rounded ring-1 ${statusColor[f.liveStatus]}">${statusLabel[f.liveStatus]}</span>
              </div>
              <h3 class="text-[11px] font-semibold text-zinc-200">${f.title}</h3>
              <p class="text-[10px] text-zinc-500 leading-relaxed">${f.description}</p>
              ${pkgs ? `<div class="flex flex-wrap gap-1">${pkgs}</div>` : ''}
            </div>
          `;
        });
        html += '</div>';
      } else {
        // Hierarchy view
        html += '<div class="space-y-2">';
        waves.filter(w => this.waveFilter === null || w === this.waveFilter).forEach(w => {
          const wFeatures = filtered.filter(f => f.wave === w);
          if (wFeatures.length === 0) return;
          const c = WAVE_COLORS[w];
          const doneCt = wFeatures.filter(f => f.liveStatus === 'done').length;
          const allDone = doneCt === wFeatures.length;

          const storyRows = wFeatures.map(f => {
            const dotColor = statusColor[f.liveStatus].split(' ')[0];
            const isRowSelected = this.selectedFeature && this.selectedFeature.id === f.id;
            return `
              <div data-sc-feature-id="${f.id}" class="w-full flex items-start gap-2 py-1 px-1.5 rounded hover:bg-zinc-800/50 transition text-left cursor-pointer${isRowSelected ? ' bg-zinc-800/70' : ''}">
                <span class="flex-shrink-0 text-[9px] font-mono ${dotColor} mt-0.5">${statusDot[f.liveStatus]}</span>
                <div class="flex-1 min-w-0">
                  <div class="flex items-baseline gap-1.5 flex-wrap">
                    <span class="text-[9px] font-mono text-zinc-600">${f.id}</span>
                    <span class="text-[11px] font-medium ${f.liveStatus === 'done' ? 'text-zinc-400 line-through decoration-zinc-600' : 'text-zinc-300'} leading-tight">${f.title}</span>
                  </div>
                </div>
                <span class="flex-shrink-0 text-[8px] font-mono px-1 py-0.5 rounded ring-1 ${statusColor[f.liveStatus]} ml-1">${statusLabel[f.liveStatus]}</span>
              </div>
            `;
          }).join('');

          html += `
            <div class="rounded-lg border border-zinc-800/60 bg-zinc-900/30 overflow-hidden">
              <div class="w-full flex items-center gap-2.5 px-3 py-2 hover:bg-zinc-800/40 transition text-left cursor-pointer" data-sc-collapse>
                <span class="text-zinc-600"><svg width="11" height="11" viewBox="0 0 11 11" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M3.5 2.5L7.5 5.5L3.5 8.5"/></svg></span>
                <span class="text-[10px] font-bold ${c.text}">W${w}</span>
                <span class="text-[10px] font-medium text-zinc-400">${WAVE_LABELS[w]}</span>
                <span class="ml-auto text-[9px] font-mono text-zinc-600">${doneCt}/${wFeatures.length}</span>
                ${allDone ? `<span class="text-[8px] font-mono font-bold px-1.5 py-0.5 rounded ring-1 ${c.pill}">SHIPPED</span>` : ''}
              </div>
              <div class="px-2 pb-2 space-y-0.5 border-t border-zinc-800/60">${storyRows}</div>
            </div>
          `;
        });
        html += '</div>';
      }

      container.innerHTML = html;

      // Event delegation for filters and view mode — attached once, not on every re-render.
      if (!this._featureClickBound) {
        this._featureClickHandler = (e) => {
          const viewBtn = e.target.closest('[data-sc-view]');
          if (viewBtn) {
            this.viewMode = viewBtn.dataset.scView;
            this._renderFeatureCards();
            return;
          }

          const waveBtn = e.target.closest('[data-sc-wave]');
          if (waveBtn) {
            const w = waveBtn.dataset.scWave;
            this.waveFilter = w === '' ? null : (this.waveFilter === Number(w) ? null : Number(w));
            this._renderFeatureCards();
            return;
          }

          const progBtn = e.target.closest('[data-sc-progress]');
          if (progBtn) {
            this.progressFilter = progBtn.dataset.scProgress;
            this._renderFeatureCards();
            return;
          }

          const collapse = e.target.closest('[data-sc-collapse]');
          if (collapse && collapse.nextElementSibling) {
            collapse.nextElementSibling.classList.toggle('hidden');
            return;
          }

          // Feature card / hierarchy row selection — drives contextual inspector + center tab
          const featureCard = e.target.closest('[data-sc-feature-id]');
          if (featureCard) {
            const featureId = featureCard.dataset.scFeatureId;
            const feature = (this.features || []).find(f => f.id === featureId) || null;
            // Toggle: click the same card again to deselect
            if (this.selectedFeature && this.selectedFeature.id === featureId) {
              this.selectedFeature = null;
              this.selectedFeatureId = null;
            } else {
              this.selectedFeature = feature;
              this.selectedFeatureId = featureId;
            }
            if (feature && this.selectedFeatureId) {
              this._updateCenterForFeature(feature);
              this._updateInspectorForFeature(feature);
            } else {
              this._renderInspector();
            }
            // Re-render cards to update selected highlight
            this._renderFeatureCards();
          }
        };
        container.addEventListener('click', this._featureClickHandler);
        this._featureClickBound = true;
      }
    }

    // ─── Formation Tree (Left column — "formation" template) ────────────────────

    _renderFormationTree() {
      const container = this._q('[data-sc="features-container"]');
      if (!container) return;

      const byWave = {};
      this.features.forEach(f => { byWave[f.wave] = [...(byWave[f.wave] || []), f]; });
      const waves = Object.keys(byWave).map(Number).sort((a, b) => a - b);

      const statusDotClass = (f) => {
        const s = this._resolveStatus(f.id);
        if (s === 'done') return 'bg-emerald-500';
        if (s === 'in-progress') return 'bg-blue-500 animate-pulse';
        return 'bg-zinc-600';
      };

      let html = '<div class="sticky top-0 z-10 bg-zinc-950/95 backdrop-blur-sm pb-2 border-b border-zinc-800/60 mb-3">'
        + '<h2 class="text-[11px] font-bold text-zinc-300">Formation Tree</h2>'
        + '<p class="text-[9px] text-zinc-600 font-mono">' + this.features.length + ' stories \u00b7 ' + waves.length + ' waves</p>'
        + '</div><div class="space-y-1">';

      waves.forEach(w => {
        const stories = byWave[w];
        const c = WAVE_COLORS[w] || WAVE_COLORS[1];
        const doneCt = stories.filter(s => this._resolveStatus(s.id) === 'done').length;
        const allDone = doneCt === stories.length;
        const waveLabel = WAVE_LABELS[w] || ('Wave ' + w);

        const storyItems = stories.map(f => {
          const isSelected = this.selectedNarrativeFeature && this.selectedNarrativeFeature.id === f.id;
          const s = this._resolveStatus(f.id);
          return '<button type="button" data-sc-formation-story="' + f.id + '" class="w-full flex items-center gap-2 px-3 py-1.5 rounded-md text-left transition text-[10px] '
            + (isSelected ? 'bg-zinc-800 text-zinc-200' : 'text-zinc-500 hover:bg-zinc-800/50 hover:text-zinc-300') + '">'
            + '<span class="flex-shrink-0 inline-block h-1.5 w-1.5 rounded-full ' + statusDotClass(f) + '"></span>'
            + '<span class="font-mono text-zinc-700 flex-shrink-0 text-[9px]">' + f.id + '</span>'
            + '<span class="truncate' + (s === 'done' ? ' line-through decoration-zinc-600' : '') + '">' + f.title + '</span>'
            + '</button>';
        }).join('');

        html += '<div class="rounded-lg border border-zinc-800/60 bg-zinc-900/30 overflow-hidden mb-1">'
          + '<button type="button" data-sc-formation-wave="' + w + '" class="w-full flex items-center gap-2 px-3 py-2 hover:bg-zinc-800/40 transition text-left cursor-pointer">'
          + '<span class="text-[10px] font-bold ' + c.text + '">W' + w + '</span>'
          + '<span class="text-[10px] font-medium text-zinc-400">' + waveLabel + '</span>'
          + '<span class="ml-auto text-[9px] font-mono text-zinc-600">' + doneCt + '/' + stories.length + '</span>'
          + (allDone ? '<span class="text-[8px] font-mono font-bold px-1.5 py-0.5 rounded ring-1 ' + c.pill + '">DONE</span>' : '')
          + '</button>'
          + '<div class="pb-1 border-t border-zinc-800/60" data-sc-wave-stories="' + w + '">' + storyItems + '</div>'
          + '</div>';
      });

      html += '</div>';
      container.innerHTML = html;

      container.querySelectorAll('[data-sc-formation-wave]').forEach(btn => {
        btn.addEventListener('click', () => {
          const w = btn.dataset.scFormationWave;
          const storiesEl = container.querySelector('[data-sc-wave-stories="' + w + '"]');
          if (storiesEl) storiesEl.classList.toggle('hidden');
        });
      });

      container.querySelectorAll('[data-sc-formation-story]').forEach(btn => {
        btn.addEventListener('click', () => {
          const id = btn.dataset.scFormationStory;
          this.selectedNarrativeFeature = this.features.find(f => f.id === id) || null;
          this._renderFormationTree();
          this._renderNarrative(this.selectedNarrativeFeature);
        });
      });
    }

    // ─── Narrative Center Column ("formation" template) ──────────────────────────

    _renderNarrative(feature) {
      const container = this._q('[data-sc="architecture-container"]');
      if (!container) return;

      if (!feature) {
        container.innerHTML = '<div class="flex items-center justify-center h-40 text-zinc-700 text-[11px] font-mono">Select a story from the formation tree</div>';
        return;
      }

      const c = WAVE_COLORS[feature.wave] || WAVE_COLORS[1];
      const status = this._resolveStatus(feature.id);
      const statusColors = {
        done: 'text-emerald-400 bg-emerald-500/10 ring-emerald-500/20',
        'in-progress': 'text-blue-400 bg-blue-500/10 ring-blue-500/20',
        planned: 'text-zinc-600 bg-zinc-800/40 ring-zinc-700/30'
      };
      const statusLabel = { done: 'DONE', 'in-progress': 'IN PROGRESS', planned: 'PLANNED' };

      const pkgs = (feature.packages || []).map(pkg =>
        '<span class="inline-flex items-center gap-1 rounded bg-zinc-800 px-2 py-0.5 text-[10px] text-zinc-400 font-mono">' + (pkg.name || pkg) + '</span>'
      ).join('');

      const rawCriteria = feature.acceptance_criteria || feature.acceptanceCriteria || [];
      const criteria = rawCriteria.map(item =>
        '<li class="flex items-start gap-2 text-[11px] text-zinc-400"><span class="flex-shrink-0 text-emerald-500 mt-0.5">&#x2713;</span><span>' + item + '</span></li>'
      ).join('');

      const placeholderSvg = '<svg viewBox="0 0 400 80" xmlns="http://www.w3.org/2000/svg" class="w-full opacity-40">'
        + '<defs><marker id="arr-n" viewBox="0 0 8 6" refX="8" refY="3" markerWidth="6" markerHeight="5" orient="auto-start-reverse"><path d="M0,0 L8,3 L0,6" fill="#52525b"/></marker></defs>'
        + '<rect x="10" y="15" width="100" height="40" rx="6" fill="none" stroke="' + c.stroke + '" stroke-width="1.5" stroke-dasharray="4 3"/>'
        + '<text x="60" y="39" text-anchor="middle" fill="' + c.stroke + '" font-size="9" font-family="monospace">' + feature.id + '</text>'
        + '<line x1="110" y1="35" x2="150" y2="35" stroke="#52525b" stroke-width="1" marker-end="url(#arr-n)"/>'
        + '<rect x="150" y="15" width="100" height="40" rx="6" fill="' + c.hex + '15" stroke="' + c.stroke + '" stroke-width="1.5"/>'
        + '<text x="200" y="33" text-anchor="middle" fill="' + c.stroke + '" font-size="8" font-family="monospace">Implementation</text>'
        + '<text x="200" y="47" text-anchor="middle" fill="#a1a1aa" font-size="7" font-family="monospace">W' + feature.wave + '</text>'
        + '<line x1="250" y1="35" x2="290" y2="35" stroke="#52525b" stroke-width="1" marker-end="url(#arr-n)"/>'
        + '<rect x="290" y="15" width="100" height="40" rx="6" fill="none" stroke="' + (status === 'done' ? '#10b981' : '#3f3f46') + '" stroke-width="1.5"/>'
        + '<text x="340" y="39" text-anchor="middle" fill="' + (status === 'done' ? '#10b981' : '#71717a') + '" font-size="9" font-family="monospace">' + statusLabel[status] + '</text>'
        + '</svg>';

      container.innerHTML = '<div class="space-y-5">'
        + '<div class="flex items-start justify-between gap-3"><div>'
        + '<div class="flex items-center gap-2 mb-1">'
        + '<span class="text-[9px] font-bold px-1.5 py-0.5 rounded ring-1 ' + c.pill + '">W' + feature.wave + '</span>'
        + '<span class="text-[9px] font-mono text-zinc-600">' + feature.id + '</span>'
        + '<span class="text-[9px] font-mono font-bold px-1.5 py-0.5 rounded ring-1 ' + statusColors[status] + '">' + statusLabel[status] + '</span>'
        + '</div>'
        + '<h2 class="text-base font-bold text-zinc-100">' + feature.title + '</h2>'
        + '</div></div>'
        + '<p class="text-[12px] text-zinc-400 leading-relaxed">' + (feature.description || 'No description available.') + '</p>'
        + (criteria ? '<div class="space-y-2"><h3 class="text-[10px] font-bold uppercase tracking-wider text-zinc-600">Acceptance Criteria</h3><ul class="space-y-1.5 pl-1">' + criteria + '</ul></div>' : '')
        + (pkgs ? '<div class="space-y-2"><h3 class="text-[10px] font-bold uppercase tracking-wider text-zinc-600">DRTW Packages</h3><div class="flex flex-wrap gap-1.5">' + pkgs + '</div></div>' : '')
        + '<div class="space-y-2"><h3 class="text-[10px] font-bold uppercase tracking-wider text-zinc-600">Story Diagram</h3>'
        + '<div class="rounded-xl border border-zinc-800 bg-zinc-900/60 p-4 overflow-hidden">' + placeholderSvg + '</div>'
        + '</div></div>';
    }

    // ─── Architecture SVG ───────────────────────────────────────────────────────

    _renderArchitecture() {
      const container = this._q('[data-sc="architecture-container"]');
      if (!container) return;

      const agentCount = this.apmState.agents?.length || 0;
      const apmDot = this.apmState.connected ? '#10b981' : '#ef4444';

      const tabClass = (id) => id === this.archTab
        ? 'px-3 py-1.5 text-[11px] font-semibold rounded-md transition-all bg-zinc-800 text-zinc-200 ring-1 ring-zinc-700'
        : 'px-3 py-1.5 text-[11px] font-medium rounded-md transition-all text-zinc-500 hover:text-zinc-400 hover:bg-zinc-800/40';

      const systemSvg = `<svg viewBox="0 0 800 420" xmlns="http://www.w3.org/2000/svg" class="w-full" role="img" aria-label="CCEM System Architecture">
        <defs>
          <filter id="glow-green" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="3" result="blur"/><feMerge><feMergeNode in="blur"/><feMergeNode in="SourceGraphic"/></feMerge></filter>
          <marker id="arrow" viewBox="0 0 10 7" refX="10" refY="3.5" markerWidth="8" markerHeight="6" orient="auto-start-reverse"><path d="M0,0 L10,3.5 L0,7" fill="#52525b"/></marker>
        </defs>
        <g class="arch-node" style="animation-delay:0.1s"><rect x="180" y="12" width="440" height="70" rx="8" fill="#18181b" stroke="#6366f180" stroke-width="1.5"/><text x="400" y="34" text-anchor="middle" fill="#a5b4fc" font-size="10" font-weight="600" font-family="Inter,sans-serif">BROWSER</text><text x="235" y="58" text-anchor="middle" fill="#a1a1aa" font-size="9" font-family="Inter,sans-serif">Dashboard</text><text x="340" y="58" text-anchor="middle" fill="#a1a1aa" font-size="9" font-family="Inter,sans-serif">19 LiveViews</text><text x="455" y="58" text-anchor="middle" fill="#a1a1aa" font-size="9" font-family="Inter,sans-serif">Notifications</text><text x="565" y="58" text-anchor="middle" fill="#a1a1aa" font-size="9" font-family="Inter,sans-serif">AG-UI Live</text></g>
        <line x1="400" y1="82" x2="400" y2="108" stroke="#52525b" stroke-width="1" marker-end="url(#arrow)" class="arch-edge" stroke-dasharray="4 4"/>
        <g class="arch-node" style="animation-delay:0.2s"><rect x="180" y="108" width="440" height="70" rx="8" fill="#18181b" stroke="#3b82f680" stroke-width="1.5"/><text x="400" y="130" text-anchor="middle" fill="#93c5fd" font-size="10" font-weight="600" font-family="Inter,sans-serif">PHOENIX API LAYER</text><text x="255" y="155" text-anchor="middle" fill="#a1a1aa" font-size="9" font-family="Inter,sans-serif">REST (56 endpoints)</text><text x="400" y="155" text-anchor="middle" fill="#a1a1aa" font-size="9" font-family="Inter,sans-serif">AG-UI SSE</text><text x="530" y="155" text-anchor="middle" fill="#a1a1aa" font-size="9" font-family="Inter,sans-serif">OpenAPI 3.0.3</text></g>
        <line x1="400" y1="178" x2="400" y2="204" stroke="#52525b" stroke-width="1" marker-end="url(#arrow)" class="arch-edge" stroke-dasharray="4 4"/>
        <g class="arch-node" style="animation-delay:0.3s"><rect x="40" y="204" width="720" height="100" rx="8" fill="#18181b" stroke="#a855f780" stroke-width="1.5"/><text x="400" y="226" text-anchor="middle" fill="#c4b5fd" font-size="10" font-weight="600" font-family="Inter,sans-serif">OTP GENSERVERS</text><rect x="60" y="240" width="120" height="28" rx="4" fill="#10b98115" stroke="#10b98140" stroke-width="1"/><text x="120" y="258" text-anchor="middle" fill="#6ee7b7" font-size="8" font-family="'Fira Code',monospace">AgentRegistry</text><rect x="195" y="240" width="110" height="28" rx="4" fill="#10b98115" stroke="#10b98140" stroke-width="1"/><text x="250" y="258" text-anchor="middle" fill="#6ee7b7" font-size="8" font-family="'Fira Code',monospace">EventRouter</text><rect x="320" y="240" width="110" height="28" rx="4" fill="#10b98115" stroke="#10b98140" stroke-width="1"/><text x="375" y="258" text-anchor="middle" fill="#6ee7b7" font-size="8" font-family="'Fira Code',monospace">StateManager</text><rect x="445" y="240" width="110" height="28" rx="4" fill="#10b98115" stroke="#10b98140" stroke-width="1"/><text x="500" y="258" text-anchor="middle" fill="#6ee7b7" font-size="8" font-family="'Fira Code',monospace">FormationStore</text><rect x="570" y="240" width="120" height="28" rx="4" fill="#10b98115" stroke="#10b98140" stroke-width="1"/><text x="630" y="258" text-anchor="middle" fill="#6ee7b7" font-size="8" font-family="'Fira Code',monospace">MetricsCollector</text><rect x="60" y="275" width="95" height="22" rx="4" fill="#3b82f610" stroke="#3b82f630" stroke-width="1"/><text x="107" y="290" text-anchor="middle" fill="#93c5fd" font-size="7" font-family="'Fira Code',monospace">ChatStore</text><rect x="170" y="275" width="115" height="22" rx="4" fill="#3b82f610" stroke="#3b82f630" stroke-width="1"/><text x="227" y="290" text-anchor="middle" fill="#93c5fd" font-size="7" font-family="'Fira Code',monospace">SkillsRegistry</text><rect x="300" y="275" width="115" height="22" rx="4" fill="#3b82f610" stroke="#3b82f630" stroke-width="1"/><text x="357" y="290" text-anchor="middle" fill="#93c5fd" font-size="7" font-family="'Fira Code',monospace">BackgroundTasks</text><rect x="430" y="275" width="115" height="22" rx="4" fill="#3b82f610" stroke="#3b82f630" stroke-width="1"/><text x="487" y="290" text-anchor="middle" fill="#93c5fd" font-size="7" font-family="'Fira Code',monospace">ProjectScanner</text><rect x="560" y="275" width="105" height="22" rx="4" fill="#3b82f610" stroke="#3b82f630" stroke-width="1"/><text x="612" y="290" text-anchor="middle" fill="#93c5fd" font-size="7" font-family="'Fira Code',monospace">ActionEngine</text></g>
        <g class="arch-node" style="animation-delay:0.4s"><rect x="40" y="340" width="200" height="65" rx="8" fill="#18181b" stroke="#f59e0b60" stroke-width="1.5" stroke-dasharray="6 3"/><text x="140" y="362" text-anchor="middle" fill="#fcd34d" font-size="10" font-weight="600" font-family="Inter,sans-serif">CLAUDE CODE</text><text x="100" y="385" text-anchor="middle" fill="#a1a1aa" font-size="8" font-family="Inter,sans-serif">Session Hooks</text><text x="180" y="385" text-anchor="middle" fill="#a1a1aa" font-size="8" font-family="Inter,sans-serif">Agents</text></g>
        <line x1="140" y1="340" x2="200" y2="304" stroke="#f59e0b50" stroke-width="1" marker-end="url(#arrow)" class="arch-edge" stroke-dasharray="4 4"/>
        <g class="arch-node" style="animation-delay:0.5s"><rect x="560" y="340" width="200" height="65" rx="8" fill="#18181b" stroke="#ef444460" stroke-width="1.5" stroke-dasharray="6 3"/><text x="660" y="362" text-anchor="middle" fill="#fca5a5" font-size="10" font-weight="600" font-family="Inter,sans-serif">CCEMAGENT</text><text x="620" y="385" text-anchor="middle" fill="#a1a1aa" font-size="8" font-family="Inter,sans-serif">macOS MenuBar</text><text x="710" y="385" text-anchor="middle" fill="#a1a1aa" font-size="8" font-family="Inter,sans-serif">Swift/AppKit</text></g>
        <line x1="660" y1="340" x2="600" y2="304" stroke="#ef444450" stroke-width="1" marker-end="url(#arrow)" class="arch-edge" stroke-dasharray="4 4"/>
        <g class="arch-node" style="animation-delay:0.6s"><rect x="290" y="340" width="220" height="65" rx="8" fill="#18181b" stroke="#6366f140" stroke-width="1" stroke-dasharray="6 3"/><text x="400" y="362" text-anchor="middle" fill="#a5b4fc" font-size="10" font-weight="600" font-family="Inter,sans-serif">EXTERNAL INTEGRATIONS</text><text x="340" y="385" text-anchor="middle" fill="#a1a1aa" font-size="8" font-family="Inter,sans-serif">Plane PM</text><text x="410" y="385" text-anchor="middle" fill="#a1a1aa" font-size="8" font-family="Inter,sans-serif">Linear</text><text x="470" y="385" text-anchor="middle" fill="#a1a1aa" font-size="8" font-family="Inter,sans-serif">GitHub</text></g>
        <line x1="400" y1="340" x2="400" y2="304" stroke="#6366f140" stroke-width="1" marker-end="url(#arrow)" class="arch-edge" stroke-dasharray="4 4"/>
        <circle cx="18" cy="18" r="6" fill="${apmDot}" filter="url(#glow-green)" class="dot-pulse"/><text x="30" y="22" fill="#a1a1aa" font-size="8" font-family="'Fira Code',monospace">APM ${this.apmState.connected ? 'LIVE' : 'OFFLINE'}</text>
      </svg>`;

      container.innerHTML = `
        <div class="space-y-3">
          <div class="flex items-center justify-between">
            <h2 class="text-sm font-bold text-zinc-300">Architecture</h2>
            <div class="flex items-center gap-2">
              <span class="inline-block h-2 w-2 rounded-full dot-pulse" style="background:${apmDot}"></span>
              <span class="text-[10px] font-mono text-zinc-600">${agentCount} agents registered</span>
            </div>
          </div>
          <div class="flex flex-wrap items-center gap-1 rounded-lg bg-zinc-900/80 p-1 ring-1 ring-zinc-800">
            <button data-sc-arch-tab="system" class="${tabClass('system')}">System</button>
            <button data-sc-arch-tab="npm" class="${tabClass('npm')}">npm Packages</button>
            <button data-sc-arch-tab="formation-flow" class="${tabClass('formation-flow')}">Formation Flow</button>
            <button data-sc-arch-tab="upm-flow" class="${tabClass('upm-flow')}">UPM Flow</button>
            <button data-sc-arch-tab="ralph-flow" class="${tabClass('ralph-flow')}">Ralph Flow</button>
            <button data-sc-arch-tab="activity" class="${tabClass('activity')}">Activity</button>
          </div>
          ${(() => {
            const feat = this.selectedFeature || (this.selectedFeatureId ? (this.features || []).find(f => f.id === this.selectedFeatureId) : null);
            if (!feat) return '';
            const fc = WAVE_COLORS[feat.wave] || WAVE_COLORS[1];
            return `<div class="rounded-lg border ${fc.border} bg-zinc-900/40 px-4 py-3 space-y-1">
              <div class="flex items-center gap-2">
                <span class="text-[9px] font-bold px-1.5 py-0.5 rounded ring-1 ${fc.pill}">W${feat.wave}</span>
                <span class="text-[9px] font-mono text-zinc-600">${feat.id}</span>
                ${feat.wave ? '<span class="text-[9px] font-mono text-zinc-600">&middot; ' + (WAVE_LABELS[feat.wave] || '') + '</span>' : ''}
              </div>
              <p class="text-[11px] font-semibold text-zinc-200">${feat.title}</p>
              <p class="text-[10px] text-zinc-500 leading-relaxed">${feat.description}</p>
            </div>`;
          })()}
          <div class="rounded-xl border border-zinc-800 bg-zinc-900/60 p-4 overflow-hidden">
            <div data-sc-arch="system" style="display:${this.archTab === 'system' ? 'block' : 'none'}">
              ${systemSvg}
            </div>
            <div data-sc-arch="npm" style="display:${this.archTab === 'npm' ? 'block' : 'none'}">
              <div data-sc="npm-svg-host"></div>
            </div>
            <div data-sc-arch="formation-flow" style="display:${this.archTab === 'formation-flow' ? 'block' : 'none'}">
              ${this.archTab === 'formation-flow' ? this._renderFormationFlowTab() : ''}
            </div>
            <div data-sc-arch="upm-flow" style="display:${this.archTab === 'upm-flow' ? 'block' : 'none'}">
              ${this.archTab === 'upm-flow' ? this._renderUpmFlowTab() : ''}
            </div>
            <div data-sc-arch="ralph-flow" style="display:${this.archTab === 'ralph-flow' ? 'block' : 'none'}">
              ${this.archTab === 'ralph-flow' ? this._renderRalphFlowTab() : ''}
            </div>
            <div data-sc-arch="activity" style="display:${this.archTab === 'activity' ? 'block' : 'none'}">
              ${this.archTab === 'activity' ? this._renderActivityTabHtml() : ''}
            </div>
          </div>
        </div>
      `;

      // Tab click handlers
      container.querySelectorAll('[data-sc-arch-tab]').forEach(btn => {
        btn.addEventListener('click', () => {
          this.archTab = btn.dataset.scArchTab;
          this._renderArchitecture();
        });
      });

      // Activity log toggle
      if (this.archTab === 'activity') {
        this._bindActivityLogToggle(container);
        if (Object.keys(this.activityData.agents || {}).length > 0) {
          this._renderActivityGraph(container);
        }
      }

      // Load npm SVG
      if (this.archTab === 'npm') {
        const host = this._q('[data-sc="npm-svg-host"]');
        if (this.npmSvgCache) {
          host.innerHTML = this.npmSvgCache;
        } else {
          host.innerHTML = '<p class="text-center text-xs text-zinc-600 py-8">Loading diagram...</p>';
          fetch(`${this.basePath}/diagrams/npm-packages.svg`)
            .then(r => r.text())
            .then(svg => {
              this.npmSvgCache = svg;
              const current = this._q('[data-sc="npm-svg-host"]');
              if (current) current.innerHTML = svg;
            })
            .catch(() => {
              const current = this._q('[data-sc="npm-svg-host"]');
              if (current) current.innerHTML = '<p class="text-center text-xs text-red-400 py-8">Failed to load npm-packages.svg</p>';
            });
        }
      }
    }

    // ─── Feature Selection Helpers ─────────────────────────────────────────────

    /**
     * _updateCenterForFeature — switches the center tab to the most relevant view
     * for the selected feature and re-renders the architecture panel.
     */
    _updateCenterForFeature(feature) {
      const wave = feature.wave || 0;
      // Wave 1-2 → formation context; US- stories → UPM flow; others → Ralph loop
      if (wave <= 2) {
        this.archTab = 'formation-flow';
      } else if (feature.id && feature.id.toUpperCase().includes('US-')) {
        this.archTab = 'upm-flow';
      } else {
        this.archTab = 'ralph-flow';
      }
      this._renderArchitecture();
    }

    /**
     * _updateInspectorForFeature — triggers inspector re-render to show feature context.
     * The inspector reads this.selectedFeature / this.selectedFeatureId.
     */
    _updateInspectorForFeature(_feature) {
      this._renderInspector();
    }

    // ─── Center Tab Renderers ───────────────────────────────────────────────────

    _renderFormationFlowTab() {
      const fmtId = this.orchState.formationId
        ? (this.orchState.formationId.length > 22 ? '…' + this.orchState.formationId.slice(-18) : this.orchState.formationId)
        : 'fmt-ccem-v6-20260317';
      const wave = this.orchState.wave || 1;
      const agentsActive = this.orchState.agentsActive || 0;
      const waveColor = (WAVE_COLORS[wave] || WAVE_COLORS[1]).hex;

      const nodeW = 110, nodeH = 34, gap = 50, startX = 20, startY = 20;
      const levels = [
        { label: 'Session',   color: '#6366f1', stroke: '#818cf8' },
        { label: 'Formation', color: '#a855f7', stroke: '#c084fc', sub: fmtId },
        { label: 'Wave ' + wave, color: waveColor, stroke: waveColor + 'cc' },
        { label: 'Squadron',  color: '#3b82f6', stroke: '#60a5fa' },
        { label: 'Swarm',     color: '#10b981', stroke: '#34d399', sub: agentsActive > 0 ? agentsActive + ' active' : null },
        { label: 'Agent',     color: '#f59e0b', stroke: '#fbbf24' },
        { label: 'Task',      color: '#ef4444', stroke: '#f87171' },
      ];
      const svgH = levels.length * (nodeH + gap) - gap + 40;
      const svgW = nodeW + startX * 2;

      const nodes = levels.map((l, i) => {
        const y = startY + i * (nodeH + gap);
        const cx = startX + nodeW / 2;
        const connector = i < levels.length - 1
          ? '<line x1="' + cx + '" y1="' + (y + nodeH) + '" x2="' + cx + '" y2="' + (y + nodeH + gap) + '" stroke="#3f3f46" stroke-width="1.5" stroke-dasharray="4 3" marker-end="url(#fmt-arrow)"/>'
          : '';
        const subText = l.sub
          ? '<text x="' + cx + '" y="' + (y + nodeH + 14) + '" text-anchor="middle" fill="#71717a" font-size="7" font-family="&#39;Fira Code&#39;,monospace">' + l.sub + '</text>'
          : '';
        return '<rect x="' + startX + '" y="' + y + '" width="' + nodeW + '" height="' + nodeH + '" rx="6" fill="' + l.color + '18" stroke="' + l.stroke + '" stroke-width="1.5"/>'
          + '<text x="' + cx + '" y="' + (y + nodeH / 2 + 4) + '" text-anchor="middle" fill="' + l.stroke + '" font-size="10" font-weight="600" font-family="Inter,sans-serif">' + l.label + '</text>'
          + connector + subText;
      }).join('');

      return '<svg viewBox="0 0 ' + svgW + ' ' + (svgH + 20) + '" xmlns="http://www.w3.org/2000/svg" class="w-full max-w-xs mx-auto" role="img" aria-label="Formation Hierarchy">'
        + '<defs><marker id="fmt-arrow" viewBox="0 0 10 7" refX="10" refY="3.5" markerWidth="7" markerHeight="5" orient="auto-start-reverse"><path d="M0,0 L10,3.5 L0,7" fill="#52525b"/></marker></defs>'
        + nodes + '</svg>';
    }

    _renderUpmFlowTab() {
      const phase = this.orchState.phase || 'build';
      const wave  = this.orchState.wave || 1;
      const tsc   = this.orchState.tsc || 'PASS';

      const stages = [
        { id: 'plan',   label: 'Plan',     color: '#3b82f6', stroke: '#60a5fa' },
        { id: 'w1',     label: 'Wave 1',   color: '#10b981', stroke: '#34d399' },
        { id: 'tsc1',   label: 'TSC',      color: '#a855f7', stroke: '#c084fc', gate: true },
        { id: 'w2',     label: 'Wave 2',   color: '#10b981', stroke: '#34d399' },
        { id: 'tsc2',   label: 'TSC',      color: '#a855f7', stroke: '#c084fc', gate: true },
        { id: 'verify', label: 'Verify',   color: '#f59e0b', stroke: '#fbbf24' },
        { id: 'ship',   label: 'Ship',     color: '#ef4444', stroke: '#f87171' },
      ];

      let activeIdx = 0;
      if (phase === 'plan') activeIdx = 0;
      else if (phase === 'build' && wave <= 1) activeIdx = 1;
      else if (phase === 'build' && wave >= 2) activeIdx = 3;
      else if (phase === 'verify') activeIdx = 5;
      else if (phase === 'ship') activeIdx = 6;

      const boxW = 66, boxH = 38, gap = 18, startY = 30, radius = 6;
      const totalW = stages.length * (boxW + gap) - gap + 40;
      const arrowY = startY + boxH / 2;

      const boxes = stages.map((s, i) => {
        const x = 20 + i * (boxW + gap);
        const isActive = i === activeIdx;
        const isDone   = i < activeIdx;
        const fill     = isActive ? s.color + '30' : isDone ? s.color + '18' : '#18181b';
        const stroke   = isActive ? s.stroke : isDone ? s.stroke + '80' : '#3f3f46';
        const textFill = isActive ? s.stroke : isDone ? s.stroke + '99' : '#52525b';
        const arrow = i < stages.length - 1
          ? '<line x1="' + (x + boxW) + '" y1="' + arrowY + '" x2="' + (x + boxW + gap) + '" y2="' + arrowY + '" stroke="' + (isDone ? s.stroke + '60' : '#3f3f46') + '" stroke-width="1.5" marker-end="url(#upm-arrow)"/>'
          : '';
        const pulse = isActive
          ? '<circle cx="' + (x + boxW - 7) + '" cy="' + (startY + 7) + '" r="3" fill="' + s.stroke + '"><animate attributeName="opacity" values="1;0.3;1" dur="2s" repeatCount="indefinite"/></circle>'
          : '';
        const shape = s.gate
          ? '<polygon points="' + (x + boxW / 2) + ',' + startY + ' ' + (x + boxW) + ',' + (startY + boxH / 2) + ' ' + (x + boxW / 2) + ',' + (startY + boxH) + ' ' + x + ',' + (startY + boxH / 2) + '" fill="' + fill + '" stroke="' + stroke + '" stroke-width="1.5"/>'
          : '<rect x="' + x + '" y="' + startY + '" width="' + boxW + '" height="' + boxH + '" rx="' + radius + '" fill="' + fill + '" stroke="' + stroke + '" stroke-width="1.5"/>';
        return shape
          + '<text x="' + (x + boxW / 2) + '" y="' + (startY + boxH / 2 + 4) + '" text-anchor="middle" fill="' + textFill + '" font-size="9" font-weight="' + (isActive ? '700' : '500') + '" font-family="Inter,sans-serif">' + s.label + '</text>'
          + pulse + arrow;
      }).join('');

      const tscBadge = '<text x="' + (totalW / 2) + '" y="' + (startY + boxH + 24) + '" text-anchor="middle" fill="' + (tsc === 'PASS' ? '#10b981' : '#ef4444') + '" font-size="9" font-family="&#39;Fira Code&#39;,monospace">tsc: ' + tsc + '</text>';

      return '<svg viewBox="0 0 ' + totalW + ' ' + (startY + boxH + 40) + '" xmlns="http://www.w3.org/2000/svg" class="w-full" role="img" aria-label="UPM Workflow Pipeline">'
        + '<defs><marker id="upm-arrow" viewBox="0 0 10 7" refX="10" refY="3.5" markerWidth="7" markerHeight="5" orient="auto-start-reverse"><path d="M0,0 L10,3.5 L0,7" fill="#52525b"/></marker></defs>'
        + boxes + tscBadge + '</svg>';
    }

    _renderRalphFlowTab() {
      const phase = this.orchState.phase || 'build';

      const steps = [
        { label: 'Read PRD',   color: '#6366f1', stroke: '#818cf8' },
        { label: 'Find Story', color: '#3b82f6', stroke: '#60a5fa' },
        { label: 'Implement',  color: '#10b981', stroke: '#34d399' },
        { label: 'Compile',    color: '#a855f7', stroke: '#c084fc' },
        { label: 'Test',       color: '#f59e0b', stroke: '#fbbf24' },
        { label: 'Commit',     color: '#ef4444', stroke: '#f87171' },
        { label: 'Update PRD', color: '#6366f1', stroke: '#818cf8' },
      ];

      const phaseMap = { plan: 0, build: 2, verify: 4, ship: 6 };
      const activeIdx = phaseMap[phase] !== undefined ? phaseMap[phase] : 2;

      const cx = 200, cy = 150, rx = 140, ry = 110, n = steps.length, boxW = 80, boxH = 28;

      const nodes = steps.map((s, i) => {
        const angle  = (2 * Math.PI * i / n) - Math.PI / 2;
        const nx = cx + rx * Math.cos(angle);
        const ny = cy + ry * Math.sin(angle);
        const isActive = i === activeIdx;
        const fill     = isActive ? s.color + '30' : '#18181b';
        const stroke   = isActive ? s.stroke : '#3f3f46';
        const textFill = isActive ? s.stroke : '#52525b';
        const pulse = isActive
          ? '<circle cx="' + nx.toFixed(1) + '" cy="' + ny.toFixed(1) + '" r="' + (boxW / 2 + 4) + '" fill="none" stroke="' + s.stroke + '" stroke-width="1" opacity="0.4"><animate attributeName="r" from="' + (boxW / 2) + '" to="' + (boxW / 2 + 8) + '" dur="2s" repeatCount="indefinite"/><animate attributeName="opacity" from="0.4" to="0" dur="2s" repeatCount="indefinite"/></circle>'
          : '';
        const nextAngle = (2 * Math.PI * ((i + 1) % n) / n) - Math.PI / 2;
        const nx2 = cx + rx * Math.cos(nextAngle);
        const ny2 = cy + ry * Math.sin(nextAngle);
        const connector = '<path d="M' + nx.toFixed(1) + ',' + ny.toFixed(1) + ' Q' + cx + ',' + cy + ' ' + nx2.toFixed(1) + ',' + ny2.toFixed(1) + '" fill="none" stroke="' + (isActive ? s.stroke + '60' : '#27272a') + '" stroke-width="1.5" marker-end="url(#ralph-arrow)"/>';
        return pulse
          + '<rect x="' + (nx - boxW / 2).toFixed(1) + '" y="' + (ny - boxH / 2).toFixed(1) + '" width="' + boxW + '" height="' + boxH + '" rx="5" fill="' + fill + '" stroke="' + stroke + '" stroke-width="1.5"/>'
          + '<text x="' + nx.toFixed(1) + '" y="' + (ny + 5).toFixed(1) + '" text-anchor="middle" fill="' + textFill + '" font-size="9" font-weight="' + (isActive ? '700' : '500') + '" font-family="Inter,sans-serif">' + s.label + '</text>'
          + connector;
      }).join('');

      return '<svg viewBox="0 0 400 300" xmlns="http://www.w3.org/2000/svg" class="w-full" role="img" aria-label="Ralph Autonomous Agent Loop">'
        + '<defs><marker id="ralph-arrow" viewBox="0 0 10 7" refX="10" refY="3.5" markerWidth="7" markerHeight="5" orient="auto-start-reverse"><path d="M0,0 L10,3.5 L0,7" fill="#52525b"/></marker></defs>'
        + '<circle cx="' + cx + '" cy="' + cy + '" r="55" fill="none" stroke="#27272a" stroke-width="1" stroke-dasharray="6 4"/>'
        + '<text x="' + cx + '" y="' + (cy - 8) + '" text-anchor="middle" fill="#52525b" font-size="8" font-family="&#39;Fira Code&#39;,monospace">ralph</text>'
        + '<text x="' + cx + '" y="' + (cy + 8) + '" text-anchor="middle" fill="#3f3f46" font-size="8" font-family="Inter,sans-serif">autonomous loop</text>'
        + nodes + '</svg>';
    }

    // ─── Lottie Loader ─────────────────────────────────────────────────────────

    _loadLottie(host) {
      if (window.lottie) { this._attachLottieAnimation(host); return; }
      if (this._lottieLoading) return;
      this._lottieLoading = true;
      const script = document.createElement('script');
      script.src = 'https://cdnjs.cloudflare.com/ajax/libs/lottie-web/5.12.2/lottie.min.js';
      script.crossOrigin = 'anonymous';
      script.onload = () => {
        this._lottieLoading = false;
        const liveHost = host.isConnected ? host : (this.container && this.container.querySelector('[id^="sc-lottie-host-"]'));
        if (liveHost) this._attachLottieAnimation(liveHost);
      };
      script.onerror = () => { this._lottieLoading = false; };
      document.head.appendChild(script);
    }

    _attachLottieAnimation(host) {
      if (!window.lottie || !host) return;
      host.innerHTML = '';
      const animData = {
        v: '5.7.4', fr: 30, ip: 0, op: 60, w: 32, h: 32, nm: 'pulse', ddd: 0, assets: [],
        layers: [0, 1, 2].map((i) => ({
          ddd: 0, ind: i + 1, ty: 4, nm: 'dot' + i,
          ks: {
            o: { a: 1, k: [{ t: i * 10, s: [20], e: [80] }, { t: i * 10 + 20, s: [80], e: [20] }, { t: 60, s: [20] }] },
            r: { a: 0, k: 0 }, p: { a: 0, k: [8 + i * 8, 16, 0] },
            a: { a: 0, k: [0, 0, 0] }, s: { a: 0, k: [100, 100, 100] }
          },
          shapes: [
            { ty: 'el', nm: 'Ellipse', p: { a: 0, k: [0, 0] }, s: { a: 0, k: [6, 6] } },
            { ty: 'fl', nm: 'Fill', c: { a: 0, k: [0.063, 0.725, 0.506, 1] }, o: { a: 0, k: 100 } }
          ],
          ip: 0, op: 60, st: 0
        }))
      };
      try { window.lottie.loadAnimation({ container: host, renderer: 'svg', loop: true, autoplay: true, animationData: animData }); }
      catch (_e) { /* CSS fallback remains */ }
    }

    // ─── Inspector Panel (Right) ────────────────────────────────────────────────

    // Shared helpers — used by both default and feature inspector views.
    _inspectorSection(title, content) {
      return `<div class="space-y-1"><h3 class="text-[10px] font-bold uppercase tracking-wider text-zinc-600">${title}</h3><div class="rounded-lg border border-zinc-800 bg-zinc-900/60 px-3 divide-y divide-zinc-800/60">${content}</div></div>`;
    }

    _inspectorRow(label, value, dot) {
      const dotHtml = dot ? `<span class="inline-block h-2 w-2 flex-shrink-0 rounded-full ${STATUS_COLORS[dot]?.dot || ''}"></span>` : '';
      return `<div class="flex items-center justify-between py-1.5"><div class="flex items-center gap-2">${dotHtml}<span class="text-xs text-zinc-400">${label}</span></div><span class="font-mono text-[10px] text-zinc-300 truncate max-w-[140px]" title="${value}">${value}</span></div>`;
    }

    _renderInspector() {
      const container = this._q('[data-sc="inspector-container"]');
      if (!container) return;

      // Route to contextual feature inspector when a feature is selected
      const selectedFeat = this.selectedFeature || (this.selectedFeatureId ? (this.features || []).find(f => f.id === this.selectedFeatureId) : null);
      if (selectedFeat) {
        this._renderInspectorForFeature(selectedFeat, container);
        return;
      }

      // Default inspector — APM health, services, stack info
      const now = this.apmState.lastPoll ? this.apmState.lastPoll.toLocaleTimeString() : 'waiting...';
      const overall = this.apmState.connected ? 'green' : 'red';

      let html = `
        <div class="flex items-center justify-between">
          <h2 class="text-sm font-bold text-zinc-300">Resource Inspector</h2>
          <div class="flex items-center gap-1.5">
            <span class="inline-block h-2 w-2 rounded-full ${STATUS_COLORS[overall].dot}"></span>
            <span class="text-[10px] text-zinc-600">${now}</span>
          </div>
        </div>
        <p class="text-[10px] text-zinc-600 flex items-center gap-1.5">
          <span class="text-zinc-700">&#x2190;</span>
          <span>Select an item to inspect</span>
        </p>
      `;

      const services = [
        { label: 'CCEM APM', status: this.apmState.connected ? 'green' : 'red', detail: this.apmState.connected ? 'localhost:3032' : 'unreachable' },
        { label: 'AG-UI EventRouter', status: this.apmState.connected ? 'green' : 'unknown', detail: this.apmState.connected ? 'routing' : 'unknown' },
        { label: 'CCEMAgent', status: 'amber', detail: 'menubar app' },
      ];
      html += this._inspectorSection('Services', services.map(s => `<div class="flex items-center justify-between py-1.5"><div class="flex items-center gap-2 min-w-0"><span class="inline-block h-2 w-2 flex-shrink-0 rounded-full ${STATUS_COLORS[s.status].dot}"></span><span class="text-xs text-zinc-300 truncate">${s.label}</span></div><span class="text-[10px] font-mono ${STATUS_COLORS[s.status].text} truncate max-w-[140px]">${s.detail}</span></div>`).join(''));

      if (this.apmState.status) {
        const st = this.apmState.status;
        html += this._inspectorSection('APM Status', [
          this._inspectorRow('Server', st.server || 'APM v5', 'green'),
          this._inspectorRow('Uptime', st.uptime || 'unknown'),
          this._inspectorRow('Agents', String(this.apmState.agents?.length || 0)),
          this._inspectorRow('Version', st.version || this.version),
        ].join(''));
      }

      if (this.apmState.agents && this.apmState.agents.length > 0) {
        html += this._inspectorSection(`Agents (${this.apmState.agents.length})`, this.apmState.agents.slice(0, 8).map(a => `<div class="flex items-center justify-between py-1.5"><div class="flex items-center gap-2 min-w-0"><span class="inline-block h-2 w-2 flex-shrink-0 rounded-full ${a.status === 'active' ? STATUS_COLORS.green.dot : STATUS_COLORS.unknown.dot}"></span><span class="text-[10px] text-zinc-400 truncate font-mono">${a.agent_id || a.id || 'unknown'}</span></div><span class="text-[9px] font-mono text-zinc-600">${a.status || 'idle'}</span></div>`).join(''));
      }

      html += this._inspectorSection('Git', [this._inspectorRow('Branch', 'main'), this._inspectorRow('Version', this.version), this._inspectorRow('Repo', 'peguesj/ccem-apm')].join(''));
      html += this._inspectorSection('Stack', [this._inspectorRow('Runtime', 'Elixir/OTP 27'), this._inspectorRow('Framework', 'Phoenix 1.7'), this._inspectorRow('UI', 'LiveView + daisyUI'), this._inspectorRow('Protocol', 'AG-UI (ag_ui_ex)'), this._inspectorRow('Agent', 'Swift/AppKit'), this._inspectorRow('Installer', 'Bash modular')].join(''));
      html += this._inspectorSection('DRTW Libraries', [this._inspectorRow('ag_ui_ex', 'v0.1.0 (Hex)'), this._inspectorRow('Phoenix', 'v1.7.x'), this._inspectorRow('LiveView', 'v1.0.x'), this._inspectorRow('Jason', 'JSON codec'), this._inspectorRow('Bandit', 'HTTP server'), this._inspectorRow('Tailwind', 'v3.x')].join(''));
      html += this._inspectorSection('Key Endpoints', [this._inspectorRow('/api/status', 'GET', 'green'), this._inspectorRow('/api/agents', 'GET', 'green'), this._inspectorRow('/api/register', 'POST', 'green'), this._inspectorRow('/api/heartbeat', 'POST', 'green'), this._inspectorRow('/api/ag-ui/events', 'SSE', 'green'), this._inspectorRow('/api/v2/openapi.json', 'GET', 'green'), this._inspectorRow('/uat', 'LiveView', 'green')].join(''));

      // CSS-only pulsing active status (no Lottie dependency)
      const showActive = this.apmState.connected && (this.orchState.wave > 0);
      if (showActive) {
        html += '<div class="space-y-1">'
          + '<h3 class="text-[10px] font-bold uppercase tracking-wider text-zinc-600">Active Status</h3>'
          + '<div class="rounded-lg border border-zinc-800 bg-zinc-900/60 px-3 py-2 flex items-center gap-3">'
          + '<span class="sc-status-pulse flex-shrink-0"></span>'
          + '<div><div class="text-[10px] font-semibold text-emerald-400">Active</div>'
          + '<div class="text-[9px] text-zinc-600 font-mono">W' + this.orchState.wave + '/' + this.orchState.totalWaves + ' &middot; ' + this.orchState.agentsActive + ' agents</div>'
          + '</div></div></div>';
      }

      container.innerHTML = html;
    }

    /**
     * _renderInspectorForFeature — contextual right-panel inspector for a selected feature.
     *
     * Renders: feature header (ID badge, title, status dot, wave badge), full description,
     * acceptance criteria checklist, related agents (filtered by story_id), timing rows,
     * status history mini-timeline (CSS-only pulsing dot for active status),
     * and action buttons: "View Formation" (pushes event to LiveView) + "Copy ID".
     *
     * Called by _renderInspector() when this.selectedFeature is set.
     * Deselect via the × button restores the default inspector.
     */
    _renderInspectorForFeature(feature, container) {
      const c = WAVE_COLORS[feature.wave] || WAVE_COLORS[1];
      const status = this._resolveStatus(feature.id);
      const statusLabel = { done: 'DONE', 'in-progress': 'IN PROGRESS', planned: 'PLANNED' };
      const statusColor = {
        done: 'text-emerald-400 bg-emerald-500/10 ring-emerald-500/20',
        'in-progress': 'text-blue-400 bg-blue-500/10 ring-blue-500/20',
        planned: 'text-zinc-500 bg-zinc-800/40 ring-zinc-700/30'
      };
      const isActive = status === 'in-progress';

      // Related agents — filtered by story_id matching feature.id
      const relatedAgents = (this.apmState.agents || []).filter(a => a.story_id === feature.id);

      // Acceptance criteria
      const criteria = feature.acceptance_criteria || feature.criteria || [];

      // Relative time helper
      function relTime(iso) {
        if (!iso) return null;
        const diff = Date.now() - new Date(iso).getTime();
        const sec = Math.floor(diff / 1000);
        if (sec < 60) return sec + 's ago';
        const min = Math.floor(sec / 60);
        if (min < 60) return min + 'm ago';
        const hr = Math.floor(min / 60);
        if (hr < 24) return hr + 'h ago';
        return Math.floor(hr / 24) + 'd ago';
      }

      // Status history mini-timeline — up to 5 entries; CSS-only animation
      const history = feature.status_history || [];
      const activeDotClass = 'h-2 w-2 rounded-full bg-blue-400 animate-pulse shadow-sm shadow-blue-400/60 flex-shrink-0';
      const doneDotClass = 'h-2 w-2 rounded-full bg-emerald-500 flex-shrink-0';
      const idleDotClass = 'h-2 w-2 rounded-full bg-zinc-600 flex-shrink-0';

      let timelineItems;
      if (history.length > 0) {
        timelineItems = history.slice(-5).map((h, i, arr) => {
          const isLast = i === arr.length - 1;
          const dotClass = isLast && isActive ? activeDotClass : isLast && status === 'done' ? doneDotClass : idleDotClass;
          const label = typeof h === 'object' ? (h.status || h.label || JSON.stringify(h)) : String(h);
          const ts = h.at ? relTime(h.at) : null;
          return '<div class="flex items-center gap-1.5 min-w-0">'
            + '<span class="' + dotClass + '"></span>'
            + '<span class="text-[9px] font-mono text-zinc-500 truncate">' + label + '</span>'
            + (ts ? '<span class="text-[8px] text-zinc-700 ml-auto flex-shrink-0">' + ts + '</span>' : '')
            + '</div>';
        }).join('');
      } else {
        const currentDotClass = isActive ? activeDotClass : status === 'done' ? doneDotClass : idleDotClass;
        timelineItems = '<div class="flex items-center gap-1.5">'
          + '<span class="' + currentDotClass + '"></span>'
          + '<span class="text-[9px] font-mono text-zinc-500">Current: ' + (statusLabel[status] || status) + '</span>'
          + '</div>';
      }

      // Feature header card
      let html = `
        <div class="flex items-start justify-between gap-2 mb-1">
          <h2 class="text-sm font-bold text-zinc-300 leading-tight">Feature Inspector</h2>
          <button type="button" data-sc-inspector-deselect
            class="flex-shrink-0 text-zinc-600 hover:text-zinc-400 transition text-sm leading-none mt-0.5"
            title="Back to default inspector">&times;</button>
        </div>

        <div class="rounded-lg border ${c.border} bg-zinc-900/60 p-3 space-y-2">
          <div class="flex items-center gap-2 flex-wrap">
            <span class="text-[9px] font-bold px-1.5 py-0.5 rounded ring-1 ${c.pill}">W${feature.wave}</span>
            <span class="text-[9px] font-mono text-zinc-500">${feature.id}</span>
            <span class="ml-auto text-[9px] font-mono font-bold px-1.5 py-0.5 rounded ring-1 ${statusColor[status] || ''}">${statusLabel[status] || status}</span>
          </div>
          <h3 class="text-[12px] font-semibold text-zinc-200 leading-snug">${feature.title}</h3>
          ${feature.description ? `<p class="text-[10px] text-zinc-500 leading-relaxed">${feature.description}</p>` : ''}
        </div>
      `;

      // Acceptance criteria checklist
      if (criteria.length > 0) {
        const rows = criteria.map(item => {
          const text = typeof item === 'object' ? (item.text || item.description || JSON.stringify(item)) : String(item);
          const done = typeof item === 'object' && item.done;
          return '<div class="flex items-start gap-2 py-1.5">'
            + '<span class="flex-shrink-0 mt-0.5 text-[10px] ' + (done ? 'text-emerald-500' : 'text-zinc-600') + '">' + (done ? '&#x2713;' : '&#x25CB;') + '</span>'
            + '<span class="text-[10px] ' + (done ? 'text-zinc-500 line-through decoration-zinc-600' : 'text-zinc-400') + ' leading-relaxed">' + text + '</span>'
            + '</div>';
        }).join('');
        html += this._inspectorSection('Acceptance Criteria (' + criteria.length + ')', rows);
      }

      // Related agents
      if (relatedAgents.length > 0) {
        const agentRows = relatedAgents.slice(0, 6).map(a => {
          const dotCls = (a.status === 'active' || a.status === 'working') ? STATUS_COLORS.green.dot : STATUS_COLORS.unknown.dot;
          return '<div class="flex items-center justify-between py-1.5"><div class="flex items-center gap-2 min-w-0">'
            + '<span class="inline-block h-2 w-2 flex-shrink-0 rounded-full ' + dotCls + '"></span>'
            + '<span class="text-[10px] text-zinc-400 truncate font-mono">' + (a.agent_id || a.id || 'unknown') + '</span>'
            + '</div><span class="text-[9px] font-mono text-zinc-600">' + (a.status || 'idle') + '</span></div>';
        }).join('');
        html += this._inspectorSection('Related Agents (' + relatedAgents.length + ')', agentRows);
      } else {
        html += this._inspectorSection('Related Agents', '<div class="py-2 text-[10px] text-zinc-700 font-mono">No agents assigned</div>');
      }

      // Timing (only if timestamps present on the feature)
      const timingRows = [];
      if (feature.started_at) timingRows.push(this._inspectorRow('Started', relTime(feature.started_at) || feature.started_at));
      if (feature.completed_at) timingRows.push(this._inspectorRow('Completed', relTime(feature.completed_at) || feature.completed_at));
      if (feature.due_at) timingRows.push(this._inspectorRow('Due', relTime(feature.due_at) || feature.due_at));
      if (timingRows.length > 0) {
        html += this._inspectorSection('Timing', timingRows.join(''));
      }

      // Status history mini-timeline (CSS-only, no Lottie)
      html += '<div class="space-y-1">'
        + '<h3 class="text-[10px] font-bold uppercase tracking-wider text-zinc-600">Status History</h3>'
        + '<div class="rounded-lg border border-zinc-800 bg-zinc-900/60 px-3 py-2 space-y-1.5">'
        + timelineItems
        + '</div></div>';

      // Action buttons
      html += '<div class="space-y-1">'
        + '<h3 class="text-[10px] font-bold uppercase tracking-wider text-zinc-600">Actions</h3>'
        + '<div class="flex flex-col gap-1.5">'
        + '<button type="button" data-sc-inspector-action="view-formation"'
        + ' class="w-full text-left rounded-lg border border-zinc-700/60 bg-zinc-800/50 px-3 py-2 text-[10px] font-mono text-zinc-300 hover:bg-zinc-700/60 hover:text-zinc-100 transition flex items-center justify-between">'
        + 'View Formation<span class="text-zinc-600">&#x2197;</span></button>'
        + '<button type="button" data-sc-inspector-action="copy-id"'
        + ' class="w-full text-left rounded-lg border border-zinc-700/60 bg-zinc-800/50 px-3 py-2 text-[10px] font-mono text-zinc-400 hover:bg-zinc-700/60 hover:text-zinc-200 transition flex items-center justify-between gap-2">'
        + '<span>Copy ID</span><span class="text-zinc-600 truncate">' + feature.id + '</span><span class="text-zinc-600 flex-shrink-0">&#x2398;</span>'
        + '</button></div></div>';

      container.innerHTML = html;

      // × deselect — restore default inspector
      container.querySelector('[data-sc-inspector-deselect]')?.addEventListener('click', () => {
        this.selectedFeature = null;
        this.selectedFeatureId = null;
        this._renderInspector();
        this._renderFeatureCards();
      });

      // View Formation — push event to LiveView via bridge
      container.querySelector('[data-sc-inspector-action="view-formation"]')?.addEventListener('click', () => {
        if (this.pushEventFn) {
          this.pushEventFn('inspector:view-formation', { id: feature.id });
        }
      });

      // Copy ID — clipboard with brief confirmation
      container.querySelector('[data-sc-inspector-action="copy-id"]')?.addEventListener('click', (e) => {
        const btn = e.currentTarget;
        if (navigator.clipboard) {
          navigator.clipboard.writeText(feature.id).then(() => {
            const prev = btn.innerHTML;
            btn.innerHTML = '<span class="text-emerald-400">Copied!</span>';
            setTimeout(() => { btn.innerHTML = prev; }, 1400);
          }).catch(() => {});
        }
      });
    }

    // ─── Activity Tab ───────────────────────────────────────────────────────────

    _renderActivityTabHtml() {
      return `
        <div class="activity-panel" style="display:flex;flex-direction:column;height:100%;gap:0;min-height:260px;">
          <div class="activity-graph-container" id="activity-graph-${this._instanceId}"
               style="flex:1;min-height:200px;position:relative;background:#0f172a;border-radius:6px;">
            <div class="activity-graph-empty" style="display:flex;align-items:center;justify-content:center;height:100%;min-height:200px;color:rgba(148,163,184,0.4);font-size:12px;">
              No active agents
            </div>
          </div>
          <div class="activity-log-toggle" id="activity-log-toggle-${this._instanceId}"
               style="border-top:1px solid rgba(100,116,139,0.3);padding:6px 12px;cursor:pointer;display:flex;align-items:center;justify-content:space-between;background:#1e293b;font-size:11px;color:#94a3b8;margin-top:4px;border-radius:0 0 4px 4px;">
            <span>Action Log (${this.activityData.log?.length || 0} recent)</span>
            <span class="log-chevron">${this._activityLogExpanded ? '▲' : '▼'}</span>
          </div>
          <div class="activity-log-panel" id="activity-log-${this._instanceId}"
               style="height:${this._activityLogExpanded ? '180px' : '0'};overflow:hidden;transition:height 0.2s ease;background:#0f172a;border-radius:0 0 6px 6px;">
            ${this._renderLogEntries()}
          </div>
        </div>
      `;
    }

    _bindActivityLogToggle(container) {
      const toggle = container.querySelector(`#activity-log-toggle-${this._instanceId}`);
      if (!toggle) return;
      toggle.addEventListener('click', () => {
        this._activityLogExpanded = !this._activityLogExpanded;
        const panel = container.querySelector(`#activity-log-${this._instanceId}`);
        const chevron = toggle.querySelector('.log-chevron');
        if (panel) panel.style.height = this._activityLogExpanded ? '180px' : '0';
        if (chevron) chevron.textContent = this._activityLogExpanded ? '▲' : '▼';
        const header = toggle.querySelector('span');
        if (header) header.textContent = `Action Log (${this.activityData.log?.length || 0} recent)`;
      });
    }

    _renderLogEntries() {
      const entries = (this.activityData.log || []).slice(0, 30);
      if (entries.length === 0) return '<div style="padding:8px 12px;font-size:11px;color:rgba(148,163,184,0.4);">No recent activity</div>';

      const statusColors = {
        'TOOL_CALL_START': '#6366f1', 'TOOL_CALL_END': '#22d3ee',
        'THINKING_START': '#f59e0b', 'THINKING_END': '#f59e0b',
        'TEXT_MESSAGE_START': '#10b981', 'TEXT_MESSAGE_END': '#10b981',
        'STEP_STARTED': '#8b5cf6', 'STEP_FINISHED': '#8b5cf6',
        'RUN_STARTED': '#34d399', 'RUN_FINISHED': '#64748b', 'RUN_ERROR': '#ef4444'
      };

      return `<div style="overflow-y:auto;height:100%;padding:4px 0;">${entries.map(e => `
        <div style="padding:3px 12px;display:flex;align-items:center;gap:8px;font-size:10px;border-bottom:1px solid rgba(100,116,139,0.1);">
          <span style="background:${statusColors[e.event_type] || '#475569'};color:#fff;padding:1px 5px;border-radius:3px;font-family:monospace;font-size:9px;white-space:nowrap;flex-shrink:0;">${(e.event_type || 'EVENT').replace('_', ' ')}</span>
          <span style="color:#94a3b8;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;">${e.description || ''}</span>
          <span style="color:#475569;margin-left:auto;white-space:nowrap;flex-shrink:0;">${(e.agent_id || '').slice(0, 8)}</span>
        </div>
      `).join('')}</div>`;
    }

    _renderActivityGraph(container) {
      const containerId = `activity-graph-${this._instanceId}`;
      const graphEl = (container || this._q('[data-sc="architecture-container"]'))?.querySelector('#' + containerId);
      if (!graphEl) return;

      const agents = Object.entries(this.activityData.agents || {}).map(([id, activity]) => ({
        id,
        shortId: id.slice(0, 8),
        status: activity.status || 'idle',
        description: activity.tool_name || activity.step_name || activity.status || 'idle'
      }));

      if (agents.length === 0) return;

      const empty = graphEl.querySelector('.activity-graph-empty');
      if (empty) empty.style.display = 'none';

      const rect = graphEl.getBoundingClientRect();
      const W = rect.width || 400, H = rect.height || 200;

      const d3 = window.d3;
      if (!d3) {
        graphEl.innerHTML = agents.map(a => `<div style="padding:4px 8px;font-size:10px;color:#94a3b8;">${a.shortId} — ${a.status}</div>`).join('');
        return;
      }

      const existingSvg = graphEl.querySelector('svg.activity-svg');
      if (existingSvg) existingSvg.remove();

      const svg = d3.select(graphEl).append('svg')
        .attr('class', 'activity-svg')
        .attr('width', W).attr('height', H)
        .style('position', 'absolute').style('top', 0).style('left', 0);

      const statusColor = (s) => ({
        idle: '#475569', thinking: '#f59e0b', executing_tool: '#6366f1',
        starting: '#34d399', working: '#8b5cf6', responding: '#10b981',
        completed: '#64748b', error: '#ef4444'
      }[s] || '#475569');

      const simulation = d3.forceSimulation(agents)
        .force('charge', d3.forceManyBody().strength(-80))
        .force('center', d3.forceCenter(W / 2, H / 2))
        .force('collision', d3.forceCollide().radius(28))
        .on('tick', ticked);

      const node = svg.selectAll('g.agent-node')
        .data(agents).join('g').attr('class', 'agent-node');

      node.filter(d => d.status !== 'idle' && d.status !== 'completed')
        .append('circle')
        .attr('r', 22).attr('fill', 'none')
        .attr('stroke', d => statusColor(d.status)).attr('stroke-width', 1.5)
        .attr('opacity', 0.3)
        .attr('class', 'pulse-ring');

      node.append('circle')
        .attr('r', 16)
        .attr('fill', d => statusColor(d.status))
        .attr('opacity', 0.85);

      node.append('text')
        .attr('text-anchor', 'middle').attr('dy', '0.35em')
        .attr('fill', '#e2e8f0').attr('font-size', '8px').attr('font-family', 'monospace')
        .text(d => d.shortId);

      node.append('text')
        .attr('text-anchor', 'middle').attr('dy', '28px')
        .attr('fill', '#94a3b8').attr('font-size', '9px')
        .text(d => d.status);

      function ticked() {
        node.attr('transform', d => `translate(${Math.max(20, Math.min(W - 20, d.x))},${Math.max(20, Math.min(H - 20, d.y))})`);
      }

      if (window.anime) {
        const pulseRings = graphEl.querySelectorAll('.pulse-ring');
        if (pulseRings.length > 0) {
          window.anime({
            targets: pulseRings,
            r: [16, 26], opacity: [0.5, 0],
            duration: 1500, loop: true, easing: 'easeOutQuad',
            delay: window.anime.stagger(200)
          });
        }
      }

      this._activitySimulation = simulation;
    }

    // ─── Bottom Bar ─────────────────────────────────────────────────────────────

    _renderBottomBar() {
      const bar = this._q('[data-sc="bottom-bar"]');
      if (!bar) return;

      bar.innerHTML = `
        <div class="flex items-center gap-3 px-4 py-2">
          <span class="flex-shrink-0 rounded bg-emerald-500/10 px-2 py-1 text-[10px] font-bold text-emerald-500 ring-1 ring-emerald-500/20">AG-UI</span>
          <input type="text" disabled placeholder="AG-UI chat coming soon" class="flex-1 rounded-lg border border-zinc-700 bg-zinc-900 px-4 py-1.5 text-sm text-zinc-200 placeholder-zinc-600 outline-none disabled:opacity-50"/>
          <button type="button" disabled class="flex-shrink-0 rounded-lg bg-zinc-700 px-4 py-1.5 text-xs font-bold text-zinc-200 disabled:opacity-40 disabled:cursor-not-allowed">Send</button>
        </div>
        <div class="border-t border-zinc-800/60 bg-zinc-950/60">
          <div class="flex flex-wrap items-center justify-between gap-2 px-4 py-1.5">
            <div class="flex items-center gap-3 text-[10px] text-zinc-600 font-mono">
              <span class="text-zinc-500 font-semibold">CCEM ${this.version}</span>
              <span>&middot;</span>
              <span>main</span>
              <span>&middot;</span>
              <span>&copy; 2026 LGTM / Jeremiah Pegues</span>
            </div>
            <div class="flex items-center gap-3 text-[10px] text-zinc-700">
              <span>AG-UI Protocol</span>
              <span>&middot;</span>
              <span>56 endpoints</span>
            </div>
          </div>
        </div>
      `;
    }
  }

  // Export to window for dynamic loading
  window.ShowcaseEngine = ShowcaseEngine;
})();
