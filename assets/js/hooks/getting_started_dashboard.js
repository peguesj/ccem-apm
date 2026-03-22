// GettingStartedDashboard — Lottie-based onboarding for the main APM dashboard (/)
// 4 slides: Dashboard Layout, Agent Fleet, Formation Graph, Live Events
// Storage key: ccem_dashboard_onboarding_v2

const STORAGE_KEY = "ccem_dashboard_onboarding_v2";
const LOTTIE_CDN = "https://cdnjs.cloudflare.com/ajax/libs/lottie-web/5.12.2/lottie.min.js";

// ── Color helpers ──────────────────────────────────────────────────────────────
function rgba(hex, a = 1) {
  const r = parseInt(hex.slice(1, 3), 16);
  const g = parseInt(hex.slice(3, 5), 16);
  const b = parseInt(hex.slice(5, 7), 16);
  return [r, g, b, Math.round(a * 255)];
}

const C = {
  indigo:  rgba("#6366f1"),
  light:   rgba("#818cf8"),
  green:   rgba("#34d399"),
  amber:   rgba("#fbbf24"),
  red:     rgba("#f87171"),
  white:   rgba("#e2e8f0"),
  dim:     rgba("#a6adc8", 0.4),
  bg:      rgba("#1e1e2e", 0.6),
  panel:   rgba("#313244", 0.5),
  header:  rgba("#181825", 0.9),
  sidebar: rgba("#1e1e2e", 0.85),
  border:  rgba("#45475a", 0.7),
};

// ── Lottie JSON skeleton ───────────────────────────────────────────────────────
function lottieBase(layers, w = 360, h = 280) {
  return {
    v: "5.9.0", fr: 30, ip: 0, op: 150,
    w, h, nm: "dashboard-onboarding",
    ddd: 0, assets: [],
    layers,
  };
}

// ── Shape primitives ───────────────────────────────────────────────────────────
let _shapeId = 0;
function sid() { return ++_shapeId; }

function makeRect(x, y, w, h, color, delay = 0, dur = 30, rx = 4) {
  const id = sid();
  return {
    ty: "sh", ind: id, nm: `rect-${id}`,
    ks: {
      o: { a: 1, k: [
        { t: delay, s: [0], e: [100], i: { x: [0.4], y: [1] }, o: { x: [0.6], y: [0] } },
        { t: delay + Math.min(dur, 20), s: [100] },
      ]},
      r: { a: 0, k: 0 }, p: { a: 0, k: [0, 0] },
      a: { a: 0, k: [0, 0] }, s: { a: 0, k: [100, 100] },
    },
    shapes: [{
      ty: "gr",
      it: [
        { ty: "rc", d: 1, s: { a: 0, k: [w, h] }, p: { a: 0, k: [x + w / 2, y + h / 2] }, r: { a: 0, k: rx } },
        { ty: "fl", c: { a: 0, k: color }, o: { a: 0, k: 100 } },
        { ty: "tr", p: { a: 0, k: [0, 0] }, a: { a: 0, k: [0, 0] }, s: { a: 0, k: [100, 100] }, r: { a: 0, k: 0 }, o: { a: 0, k: 100 } },
      ],
    }],
    ip: 0, op: 150, st: 0, bm: 0,
  };
}

function makeCircle(cx, cy, r, color, delay = 0, dur = 20) {
  const id = sid();
  return {
    ty: "sh", ind: id, nm: `circle-${id}`,
    ks: {
      o: { a: 1, k: [
        { t: delay, s: [0], e: [100], i: { x: [0.4], y: [1] }, o: { x: [0.6], y: [0] } },
        { t: delay + Math.min(dur, 15), s: [100] },
      ]},
      r: { a: 0, k: 0 }, p: { a: 0, k: [0, 0] },
      a: { a: 0, k: [0, 0] }, s: { a: 0, k: [100, 100] },
    },
    shapes: [{
      ty: "gr",
      it: [
        { ty: "el", d: 1, s: { a: 0, k: [r * 2, r * 2] }, p: { a: 0, k: [cx, cy] } },
        { ty: "fl", c: { a: 0, k: color }, o: { a: 0, k: 100 } },
        { ty: "tr", p: { a: 0, k: [0, 0] }, a: { a: 0, k: [0, 0] }, s: { a: 0, k: [100, 100] }, r: { a: 0, k: 0 }, o: { a: 0, k: 100 } },
      ],
    }],
    ip: 0, op: 150, st: 0, bm: 0,
  };
}

