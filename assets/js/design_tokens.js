/**
 * CCEM APM Design Tokens
 *
 * Single source of truth for all JS hooks (formation_graph.js,
 * dependency_graph.js, showcase-engine.js, etc.).
 *
 * Values mirror the daisyUI dark theme configuration used in app.css
 * and the Tailwind/daisyUI variable set active at data-theme="dark".
 *
 * Canonical daisyUI dark palette:
 *   base-100: #1d232a  base-200: #191e24  base-300: #15191e
 *   success: #36d399   warning: #fbbd23   error: #f87272
 *   info: #3abff8      primary: #6366f1   secondary: #818cf8
 */

export const TOKENS = {
  // ── Backgrounds ────────────────────────────────────────────────────────────
  bg: {
    primary:   "#1d232a",  // base-100  — main surface
    secondary: "#191e24",  // base-200  — cards, panels
    tertiary:  "#15191e",  // base-300  — borders, deep wells
    elevated:  "#212830",  // raised cards / node backgrounds
    canvas:    "#0f1420",  // dot-grid canvas background
  },

  // ── Status / semantic ──────────────────────────────────────────────────────
  status: {
    success: "#36d399",
    warning: "#fbbd23",
    error:   "#f87272",
    info:    "#3abff8",
  },

  // ── Formation hierarchy ────────────────────────────────────────────────────
  // Each level: fill (node body), stroke (border/accent), text (label)
  // Status overlays for agent nodes use the status palette above.
  formation: {
    session: {
      fill:   "#312e81",   // deep indigo bg
      stroke: "#4338ca",   // indigo-700
      text:   "#c7d2fe",   // indigo-200
    },
    formation: {
      fill:   "#1e1b4b",   // indigo-950
      stroke: "#6366f1",   // primary
      text:   "#e0e7ff",   // indigo-100
    },
    squadron: {
      fill:   "#0c4a6e",   // sky-950
      stroke: "#0ea5e9",   // sky-500
      text:   "#e0f2fe",   // sky-100
    },
    swarm: {
      fill:   "#064e3b",   // emerald-950
      stroke: "#10b981",   // emerald-500
      text:   "#d1fae5",   // emerald-100
    },
    cluster: {
      fill:   "#2e1065",   // violet-950
      stroke: "#8b5cf6",   // violet-500
      text:   "#ede9fe",   // violet-100
    },
    agent: {
      active:  { fill: "#14532d", stroke: "#22c55e" },  // green-900 / green-500
      idle:    { fill: "#1e293b", stroke: "#64748b" },  // slate-800 / slate-500
      error:   { fill: "#7f1d1d", stroke: "#ef4444" },  // red-900 / red-500
      default: { fill: "#1e293b", stroke: "#475569" },  // slate-800 / slate-600
    },
    task: {
      fill:   "#713f12",   // amber-950
      stroke: "#f59e0b",   // amber-400
      text:   "#fef3c7",   // amber-100
    },
    fleet: {
      fill:   "#1a1a2e",   // virtual root — very deep
      stroke: "#4338ca",   // indigo-700
      text:   "#c7d2fe",   // indigo-200
    },
  },

  // ── Text ───────────────────────────────────────────────────────────────────
  text: {
    primary:   "#e2e8f0",  // slate-200
    secondary: "#94a3b8",  // slate-400
    muted:     "#64748b",  // slate-500
    code:      "#a5f3fc",  // cyan-200
  },

  // ── Borders / lines ────────────────────────────────────────────────────────
  border: {
    default: "#334155",    // slate-700
    active:  "#6366f1",    // primary
    success: "#36d399",    // success
    dim:     "#1e293b",    // slate-800  — subtle separators
  },

  // ── Link / edge ────────────────────────────────────────────────────────────
  edge: {
    default:  "#334155",   // slate-700
    active:   "#6366f1",   // primary
    dashed:   "#1e293b",   // dim connector
  },

  // ── Dot grid pattern ───────────────────────────────────────────────────────
  dotGrid: {
    bg:  "#0f1420",
    dot: "#1e2a3a",
  },
}

/**
 * Resolve a formation node's colors by level and optional status.
 *
 * @param {string} level  - "session"|"formation"|"squadron"|"swarm"|"cluster"|"agent"|"task"|"fleet"
 * @param {string} status - (agent only) "active"|"idle"|"error"|"default"
 * @returns {{ fill: string, stroke: string, text: string }}
 */
export function nodeColors(level, status) {
  const t = TOKENS.formation
  switch ((level || "").toLowerCase()) {
    case "session":   return t.session
    case "formation": return t.formation
    case "squadron":  return t.squadron
    case "swarm":     return t.swarm
    case "cluster":   return t.cluster
    case "task":      return t.task
    case "fleet":     return t.fleet
    case "agent": {
      const s = (status || "default").toLowerCase()
      const c = t.agent[s] || t.agent.default
      return { fill: c.fill, stroke: c.stroke, text: TOKENS.text.primary }
    }
    default: {
      return { fill: TOKENS.bg.elevated, stroke: TOKENS.border.default, text: TOKENS.text.secondary }
    }
  }
}

/**
 * Resolve a status indicator color.
 *
 * @param {string} status
 * @returns {string} hex color
 */
export function statusColor(status) {
  switch ((status || "").toLowerCase()) {
    case "active":
    case "running":
    case "pass":
    case "complete":
    case "done":     return TOKENS.status.success
    case "failed":
    case "fail":
    case "error":    return TOKENS.status.error
    case "pending":
    case "idle":     return TOKENS.status.warning
    default:         return TOKENS.text.muted
  }
}
