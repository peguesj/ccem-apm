/**
 * SessionDiagramHook — LiveView hook for /sessions/:id diagram containers.
 *
 * Reads `data-diagram-type` and `data-diagram-payload` from the hook element
 * and renders a small SVG visualisation.
 *
 * Two rendering paths:
 *   Path A (DEFAULT): `renderViaShowcaseEngine` — ensures ShowcaseEngine is
 *     loaded on the page (for shared fonts/CSS + future engine integration),
 *     then delegates to the same lightweight SVG builder used by Path B. The
 *     ShowcaseEngine class in its current form does not expose public node/
 *     edge primitives, so this path mainly guarantees the engine bundle is
 *     available for cross-page consistency.
 *   Path B (behind feature flag): `renderStandalone` — identical SVG builder,
 *     but without touching ShowcaseEngine at all. Enabled by
 *     `window.__CCEM_USE_STANDALONE_SVG === true` or
 *     `localStorage.getItem('ccem.sessions.standaloneSvg') === '1'`.
 *
 * Supported diagram types: "topology", "hook-lifecycle", "formation-tree".
 * Payload shape: { nodes: [{id, label, type, x, y, ...}], edges: [{from, to, label}] }
 */

const SVG_NS = "http://www.w3.org/2000/svg";

const TYPE_STYLES = {
  // Topology nodes
  root:     { fill: "#6366f1", stroke: "#a5b4fc", text: "#ffffff", radius: 10 },
  present:  { fill: "#10b98133", stroke: "#10b981", text: "#d1fae5", radius: 8 },
  absent:   { fill: "#71717a22", stroke: "#71717a", text: "#a1a1aa", radius: 8 },
  agents:   { fill: "#3b82f633", stroke: "#60a5fa", text: "#dbeafe", radius: 8 },
  ports:    { fill: "#f59e0b33", stroke: "#fbbf24", text: "#fef3c7", radius: 8 },
  plugins:  { fill: "#a855f733", stroke: "#c084fc", text: "#f3e8ff", radius: 8 },
  skills:   { fill: "#ec489933", stroke: "#f472b6", text: "#fce7f3", radius: 8 },
  hooks:    { fill: "#06b6d433", stroke: "#22d3ee", text: "#cffafe", radius: 8 },

  // Hook lifecycle phases
  hook_phase: { fill: "#1f293766", stroke: "#6366f1", text: "#c7d2fe", radius: 8 },

  // Formation tree
  lead:    { fill: "#f59e0b33", stroke: "#fbbf24", text: "#fef3c7", radius: 8 },
  swarm:   { fill: "#3b82f633", stroke: "#60a5fa", text: "#dbeafe", radius: 8 },
  cluster: { fill: "#10b98133", stroke: "#34d399", text: "#d1fae5", radius: 8 },
  agent:   { fill: "#71717a33", stroke: "#a1a1aa", text: "#e4e4e7", radius: 8 },
};

const DEFAULT_STYLE = { fill: "#1f293755", stroke: "#52525b", text: "#d4d4d8", radius: 8 };

function styleFor(type) {
  return TYPE_STYLES[type] || DEFAULT_STYLE;
}

function createSvgEl(tag, attrs = {}) {
  const el = document.createElementNS(SVG_NS, tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (v !== null && v !== undefined) el.setAttribute(k, String(v));
  }
  return el;
}