function makeLine(x1, y1, x2, y2, color, delay = 0, dur = 20, strokeW = 1.5) {
  const id = sid();
  return {
    ty: "sh", ind: id, nm: `line-${id}`,
    ks: {
      o: { a: 1, k: [
        { t: delay, s: [0], e: [80], i: { x: [0.4], y: [1] }, o: { x: [0.6], y: [0] } },
        { t: delay + Math.min(dur, 12), s: [80] },
      ]},
      r: { a: 0, k: 0 }, p: { a: 0, k: [0, 0] },
      a: { a: 0, k: [0, 0] }, s: { a: 0, k: [100, 100] },
    },
    shapes: [{
      ty: "gr",
      it: [
        {
          ty: "sh", d: 1,
          ks: { a: 0, k: { i: [[0,0],[0,0]], o: [[0,0],[0,0]], v: [[x1,y1],[x2,y2]], c: false } },
        },
        { ty: "st", c: { a: 0, k: color }, o: { a: 0, k: 100 }, w: { a: 0, k: strokeW }, lc: 2, lj: 2 },
        { ty: "tr", p: { a: 0, k: [0, 0] }, a: { a: 0, k: [0, 0] }, s: { a: 0, k: [100, 100] }, r: { a: 0, k: 0 }, o: { a: 0, k: 100 } },
      ],
    }],
    ip: 0, op: 150, st: 0, bm: 0,
  };
}

function makePulse(cx, cy, r, color, delay = 0) {
  const id = sid();
  return {
    ty: "sh", ind: id, nm: `pulse-${id}`,
    ks: {
      o: { a: 1, k: [
        { t: delay, s: [60], e: [0], i: { x: [0.4], y: [1] }, o: { x: [0.6], y: [0] } },
        { t: delay + 40, s: [0] },
      ]},
      r: { a: 0, k: 0 }, p: { a: 0, k: [0, 0] },
      a: { a: 0, k: [0, 0] },
      s: { a: 1, k: [
        { t: delay, s: [100, 100], e: [220, 220], i: { x: [0.4], y: [1] }, o: { x: [0.6], y: [0] } },
        { t: delay + 40, s: [220, 220] },
      ]},
    },
    shapes: [{
      ty: "gr",
      it: [
        { ty: "el", d: 1, s: { a: 0, k: [r * 2, r * 2] }, p: { a: 0, k: [cx, cy] } },
        { ty: "st", c: { a: 0, k: color }, o: { a: 0, k: 100 }, w: { a: 0, k: 1 }, lc: 2, lj: 2 },
        { ty: "fl", c: { a: 0, k: [...color.slice(0, 3), 0] }, o: { a: 0, k: 100 } },
        { ty: "tr", p: { a: 0, k: [0, 0] }, a: { a: 0, k: [cx, cy] }, s: { a: 0, k: [100, 100] }, r: { a: 0, k: 0 }, o: { a: 0, k: 100 } },
      ],
    }],
    ip: 0, op: 150, st: 0, bm: 0,
  };
}

// ── Slide animations ───────────────────────────────────────────────────────────

