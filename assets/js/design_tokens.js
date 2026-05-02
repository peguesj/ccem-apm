/**
 * CCEM APM Design Tokens
 *
 * Single source of truth for all JS hooks (formation_graph.js,
 * dependency_graph.js, showcase-engine.js, etc.).
 *
 * Hex approximations of the oklch design system tokens in app.css.
 * Canvas uses CCEM Design System oklch palette; formation hierarchy
 * retains semantic indigo/sky/emerald/violet for D3 node differentiation.
 */

export const TOKENS = {
  // ── Backgrounds (aligned to --ccem-bg-*) ───────────────────────────────────
  bg: {
    primary:   "#1a1d2b",  // --ccem-bg-1 oklch(0.175 0.014 255)
    secondary: "#151827",  // --ccem-bg-0 oklch(0.145 0.012 255)
    tertiary:  "#1f2333",  // --ccem-bg-2 oklch(0.205 0.016 255)
    elevated:  "#252a3a",  // --ccem-bg-3 oklch(0.235 0.017 255)
    canvas:    "#151827",  // --ccem-bg-0
  },

  // ── Status / semantic (aligned to --ccem-ok/warn/err/info) ─────────────────
  status: {
    success: "#5ee8a0",    // --ccem-ok  oklch(0.82 0.18 150)
    warning: "#e0b830",    // --ccem-warn oklch(0.82 0.16 85)
    error:   "#e8503a",    // --ccem-err  oklch(0.70 0.22 25)
    info:    "#5ab8e8",    // --ccem-info oklch(0.78 0.14 230)
  },

  // ── Accent (signature lime) ────────────────────────────────────────────────
  accent: {
    lime:     "#a3e635",   // --ccem-accent oklch(0.86 0.18 140)
    limeDim:  "#7cc020",   // --ccem-accent-dim
    iris:     "#7c5cf6",   // --ccem-iris oklch(0.68 0.19 280)
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

  // ── Text (aligned to --ccem-fg-*) ───────────────────────────────────────────
  text: {
    primary:   "#f0f1f4",  // --ccem-fg oklch(0.97 0.005 255)
    secondary: "#b0b5c0",  // --ccem-fg-muted oklch(0.78 0.012 255)
    muted:     "#808590",  // --ccem-fg-dim oklch(0.58 0.013 255)
    faint:     "#606570",  // --ccem-fg-faint oklch(0.44 0.012 255)
    code:      "#a5f3fc",  // cyan-200 (unchanged — code highlight)
  },

  // ── Borders / lines (aligned to --ccem-line-*) ─────────────────────────────
  border: {
    default: "#363c4d",    // --ccem-line oklch(0.30 0.018 255)
    strong:  "#464e60",    // --ccem-line-strong oklch(0.36 0.02 255)
    subtle:  "#2a2f3d",    // --ccem-line-subtle
    active:  "#7c5cf6",    // --ccem-iris
    success: "#5ee8a0",    // --ccem-ok
    dim:     "#2a2f3d",    // subtle separators
  },

  // ── Link / edge ────────────────────────────────────────────────────────────
  edge: {
    default:  "#363c4d",   // --ccem-line
    active:   "#a3e635",   // --ccem-accent (lime for live edges)
    dashed:   "#2a2f3d",   // subtle
  },

  // ── Dot grid pattern ───────────────────────────────────────────────────────
  dotGrid: {
    bg:  "#151827",        // --ccem-bg-0
    dot: "#2a3040",
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
