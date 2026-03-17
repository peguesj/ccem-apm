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

      this.container.innerHTML = '';
      // Null out all references so closures captured in event listeners
      // (added via addEventListener inside innerHTML) don't hold this alive.
      this.container = null;
      this.features = null;
      this.apmState = null;
      this.orchState = null;
      this.liveMap = null;
      this.npmSvgCache = null;
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
      this._renderInspector();
      this._renderArchitecture();
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
      this._renderInspector();
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

    reinit(data) {
      if (data.features) this.features = data.features;
      if (data.version) this.version = data.version;
      if (data.project) this.project = data.project;
      this.orchState.storiesDone = this.features.length;
      this.orchState.storiesTotal = this.features.length;
      this._renderAll();
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
      this._renderFeatureCards();
      this._renderArchitecture();
      this._renderInspector();
      this._renderBottomBar();
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
          <button type="button" data-sc-action="toggle-roadmap" class="flex-shrink-0 rounded border border-zinc-700/60 bg-zinc-800/50 px-2.5 py-1 text-[10px] font-mono text-zinc-400 hover:bg-zinc-700/60 hover:text-zinc-200 transition">
            Roadmap &#x2197;
          </button>
        </div>
      `;

      bar.querySelector('[data-sc-action="toggle-roadmap"]')?.addEventListener('click', () => {
        this.roadmapOpen = !this.roadmapOpen;
        this._renderRoadmapModal();
      });
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
          html += `
            <div class="rounded-lg border ${f.liveStatus === 'done' ? c.border : 'border-zinc-800'} bg-zinc-900/60 p-3 space-y-2">
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
            return `
              <div class="w-full flex items-start gap-2 py-1 px-1.5 rounded hover:bg-zinc-800/50 transition text-left">
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
          }
        };
        container.addEventListener('click', this._featureClickHandler);
        this._featureClickBound = true;
      }
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
          <div class="flex items-center gap-1 rounded-lg bg-zinc-900/80 p-1 ring-1 ring-zinc-800">
            <button data-sc-arch-tab="system" class="${tabClass('system')}">System</button>
            <button data-sc-arch-tab="npm" class="${tabClass('npm')}">npm Packages</button>
          </div>
          <div class="rounded-xl border border-zinc-800 bg-zinc-900/60 p-4 overflow-hidden">
            <div data-sc-arch="system" style="display:${this.archTab === 'system' ? 'block' : 'none'}">
              ${systemSvg}
            </div>
            <div data-sc-arch="npm" style="display:${this.archTab === 'npm' ? 'block' : 'none'}">
              <div data-sc="npm-svg-host"></div>
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

    // ─── Inspector Panel (Right) ────────────────────────────────────────────────

    _renderInspector() {
      const container = this._q('[data-sc="inspector-container"]');
      if (!container) return;

      const now = this.apmState.lastPoll ? this.apmState.lastPoll.toLocaleTimeString() : 'waiting...';
      const overall = this.apmState.connected ? 'green' : 'red';

      const inspectorSection = (title, content) =>
        `<div class="space-y-1"><h3 class="text-[10px] font-bold uppercase tracking-wider text-zinc-600">${title}</h3><div class="rounded-lg border border-zinc-800 bg-zinc-900/60 px-3 divide-y divide-zinc-800/60">${content}</div></div>`;

      const inspectorRow = (label, value, dot) =>
        `<div class="flex items-center justify-between py-1.5"><div class="flex items-center gap-2">${dot ? `<span class="inline-block h-2 w-2 flex-shrink-0 rounded-full ${STATUS_COLORS[dot]?.dot || ''}"></span>` : ''}<span class="text-xs text-zinc-400">${label}</span></div><span class="font-mono text-[10px] text-zinc-300 truncate max-w-[140px]" title="${value}">${value}</span></div>`;

      let html = `
        <div class="flex items-center justify-between">
          <h2 class="text-sm font-bold text-zinc-300">Resource Inspector</h2>
          <div class="flex items-center gap-1.5">
            <span class="inline-block h-2 w-2 rounded-full ${STATUS_COLORS[overall].dot}"></span>
            <span class="text-[10px] text-zinc-600">${now}</span>
          </div>
        </div>
        <p class="text-[10px] text-zinc-600">Real-time via PubSub</p>
      `;

      const services = [
        { label: 'CCEM APM', status: this.apmState.connected ? 'green' : 'red', detail: this.apmState.connected ? 'localhost:3032' : 'unreachable' },
        { label: 'AG-UI EventRouter', status: this.apmState.connected ? 'green' : 'unknown', detail: this.apmState.connected ? 'routing' : 'unknown' },
        { label: 'CCEMAgent', status: 'amber', detail: 'menubar app' },
      ];
      html += inspectorSection('Services', services.map(s => `<div class="flex items-center justify-between py-1.5"><div class="flex items-center gap-2 min-w-0"><span class="inline-block h-2 w-2 flex-shrink-0 rounded-full ${STATUS_COLORS[s.status].dot}"></span><span class="text-xs text-zinc-300 truncate">${s.label}</span></div><span class="text-[10px] font-mono ${STATUS_COLORS[s.status].text} truncate max-w-[140px]">${s.detail}</span></div>`).join(''));

      if (this.apmState.status) {
        const st = this.apmState.status;
        html += inspectorSection('APM Status', [
          inspectorRow('Server', st.server || 'APM v5', 'green'),
          inspectorRow('Uptime', st.uptime || 'unknown'),
          inspectorRow('Agents', String(this.apmState.agents?.length || 0)),
          inspectorRow('Version', st.version || this.version),
        ].join(''));
      }

      if (this.apmState.agents && this.apmState.agents.length > 0) {
        html += inspectorSection(`Agents (${this.apmState.agents.length})`, this.apmState.agents.slice(0, 8).map(a => `<div class="flex items-center justify-between py-1.5"><div class="flex items-center gap-2 min-w-0"><span class="inline-block h-2 w-2 flex-shrink-0 rounded-full ${a.status === 'active' ? STATUS_COLORS.green.dot : STATUS_COLORS.unknown.dot}"></span><span class="text-[10px] text-zinc-400 truncate font-mono">${a.agent_id || a.id || 'unknown'}</span></div><span class="text-[9px] font-mono text-zinc-600">${a.status || 'idle'}</span></div>`).join(''));
      }

      html += inspectorSection('Git', [inspectorRow('Branch', 'main'), inspectorRow('Version', this.version), inspectorRow('Repo', 'peguesj/ccem-apm')].join(''));
      html += inspectorSection('Stack', [inspectorRow('Runtime', 'Elixir/OTP 27'), inspectorRow('Framework', 'Phoenix 1.7'), inspectorRow('UI', 'LiveView + daisyUI'), inspectorRow('Protocol', 'AG-UI (ag_ui_ex)'), inspectorRow('Agent', 'Swift/AppKit'), inspectorRow('Installer', 'Bash modular')].join(''));
      html += inspectorSection('DRTW Libraries', [inspectorRow('ag_ui_ex', 'v0.1.0 (Hex)'), inspectorRow('Phoenix', 'v1.7.x'), inspectorRow('LiveView', 'v1.0.x'), inspectorRow('Jason', 'JSON codec'), inspectorRow('Bandit', 'HTTP server'), inspectorRow('Tailwind', 'v3.x')].join(''));
      html += inspectorSection('Key Endpoints', [inspectorRow('/api/status', 'GET', 'green'), inspectorRow('/api/agents', 'GET', 'green'), inspectorRow('/api/register', 'POST', 'green'), inspectorRow('/api/heartbeat', 'POST', 'green'), inspectorRow('/api/ag-ui/events', 'SSE', 'green'), inspectorRow('/api/v2/openapi.json', 'GET', 'green'), inspectorRow('/uat', 'LiveView', 'green')].join(''));

      container.innerHTML = html;
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