// Slide 1 — Full APM viewport with chrome, sidebar, header, 3 panels
function slide1_dashboardLayout() {
  _shapeId = 0;
  const layers = [];

  // App window frame
  layers.push(makeRect(10, 10, 340, 260, C.bg, 0, 15, 6));
  // Header bar
  layers.push(makeRect(10, 10, 340, 32, C.header, 3, 12, 0));
  // Logo dot in header
  layers.push(makeCircle(28, 26, 5, C.indigo, 6, 10));
  // Logo text bar
  layers.push(makeRect(36, 20, 48, 7, C.light, 7, 10, 3));
  // Status badge in header
  layers.push(makeRect(290, 20, 42, 12, C.green, 8, 10, 4));
  // Header divider
  layers.push(makeLine(10, 42, 350, 42, C.border, 5, 12));

  // Sidebar
  layers.push(makeRect(10, 42, 56, 228, C.sidebar, 8, 15, 0));
  // Sidebar divider
  layers.push(makeLine(66, 42, 66, 270, C.border, 10, 12));

  // Sidebar nav items — active item
  layers.push(makeRect(14, 52, 48, 22, C.indigo, 12, 10, 4));
  layers.push(makeCircle(26, 63, 5, C.white, 14, 8));
  // Inactive nav items (5)
  for (let i = 0; i < 5; i++) {
    layers.push(makeRect(14, 80 + i * 26, 48, 18, C.dim, 15 + i * 2, 10, 4));
    layers.push(makeCircle(26, 89 + i * 26, 4, rgba("#a6adc8", 0.3), 16 + i * 2, 8));
  }

  // Content area sub-header
  layers.push(makeRect(70, 42, 290, 22, C.header, 10, 12, 0));
  layers.push(makeRect(76, 49, 60, 9, C.light, 12, 8, 3));
  layers.push(makeLine(70, 64, 360, 64, C.border, 11, 10));

  // Panel A — Agent Fleet (top-left)
  layers.push(makeRect(70, 68, 134, 88, C.panel, 18, 12, 4));
  layers.push(makeRect(74, 72, 60, 7, C.white, 20, 8, 2));
  layers.push(makeRect(74, 72, 60, 7, C.dim, 20, 8, 2));
  // Panel A badge
  layers.push(makeRect(156, 72, 30, 7, C.green, 21, 8, 3));
  // Agent rows in Panel A
  for (let i = 0; i < 3; i++) {
    const d = 24 + i * 6;
    const y = 84 + i * 20;
    layers.push(makeCircle(82, y + 5, 4, i === 0 ? C.green : i === 1 ? C.amber : C.red, d, 8));
    layers.push(makeRect(90, y, 62, 7, C.dim, d + 1, 8, 2));
    layers.push(makeRect(90, y + 10, 32, 5, rgba("#6366f1", 0.3), d + 2, 8, 2));
  }

  // Panel B — Formations (top-right)
  layers.push(makeRect(208, 68, 142, 88, C.panel, 20, 12, 4));
  layers.push(makeRect(212, 72, 58, 7, C.dim, 22, 8, 2));
  layers.push(makeRect(212, 72, 58, 7, C.white, 22, 8, 2));
  layers.push(makeRect(280, 72, 30, 7, C.amber, 23, 8, 3));
  // Formation mini-hierarchy nodes
  layers.push(makeCircle(280, 90, 5, C.indigo, 28, 8));
  layers.push(makeLine(280, 95, 262, 104, C.dim, 30, 8));
  layers.push(makeLine(280, 95, 298, 104, C.dim, 30, 8));
  layers.push(makeCircle(262, 108, 4, C.green, 32, 8));
  layers.push(makeCircle(298, 108, 4, C.amber, 32, 8));
  layers.push(makeLine(262, 112, 252, 120, C.dim, 34, 6));
  layers.push(makeLine(262, 112, 272, 120, C.dim, 34, 6));
  layers.push(makeCircle(252, 123, 3, C.green, 36, 6));
  layers.push(makeCircle(272, 123, 3, C.green, 36, 6));
  layers.push(makeCircle(298, 112, 3, C.amber, 36, 6));

  // Panel C — Dependency Graph (full-width bottom)
  layers.push(makeRect(70, 160, 280, 102, C.panel, 25, 12, 4));
  layers.push(makeRect(74, 164, 70, 7, C.dim, 27, 8, 2));
  layers.push(makeRect(74, 164, 70, 7, C.white, 27, 8, 2));
  // Graph nodes
  const gnodes = [[120,195],[180,185],[240,195],[150,220],[210,215]];
  gnodes.forEach(([gx,gy], i) => {
    layers.push(makeCircle(gx, gy, 6, i % 2 === 0 ? C.indigo : C.light, 32 + i * 3, 8));
  });
  // Graph edges
  layers.push(makeLine(120,195,180,185, C.dim, 38, 8));
  layers.push(makeLine(180,185,240,195, C.dim, 38, 8));
  layers.push(makeLine(180,185,150,220, C.dim, 40, 8));
  layers.push(makeLine(180,185,210,215, C.dim, 40, 8));
  layers.push(makeLine(150,220,210,215, C.dim, 42, 8));

  // Pulse rings on active elements
  layers.push(makePulse(82, 89, 4, C.green, 60));
  layers.push(makePulse(262, 108, 4, C.green, 80));
  layers.push(makePulse(180, 185, 6, C.indigo, 100));

  return lottieBase(layers);
}