// Build the SVG visualisation. Shared by both render paths.
function buildDiagramSvg(type, payload) {
  const nodes = Array.isArray(payload.nodes) ? payload.nodes : [];
  const edges = Array.isArray(payload.edges) ? payload.edges : [];

  // Compute bounding box so we can set a viewBox that fits the nodes
  const padding = 40;
  const xs = nodes.map((n) => n.x || 0);
  const ys = nodes.map((n) => n.y || 0);
  const minX = xs.length ? Math.min(...xs) - padding : 0;
  const minY = ys.length ? Math.min(...ys) - padding : 0;
  const maxX = xs.length ? Math.max(...xs) + padding : 500;
  const maxY = ys.length ? Math.max(...ys) + padding : 300;
  const width = Math.max(300, maxX - minX);
  const height = Math.max(200, maxY - minY);

  const svg = createSvgEl("svg", {
    xmlns: SVG_NS,
    viewBox: `${minX} ${minY} ${width} ${height}`,
    width: "100%",
    height: "100%",
    "data-diagram-type": type,
    "preserveAspectRatio": "xMidYMid meet",
    style: "font-family: 'Inter', system-ui, sans-serif;",
  });

  // <defs> with an arrowhead marker for edges
  const defs = createSvgEl("defs");
  const marker = createSvgEl("marker", {
    id: `session-diagram-arrow-${type}`,
    viewBox: "0 -5 10 10",
    refX: 9,
    refY: 0,
    markerWidth: 6,
    markerHeight: 6,
    orient: "auto",
  });
  const markerPath = createSvgEl("path", {
    d: "M0,-5 L10,0 L0,5",
    fill: "#6366f1",
  });
  marker.appendChild(markerPath);
  defs.appendChild(marker);
  svg.appendChild(defs);

  // Node lookup for edge endpoints
  const nodeById = new Map();
  for (const n of nodes) nodeById.set(n.id, n);

  // Render edges behind nodes
  const edgeGroup = createSvgEl("g", { class: "session-diagram-edges" });
  for (const edge of edges) {
    const a = nodeById.get(edge.from);
    const b = nodeById.get(edge.to);
    if (!a || !b) continue;

    const line = createSvgEl("line", {
      x1: a.x,
      y1: a.y,
      x2: b.x,
      y2: b.y,
      stroke: "#52525b",
      "stroke-width": 1.25,
      "stroke-opacity": 0.7,
      "marker-end": `url(#session-diagram-arrow-${type})`,
    });
    edgeGroup.appendChild(line);

    if (edge.label) {
      const midX = (a.x + b.x) / 2;
      const midY = (a.y + b.y) / 2;
      const label = createSvgEl("text", {
        x: midX,
        y: midY - 4,
        "text-anchor": "middle",
        "font-size": 9,
        fill: "#71717a",
      });
      label.textContent = edge.label;
      edgeGroup.appendChild(label);
    }
  }
  svg.appendChild(edgeGroup);

  // Render nodes on top
  const nodeGroup = createSvgEl("g", { class: "session-diagram-nodes" });
  for (const n of nodes) {
    const style = styleFor(n.type);
    const label = n.label || n.id || "";
    const labelWidth = Math.max(80, Math.min(200, label.length * 7 + 20));
    const labelHeight = 26;

    const rect = createSvgEl("rect", {
      x: n.x - labelWidth / 2,
      y: n.y - labelHeight / 2,
      width: labelWidth,
      height: labelHeight,
      rx: style.radius,
      ry: style.radius,
      fill: style.fill,
      stroke: style.stroke,
      "stroke-width": 1.5,
    });
    nodeGroup.appendChild(rect);

    const text = createSvgEl("text", {
      x: n.x,
      y: n.y + 3.5,
      "text-anchor": "middle",
      "font-size": 10.5,
      "font-weight": 500,
      fill: style.text,
    });
    text.textContent = label;
    nodeGroup.appendChild(text);

    if (n.count !== undefined && n.count !== null) {
      const countText = createSvgEl("text", {
        x: n.x,
        y: n.y + labelHeight / 2 + 11,
        "text-anchor": "middle",
        "font-size": 8.5,
        fill: "#71717a",
      });
      countText.textContent = `×${n.count}`;
      nodeGroup.appendChild(countText);
    }
  }
  svg.appendChild(nodeGroup);

  return svg;
}

function isStandaloneMode() {
  if (typeof window === "undefined") return true;
  if (window.__CCEM_USE_STANDALONE_SVG === true) return true;
  try {
    return window.localStorage &&
      window.localStorage.getItem("ccem.sessions.standaloneSvg") === "1";
  } catch (_e) {
    return false;
  }
}

function ensureShowcaseEngineLoaded(onReady) {
  if (typeof window.ShowcaseEngine === "function") {
    onReady();
    return;
  }
  const existing = document.querySelector(
    'script[data-session-diagram-loader="showcase-engine"]'
  );
  if (existing) {
    existing.addEventListener("load", onReady, { once: true });
    return;
  }
  const script = document.createElement("script");
  script.src = "/showcase/showcase-engine.js";
  script.dataset.sessionDiagramLoader = "showcase-engine";
  script.onload = onReady;
  script.onerror = () => {
    console.warn(
      "[SessionDiagram] ShowcaseEngine failed to load; falling back to standalone render."
    );
    onReady();
  };
  document.head.appendChild(script);
}

const SessionDiagram = {
  mounted() {
    this._parseAndRender();
  },

  updated() {
    this._parseAndRender();
  },

  destroyed() {
    while (this.el.firstChild) this.el.removeChild(this.el.firstChild);
  },

  _parseAndRender() {
    this.type = this.el.dataset.diagramType || "topology";
    try {
      this.payload = JSON.parse(this.el.dataset.diagramPayload || "{}");
    } catch (err) {
      console.warn("[SessionDiagram] Failed to parse payload:", err);
      this.payload = { nodes: [], edges: [] };
    }

    if (isStandaloneMode()) {
      this.renderStandalone();
    } else {
      this.renderViaShowcaseEngine();
    }
  },

  renderStandalone() {
    this._replaceContent(buildDiagramSvg(this.type, this.payload));
  },

  renderViaShowcaseEngine() {
    // Ensure ShowcaseEngine is loaded on the page (for shared assets).
    // Then delegate to the same SVG builder — ShowcaseEngine does not expose
    // reusable node/edge primitives, so re-using it here would mean duplicating
    // private render methods. The shared builder keeps both paths consistent.
    ensureShowcaseEngineLoaded(() => {
      this._replaceContent(buildDiagramSvg(this.type, this.payload));
    });
  },

  _replaceContent(node) {
    while (this.el.firstChild) this.el.removeChild(this.el.firstChild);
    this.el.appendChild(node);
  },
};

export default SessionDiagram;