// Slide 2 — Zoomed Agent Fleet panel with status rows
function slide2_agentFleet() {
  _shapeId = 0;
  const layers = [];

  // Panel background
  layers.push(makeRect(20, 20, 320, 240, C.panel, 0, 15, 6));
  // Panel header
  layers.push(makeRect(20, 20, 320, 32, C.header, 0, 12, 0));
  layers.push(makeRect(28, 28, 72, 9, C.white, 3, 10, 3));
  // "12 active" badge
  layers.push(makeRect(244, 27, 52, 13, C.green, 5, 10, 4));
  // Sort/filter icon rects
  layers.push(makeRect(302, 27, 16, 13, C.dim, 5, 10, 4));

  // Column headers
  layers.push(makeLine(20, 52, 340, 52, C.border, 6, 10));
  layers.push(makeRect(38, 56, 28, 6, rgba("#a6adc8", 0.35), 7, 8, 2));
  layers.push(makeRect(80, 56, 60, 6, rgba("#a6adc8", 0.35), 7, 8, 2));
  layers.push(makeRect(156, 56, 36, 6, rgba("#a6adc8", 0.35), 7, 8, 2));
  layers.push(makeRect(206, 56, 44, 6, rgba("#a6adc8", 0.35), 7, 8, 2));
  layers.push(makeRect(264, 56, 48, 6, rgba("#a6adc8", 0.35), 7, 8, 2));
  layers.push(makeLine(20, 66, 340, 66, C.border, 8, 10));

  // Agent rows
  const agents = [
    { color: C.green,  tier: C.red,   project: C.indigo, formation: C.light },
    { color: C.green,  tier: C.amber, project: C.green,  formation: C.light },
    { color: C.amber,  tier: C.amber, project: C.amber,  formation: C.dim   },
    { color: C.red,    tier: C.red,   project: C.indigo, formation: C.light },
    { color: C.green,  tier: C.dim,   project: C.green,  formation: C.dim   },
  ];

  agents.forEach((a, i) => {
    const y = 74 + i * 32;
    const d = 10 + i * 7;

    // Row bg (hover-like for first)
    if (i === 0) layers.push(makeRect(20, y - 2, 320, 28, rgba("#45475a", 0.2), d, 8, 0));

    // Status dot
    layers.push(makeCircle(34, y + 12, 5, a.color, d, 10));

    // Agent name bar
    layers.push(makeRect(48, y + 6, 72, 8, C.dim, d + 1, 8, 2));
    // Sub-label
    layers.push(makeRect(48, y + 17, 44, 5, rgba("#a6adc8", 0.25), d + 2, 8, 2));

    // Tier badge
    layers.push(makeRect(132, y + 8, 26, 11, [...a.tier.slice(0,3), 60], d + 2, 8, 4));

    // Project badge
    layers.push(makeRect(176, y + 8, 44, 11, [...a.project.slice(0,3), 60], d + 3, 8, 4));

    // Formation badge
    layers.push(makeRect(240, y + 8, 72, 11, [...a.formation.slice(0,3), 50], d + 3, 8, 4));

    // Row divider
    layers.push(makeLine(20, y + 28, 340, y + 28, C.border, d + 4, 8));
  });

  // Pulse rings on green/red active agents
  layers.push(makePulse(34, 86, 5, C.green, 55));
  layers.push(makePulse(34, 118, 5, C.green, 70));
  layers.push(makePulse(34, 150, 5, C.amber, 85));
  layers.push(makePulse(34, 182, 5, C.red, 95));

  return lottieBase(layers);
}

// Slide 3 — Formation hierarchy graph with wave progress
function slide3_formationGraph() {
  _shapeId = 0;
  const layers = [];

  // Panel background
  layers.push(makeRect(20, 20, 320, 240, C.panel, 0, 15, 6));
  // Panel header
  layers.push(makeRect(20, 20, 320, 28, C.header, 0, 12, 0));
  layers.push(makeRect(28, 27, 68, 9, C.white, 3, 10, 3));
  // Formation ID badge
  layers.push(makeRect(236, 26, 90, 11, C.dim, 4, 10, 4));

  // Session node (top)
  layers.push(makeCircle(180, 58, 10, C.indigo, 6, 12));
  layers.push(makeRect(156, 70, 48, 7, C.light, 8, 8, 2));

  // Session → Formation line
  layers.push(makeLine(180, 68, 180, 84, C.dim, 10, 8));

  // Formation rect
  layers.push(makeRect(136, 84, 88, 20, rgba("#6366f1", 0.25), 12, 10, 4));
  layers.push(makeRect(148, 89, 48, 7, C.light, 14, 8, 2));

  // Formation → Squadrons lines
  layers.push(makeLine(155, 104, 90, 122, C.dim, 16, 8));
  layers.push(makeLine(180, 104, 180, 122, C.dim, 16, 8));
  layers.push(makeLine(205, 104, 270, 122, C.dim, 16, 8));

  // Squadron rects (3)
  const squadrons = [
    { x: 52, color: C.green,  label: "Alpha", progress: 100 },
    { x: 148, color: C.amber,  label: "Bravo", progress: 60 },
    { x: 244, color: C.dim,    label: "Charlie", progress: 0 },
  ];
  squadrons.forEach((sq, i) => {
    const d = 18 + i * 3;
    layers.push(makeRect(sq.x, 122, 72, 18, [...sq.color.slice(0,3), 50], d, 10, 4));
    layers.push(makeRect(sq.x + 6, 127, 38, 6, sq.color, d + 2, 8, 2));
    // Wave progress bar
    const pw = Math.round(60 * sq.progress / 100);
    if (pw > 0) layers.push(makeRect(sq.x, 138, pw, 4, sq.color, d + 3, 8, 0));
    layers.push(makeRect(sq.x, 138, 60, 4, rgba("#45475a", 0.5), d, 8, 0));
    if (pw > 0) layers.push(makeRect(sq.x, 138, pw, 4, sq.color, d + 3, 8, 0));
  });

  // Squadron → Agent lines + agent nodes
  const agentDefs = [
    // Alpha (done — green)
    { sqX: 88, agents: [{ x: 68, y: 178, c: C.green }, { x: 108, y: 178, c: C.green }] },
    // Bravo (in-progress — amber)
    { sqX: 184, agents: [{ x: 162, y: 178, c: C.amber }, { x: 200, y: 178, c: C.amber }, { x: 202, y: 178, c: C.dim }] },
    // Charlie (queued — dim)
    { sqX: 280, agents: [{ x: 258, y: 178, c: C.dim }, { x: 295, y: 178, c: C.dim }] },
  ];

  agentDefs.forEach((sq, si) => {
    sq.agents.forEach((ag, ai) => {
      const d = 26 + si * 3 + ai * 2;
      layers.push(makeLine(sq.sqX, 140, ag.x, ag.y, C.dim, d, 8));
      layers.push(makeCircle(ag.x, ag.y, 7, ag.c, d + 1, 8));
      // Task rect below active agents
      if (ag.c === C.amber) {
        layers.push(makeRect(ag.x - 16, ag.y + 9, 32, 10, rgba("#fbbf24", 0.2), d + 2, 8, 3));
      }
    });
  });

  // Pulse rings on in-progress agents
  layers.push(makePulse(162, 178, 7, C.amber, 60));
  layers.push(makePulse(200, 178, 7, C.amber, 75));
  layers.push(makePulse(88, 128, 9, C.green, 90));

  // Legend
  layers.push(makeCircle(34, 218, 4, C.green, 40, 8));
  layers.push(makeRect(42, 214, 34, 7, C.dim, 40, 8, 2));
  layers.push(makeCircle(92, 218, 4, C.amber, 40, 8));
  layers.push(makeRect(100, 214, 36, 7, C.dim, 40, 8, 2));
  layers.push(makeCircle(152, 218, 4, C.dim, 40, 8));
  layers.push(makeRect(160, 214, 30, 7, C.dim, 40, 8, 2));

  return lottieBase(layers);
}

// Slide 4 — Live AG-UI event stream panel
function slide4_liveEvents() {
  _shapeId = 0;
  const layers = [];

  // Panel background
  layers.push(makeRect(20, 20, 320, 240, C.panel, 0, 15, 6));
  // Panel header
  layers.push(makeRect(20, 20, 320, 32, C.header, 0, 12, 0));
  layers.push(makeRect(28, 28, 80, 9, C.white, 3, 10, 3));
  // LIVE badge
  layers.push(makeRect(274, 26, 36, 13, C.red, 4, 8, 4));
  // Live dot
  layers.push(makeCircle(280, 33, 3, rgba("#e2e8f0"), 5, 8));

  // Filter bar
  layers.push(makeRect(24, 56, 210, 18, rgba("#1e1e2e", 0.6), 6, 10, 4));
  layers.push(makeRect(30, 61, 60, 6, C.dim, 7, 8, 2));
  layers.push(makeRect(248, 56, 40, 18, rgba("#6366f1", 0.3), 6, 10, 4));
  layers.push(makeRect(294, 56, 30, 18, C.dim, 6, 10, 4));
  layers.push(makeLine(20, 78, 340, 78, C.border, 7, 10));

  // Event rows
  const events = [
    { badge: C.indigo,  label: "TOOL_CALL_START", agent: 52, msg: 140 },
    { badge: C.green,   label: "RUN_STARTED",     agent: 44, msg: 128 },
    { badge: C.amber,   label: "STEP_STARTED",    agent: 48, msg: 132 },
    { badge: C.dim,     label: "CUSTOM",           agent: 36, msg: 120 },
    { badge: C.green,   label: "TOOL_CALL_END",   agent: 52, msg: 140 },
  ];

  events.forEach((ev, i) => {
    const y = 83 + i * 31;
    const d = 10 + i * 8;

    // Row hover bg for first
    if (i === 0) layers.push(makeRect(20, y, 320, 28, rgba("#45475a", 0.15), d, 6, 0));

    // Type badge
    const bw = 4 + ev.label.length * 3.5;
    layers.push(makeRect(26, y + 8, bw, 13, [...ev.badge.slice(0,3), 70], d + 1, 8, 4));

    // Agent bar
    layers.push(makeRect(26 + bw + 6, y + 8, ev.agent, 6, C.light, d + 2, 8, 2));
    // Sub-label (timestamp)
    layers.push(makeRect(26 + bw + 6, y + 17, 28, 5, C.dim, d + 2, 6, 2));

    // Message bar
    const msgX = 26 + bw + 6 + ev.agent + 8;
    layers.push(makeRect(msgX, y + 8, ev.msg, 6, C.dim, d + 3, 8, 2));

    // Divider
    layers.push(makeLine(20, y + 28, 340, y + 28, C.border, d + 4, 6));
  });

  // Scroll indicator dots
  for (let i = 0; i < 5; i++) {
    layers.push(makeCircle(160 + (i - 2) * 10, 248, 2, i === 0 ? C.indigo : C.dim, 40 + i * 2, 8));
  }

  // Live pulse on LIVE badge
  layers.push(makePulse(280, 33, 3, C.red, 50));
  layers.push(makePulse(280, 33, 3, C.red, 100));

  // Scroll animation — new row appearing
  layers.push(makeRect(20, 240, 320, 4, C.indigo, 110, 10, 0));

  return lottieBase(layers);
}

// ── Slide metadata ─────────────────────────────────────────────────────────────
const SLIDES = [
  {
    title: "Your APM Dashboard",
    body: "A real-time command center for all your agents, formations, and system health — right in your browser.",
    fn: slide1_dashboardLayout,
  },
  {
    title: "Agent Fleet",
    body: "Monitor every agent live: status, tier, project assignment, and formation membership at a glance.",
    fn: slide2_agentFleet,
  },
  {
    title: "Formation Graph",
    body: "Visualize hierarchical agent structures — sessions, formations, squadrons, and individual agents — as they execute.",
    fn: slide3_formationGraph,
  },
  {
    title: "Live Event Stream",
    body: "AG-UI protocol events flow in real-time. Filter by type, agent, or formation to debug exactly what you need.",
    fn: slide4_liveEvents,
  },
];

// ── Hook ───────────────────────────────────────────────────────────────────────
const GettingStartedDashboard = {
  mounted() {
    if (localStorage.getItem(STORAGE_KEY)) {
      this.el.style.display = "none";
      return;
    }
    this.currentSlide = 0;
    this.animations = [];
    this.lottieLoaded = false;
    this._render();
    this._loadLottie().then(() => {
      this.lottieLoaded = true;
      this._initAnimation(this.currentSlide);
    });
    this._bindEvents();
  },

  destroyed() {
    this.animations.forEach(a => { try { a.destroy(); } catch (_) {} });
    this.animations = [];
  },

  _render() {
    const total = SLIDES.length;
    const i = this.currentSlide;
    const slide = SLIDES[i];

    this.el.innerHTML = `
      <div class="lottie-wizard-backdrop" id="lw-backdrop">
        <div class="lottie-wizard-modal" role="dialog" aria-modal="true" aria-label="${slide.title}">
          <button class="lottie-wizard-close" id="lw-close" aria-label="Dismiss">&times;</button>

          <div class="lottie-wizard-canvas-wrap">
            <div id="lw-canvas-${i}" class="lottie-wizard-canvas"></div>
          </div>

          <div class="lottie-wizard-body">
            <div class="lottie-wizard-progress">
              ${SLIDES.map((_, idx) =>
                `<span class="lw-dot${idx === i ? " lw-dot--active" : ""}" data-idx="${idx}"></span>`
              ).join("")}
            </div>
            <h3 class="lottie-wizard-title">${slide.title}</h3>
            <p class="lottie-wizard-text">${slide.body}</p>
          </div>

          <div class="lottie-wizard-actions">
            <button class="lw-btn lw-btn--ghost" id="lw-skip">Skip</button>
            <div class="lw-nav">
              ${i > 0 ? `<button class="lw-btn lw-btn--secondary" id="lw-prev">Back</button>` : ""}
              ${i < total - 1
                ? `<button class="lw-btn lw-btn--primary" id="lw-next">Next &rarr;</button>`
                : `<button class="lw-btn lw-btn--primary" id="lw-done">Get Started</button>`
              }
            </div>
          </div>
        </div>
      </div>
    `;
    this._injectStyles();
    this.el.style.display = "";
  },

  _injectStyles() {
    if (document.getElementById("lottie-wizard-styles")) return;
    const style = document.createElement("style");
    style.id = "lottie-wizard-styles";
    style.textContent = `
      .lottie-wizard-backdrop {
        position: fixed; inset: 0; z-index: 9999;
        background: rgba(0,0,0,0.65);
        display: flex; align-items: center; justify-content: center;
        backdrop-filter: blur(4px);
      }
      .lottie-wizard-modal {
        background: #1e1e2e;
        border: 1px solid #45475a;
        border-radius: 14px;
        width: 420px; max-width: calc(100vw - 32px);
        box-shadow: 0 24px 64px rgba(0,0,0,0.5);
        overflow: hidden;
        display: flex; flex-direction: column;
      }
      .lottie-wizard-close {
        position: absolute; top: 12px; right: 16px;
        background: none; border: none;
        color: #a6adc8; font-size: 20px; cursor: pointer;
        line-height: 1; padding: 4px 6px; border-radius: 4px;
      }
      .lottie-wizard-close:hover { color: #cdd6f4; background: rgba(255,255,255,0.05); }
      .lottie-wizard-canvas-wrap {
        background: #181825;
        border-bottom: 1px solid #313244;
        display: flex; align-items: center; justify-content: center;
        padding: 12px 0 8px;
        min-height: 180px;
      }
      .lottie-wizard-canvas { width: 360px; height: 220px; }
      .lottie-wizard-body { padding: 20px 24px 8px; }
      .lottie-wizard-progress {
        display: flex; gap: 6px; margin-bottom: 14px; justify-content: center;
      }
      .lw-dot {
        width: 6px; height: 6px; border-radius: 50%;
        background: #45475a; cursor: pointer; transition: background 0.2s;
      }
      .lw-dot--active { background: #6366f1; width: 18px; border-radius: 3px; }
      .lottie-wizard-title {
        font-size: 17px; font-weight: 600; color: #cdd6f4;
        margin: 0 0 6px; letter-spacing: -0.01em;
      }
      .lottie-wizard-text {
        font-size: 13px; color: #a6adc8; line-height: 1.55;
        margin: 0;
      }
      .lottie-wizard-actions {
        display: flex; justify-content: space-between; align-items: center;
        padding: 14px 24px 20px;
      }
      .lw-nav { display: flex; gap: 8px; }
      .lw-btn {
        font-size: 13px; font-weight: 500; border-radius: 6px;
        padding: 7px 16px; cursor: pointer; border: none;
        transition: background 0.15s, opacity 0.15s;
      }
      .lw-btn--ghost { background: none; color: #585b70; }
      .lw-btn--ghost:hover { color: #a6adc8; }
      .lw-btn--secondary {
        background: #313244; color: #cdd6f4;
      }
      .lw-btn--secondary:hover { background: #45475a; }
      .lw-btn--primary {
        background: #6366f1; color: #fff;
      }
      .lw-btn--primary:hover { background: #818cf8; }
    `;
    document.head.appendChild(style);
  },

  _loadLottie() {
    if (window.lottie) return Promise.resolve();
    return new Promise((resolve, reject) => {
      const s = document.createElement("script");
      s.src = LOTTIE_CDN;
      s.onload = resolve;
      s.onerror = reject;
      document.head.appendChild(s);
    });
  },

  _initAnimation(idx) {
    if (!window.lottie) return;
    const container = document.getElementById(`lw-canvas-${idx}`);
    if (!container) return;
    if (this.animations[idx]) {
      this.animations[idx].destroy();
      delete this.animations[idx];
    }
    const animData = SLIDES[idx].fn();
    const anim = window.lottie.loadAnimation({
      container,
      renderer: "canvas",
      loop: true,
      autoplay: true,
      animationData: animData,
    });
    this.animations[idx] = anim;
  },

  _bindEvents() {
    this.el.addEventListener("click", (e) => {
      const id = e.target.id || e.target.closest("[id]")?.id;
      const dot = e.target.closest(".lw-dot");

      if (id === "lw-close" || id === "lw-skip" || id === "lw-backdrop") {
        if (id === "lw-backdrop" && e.target.id !== "lw-backdrop") return;
        this._dismiss();
      } else if (id === "lw-next") {
        this._goTo(this.currentSlide + 1);
      } else if (id === "lw-prev") {
        this._goTo(this.currentSlide - 1);
      } else if (id === "lw-done") {
        this._dismiss();
      } else if (dot) {
        this._goTo(parseInt(dot.dataset.idx, 10));
      }
    });
  },

  _goTo(idx) {
    if (idx < 0 || idx >= SLIDES.length) return;
    this.currentSlide = idx;
    this._render();
    if (this.lottieLoaded) this._initAnimation(idx);
    else this._loadLottie().then(() => { this.lottieLoaded = true; this._initAnimation(idx); });
  },

  _dismiss() {
    localStorage.setItem(STORAGE_KEY, "1");
    this.el.style.display = "none";
  },
};

export default GettingStartedDashboard;
