/**
 * DependencyGraph LiveView JS Hook
 *
 * Renders the CCEM agentic hierarchy as a live D3 top-down tree:
 *   Session → Formation → Squadron → Swarm → Agent → Task
 *
 * Data sources (in priority order):
 *   1. push_event("hierarchy_data", {tree: {...}}) — structured tree from LiveView
 *   2. push_event("agents_updated", {agents: [...]}) — flat agent list, tree built client-side
 *   3. Fetch /api/v2/formations + /api/agents on mount — initial state
 *
 * Features:
 *   - D3 v7 tree layout (top-down, cubic bezier links)
 *   - Level-based node colors: Session/Formation/Squadron/Swarm/Agent/Task
 *   - Status dot per node (active=green, complete=blue, failed=red, idle=gray)
 *   - Hover tooltips with metadata
 *   - Zoom/pan via d3.zoom()
 *   - Auto-fit on initial render
 *   - Legend with level colors
 */

// D3 lazy loading — only fetched on routes that mount this hook
let d3 = null
let _d3LoadPromise = null
function ensureD3() {
  if (d3) return Promise.resolve(d3)
  if (window.d3) { d3 = window.d3; return Promise.resolve(d3) }
  if (_d3LoadPromise) return _d3LoadPromise
  _d3LoadPromise = new Promise((resolve, reject) => {
    const script = document.createElement("script")
    script.src = "https://cdn.jsdelivr.net/npm/d3@7/dist/d3.min.js"
    script.onload = () => { d3 = window.d3; resolve(d3) }
    script.onerror = () => reject(new Error("Failed to load D3 from CDN"))
    document.head.appendChild(script)
  })
  return _d3LoadPromise
}

// ── Palette ──────────────────────────────────────────────────────────────────
const PALETTE = {
  bg:        "#0f172a",
  border:    "#1e293b",
  text:      "#e2e8f0",
  textDim:   "#8899aa",
  textMuted: "#475569",
  edge:      "#1e293b",
}

// Level → color mapping (Session=purple … Task=yellow)
const LEVEL_COLORS = {
  session:   "#7c3aed",
  formation: "#3b82f6",
  squadron:  "#06b6d4",
  swarm:     "#22c55e",
  agent:     "#f97316",
  task:      "#eab308",
  unknown:   "#6b7280",
}

const LEVEL_ORDER = ["session", "formation", "squadron", "swarm", "agent", "task"]

function levelColor(level) {
  return LEVEL_COLORS[(level || "").toLowerCase()] || LEVEL_COLORS.unknown
}

function levelLabel(level) {
  const l = (level || "").toLowerCase()
  return l ? l.charAt(0).toUpperCase() + l.slice(1) : "Unknown"
}

function statusColor(status) {
  switch ((status || "").toLowerCase()) {
    case "active":    return "#22c55e"
    case "running":   return "#22c55e"
    case "pass":      return "#22c55e"
    case "complete":  return "#3b82f6"
    case "done":      return "#3b82f6"
    case "failed":    return "#ef4444"
    case "fail":      return "#ef4444"
    case "error":     return "#ef4444"
    case "idle":      return "#94a3b8"
    case "waiting":   return "#94a3b8"
    default:          return "#6b7280"
  }
}

function abbreviate(name, maxLen) {
  if (!name) return "?"
  if (name.length <= maxLen) return name
  // Try camelCase abbreviation first
  const parts = name.split(/(?=[A-Z])/)
  if (parts.length >= 3) {
    return parts.slice(0, -1).map(p => p[0]).join("") + parts[parts.length - 1].substring(0, 3)
  }
  return name.substring(0, maxLen - 1) + "…"
}

// ── Formation-role → hierarchy level ─────────────────────────────────────────
function roleToLevel(role) {
  const r = (role || "").toLowerCase()
  if (r === "orchestrator")   return "formation"
  if (r === "squadron_lead")  return "squadron"
  if (r === "swarm_agent")    return "swarm"
  if (r === "cluster_agent")  return "agent"
  return "agent"
}

// ── Build hierarchy tree from flat agents list ────────────────────────────────
// Groups by formation_id first, then walks parent_agent_id pointers within each group.
function buildHierarchyFromAgents(agents) {
  if (!agents || agents.length === 0) return null

  const byId = {}
  agents.forEach(a => { byId[a.agent_id || a.id] = a })

  // Group by formation_id
  const byFormation = {}
  const noFormation = []
  agents.forEach(a => {
    const fid = a.formation_id || a.formationId || ""
    if (fid) {
      if (!byFormation[fid]) byFormation[fid] = []
      byFormation[fid].push(a)
    } else {
      noFormation.push(a)
    }
  })

  const sessionNode = {
    id: "session",
    name: "Session",
    level: "session",
    status: "active",
    children: [],
  }

  // Build a subtree for each formation
  Object.entries(byFormation).forEach(([fid, fAgents]) => {
    const fmtNode = {
      id: fid,
      name: fid,
      level: "formation",
      status: inferFormationStatus(fAgents),
      children: [],
    }

    // Within the formation, build tree via parent_agent_id
    const aIds = new Set(fAgents.map(a => a.agent_id || a.id))
    const childrenOf = {}
    const roots = []

    fAgents.forEach(a => {
      const pid = a.parent_agent_id
      if (pid && aIds.has(pid)) {
        if (!childrenOf[pid]) childrenOf[pid] = []
        childrenOf[pid].push(a)
      } else {
        roots.push(a)
      }
    })

    function toNode(a) {
      const kids = childrenOf[a.agent_id || a.id] || []
      return {
        id: a.agent_id || a.id,
        name: a.task_subject || a.agent_id || a.id,
        level: roleToLevel(a.formation_role || a.role),
        status: a.status || "unknown",
        meta: a,
        children: kids.map(toNode),
      }
    }

    fmtNode.children = roots.map(toNode)
    sessionNode.children.push(fmtNode)
  })

  // Orphaned agents (no formation_id)
  if (noFormation.length > 0) {
    const orphanNode = {
      id: "orphaned",
      name: "Unassigned",
      level: "formation",
      status: "idle",
      children: noFormation.map(a => ({
        id: a.agent_id || a.id,
        name: a.task_subject || a.agent_id || a.id,
        level: "agent",
        status: a.status || "unknown",
        meta: a,
        children: [],
      })),
    }
    sessionNode.children.push(orphanNode)
  }

  return sessionNode
}

// Build from formations + agents (when /api/v2/formations data is available)
function buildHierarchyFromFormations(formations, agents) {
  if (!formations || formations.length === 0) {
    return buildHierarchyFromAgents(agents)
  }

  const sessionNode = {
    id: "session",
    name: "Session",
    level: "session",
    status: "active",
    children: [],
  }

  // Index agents by formation_id
  const agentsByFmt = {}
  ;(agents || []).forEach(a => {
    const fid = a.formation_id || a.formationId || ""
    if (!agentsByFmt[fid]) agentsByFmt[fid] = []
    agentsByFmt[fid].push(a)
  })

  formations.forEach(fmt => {
    const fid = fmt.id || fmt.formation_id || "formation"
    const fmtAgents = agentsByFmt[fid] || fmt.agents || []

    const fmtNode = {
      id: fid,
      name: fid,
      level: "formation",
      status: fmt.status || inferFormationStatus(fmtAgents),
      meta: fmt,
      children: [],
    }

    // If the formation ships squadrons, use them
    if (fmt.squadrons && fmt.squadrons.length > 0) {
      fmt.squadrons.forEach(sq => {
        const sqNode = {
          id: sq.id || `${fid}-${sq.name || sq.id}`,
          name: sq.name || sq.id || "Squadron",
          level: "squadron",
          status: sq.status || "unknown",
          meta: sq,
          children: [],
        }

        const swarms = sq.swarms || []
        if (swarms.length > 0) {
          swarms.forEach(sw => {
            const swNode = {
              id: sw.id || `${sqNode.id}-sw`,
              name: sw.name || sw.id || "Swarm",
              level: "swarm",
              status: sw.status || "unknown",
              meta: sw,
              children: (sw.agents || []).map(a => ({
                id: a.agent_id || a.id,
                name: a.task_subject || a.agent_id || a.id,
                level: "agent",
                status: a.status || "unknown",
                meta: a,
                children: [],
              })),
            }
            sqNode.children.push(swNode)
          })
        } else {
          sqNode.children = (sq.agents || []).map(a => ({
            id: a.agent_id || a.id,
            name: a.task_subject || a.agent_id || a.id,
            level: "agent",
            status: a.status || "unknown",
            meta: a,
            children: [],
          }))
        }
        fmtNode.children.push(sqNode)
      })
    } else if (fmtAgents.length > 0) {
      // Fall back to building from agent parent_agent_id tree
      const sub = buildHierarchyFromAgents(fmtAgents)
      // Extract children of the formation node from the sub-tree
      fmtNode.children = sub ? (sub.children[0] ? sub.children[0].children : []) : []
    }

    sessionNode.children.push(fmtNode)
  })

  return sessionNode
}

function inferFormationStatus(agents) {
  if (!agents || agents.length === 0) return "idle"
  if (agents.some(a => (a.status || "").toLowerCase() === "active")) return "active"
  if (agents.every(a => (a.status || "").toLowerCase() === "complete")) return "complete"
  if (agents.some(a => (a.status || "").toLowerCase() === "failed")) return "failed"
  return "idle"
}

// ── Main Hook ─────────────────────────────────────────────────────────────────
const DependencyGraph = {
  async mounted() {
    await ensureD3()
    this._container = d3.select(this.el)
    this._treeData  = null
    this._tooltip   = null
    this._svg       = null

    // Fetch initial data from APM
    this._fetchInitialData()

    // LiveView sends structured tree
    this.handleEvent("hierarchy_data", (data) => {
      this._treeData = data.tree || data
      this._render()
    })

    // LiveView sends flat agent list — build tree client-side
    this.handleEvent("agents_updated", (data) => {
      const agents = data.agents || []
      this._treeData = buildHierarchyFromAgents(agents) || this._treeData
      this._render()
    })

    // graph_toggle_anon kept for backward compat — re-renders in place
    this.handleEvent("graph_toggle_anon", () => {
      this._render()
    })
  },

  destroyed() {
    if (this._tooltip) this._tooltip.remove()
    if (this._svg) this._svg.remove()
  },

  async _fetchInitialData() {
    try {
      const [fmtRes, agentRes] = await Promise.all([
        fetch("/api/v2/formations").catch(() => null),
        fetch("/api/agents").catch(() => null),
      ])

      let formations = []
      let agents = []

      if (fmtRes && fmtRes.ok) {
        const j = await fmtRes.json()
        formations = j.data || j.formations || (Array.isArray(j) ? j : [])
      }
      if (agentRes && agentRes.ok) {
        const j = await agentRes.json()
        agents = j.agents || j.data || (Array.isArray(j) ? j : [])
      }

      const tree = buildHierarchyFromFormations(formations, agents)
      if (tree) {
        this._treeData = tree
        this._render()
      } else {
        this._renderEmpty()
      }
    } catch (e) {
      console.warn("[DependencyGraph] Fetch failed:", e)
      if (!this._treeData) this._renderEmpty()
    }
  },

  _render() {
    const data = this._treeData
    if (!data) { this._renderEmpty(); return }

    const rect = this.el.getBoundingClientRect()
    const W = Math.max(rect.width  || 800, 400)
    const H = Math.max(rect.height || 600, 350)

    // Clear previous
    this._container.selectAll("svg").remove()
    if (this._tooltip) { this._tooltip.remove(); this._tooltip = null }

    const svg = this._container.append("svg")
      .attr("width",  "100%")
      .attr("height", "100%")
      .attr("role", "img")
      .attr("aria-label", "CCEM agentic hierarchy")
    this._svg = svg

    // Zoom layer
    const g = svg.append("g").attr("class", "graph-content")
    this._g = g

    const zoomBehavior = d3.zoom()
      .scaleExtent([0.08, 4])
      .on("zoom", (e) => g.attr("transform", e.transform))
    svg.call(zoomBehavior)

    // Tooltip (positioned relative to hook element)
    const tooltip = this._container.append("div")
      .style("position",       "absolute")
      .style("display",        "none")
      .style("background",     "rgba(15,23,42,0.96)")
      .style("border",         `1px solid ${PALETTE.border}`)
      .style("border-radius",  "6px")
      .style("padding",        "8px 12px")
      .style("color",          PALETTE.text)
      .style("font-size",      "11px")
      .style("font-family",    "monospace")
      .style("pointer-events", "none")
      .style("z-index",        "200")
      .style("max-width",      "260px")
      .style("backdrop-filter","blur(8px)")
      .style("line-height",    "1.6")
    this._tooltip = tooltip

    // Build D3 hierarchy (null children = leaf)
    const root = d3.hierarchy(data, d =>
      d.children && d.children.length > 0 ? d.children : null
    )

    const nodeCount = root.descendants().length
    const depth     = root.height + 1

    // Node separation per level — wider when fewer nodes per level
    const nodesPerLevel = nodeCount / depth
    const nodeW = Math.max(48, Math.min(100, W  / Math.max(nodesPerLevel, 2)))
    const nodeH = Math.max(70, Math.min(130, (H - 80) / Math.max(depth, 2)))

    const treeLayout = d3.tree()
      .nodeSize([nodeW, nodeH])
      .separation((a, b) => a.parent === b.parent ? 1.5 : 2.2)

    treeLayout(root)

    // Extents for centering
    let minX = Infinity, maxX = -Infinity
    let minY = Infinity, maxY = -Infinity
    root.each(d => {
      if (d.x < minX) minX = d.x
      if (d.x > maxX) maxX = d.x
      if (d.y < minY) minY = d.y
      if (d.y > maxY) maxY = d.y
    })

    const treeW = maxX - minX + nodeW * 2
    const treeH = maxY - minY + nodeH

    // Fit-to-view transform
    const scale = Math.min(1.0, (W - 60) / treeW, (H - 80) / treeH)
    const tx = W / 2 - ((minX + maxX) / 2) * scale
    const ty = 36

    svg.call(zoomBehavior.transform, d3.zoomIdentity.translate(tx, ty).scale(scale))

    const NODE_R = 17

    // ── Links (cubic bezier, colored by child level) ──────────────────────────
    g.append("g").attr("class", "links")
      .selectAll("path")
      .data(root.links())
      .enter()
      .append("path")
      .attr("d", link => {
        const sx = link.source.x, sy = link.source.y
        const tx = link.target.x, ty = link.target.y
        const midY = (sy + ty) / 2
        return `M${sx},${sy} C${sx},${midY} ${tx},${midY} ${tx},${ty}`
      })
      .attr("fill",         "none")
      .attr("stroke",       link => {
        const c = d3.color(levelColor(link.target.data.level))
        if (c) c.opacity = 0.28
        return c ? c.toString() : PALETTE.edge
      })
      .attr("stroke-width", 1.6)

    // ── Nodes ─────────────────────────────────────────────────────────────────
    const node = g.append("g").attr("class", "nodes")
      .selectAll("g")
      .data(root.descendants())
      .enter()
      .append("g")
      .attr("class",     "dg-node")
      .attr("cursor",    "pointer")
      .attr("transform", d => `translate(${d.x},${d.y})`)
      .on("mouseenter", (event, d) => {
        const nd   = d.data
        const meta = nd.meta || {}
        let html = `<strong style="color:${levelColor(nd.level)}">${nd.name || nd.id}</strong><br>`
        html += `<span style="color:${PALETTE.textDim}">${levelLabel(nd.level)}</span>`
        if (nd.status) {
          html += ` · <span style="color:${statusColor(nd.status)}">${nd.status}</span>`
        }
        if (meta.wave)              html += `<br><span style="color:${PALETTE.textDim}">Wave ${meta.wave}</span>`
        if (meta.formation_id)      html += `<br>Formation: <span style="color:${levelColor("formation")}">${meta.formation_id}</span>`
        if (meta.formation_role)    html += `<br>Role: ${meta.formation_role}`
        if (meta.parent_agent_id)   html += `<br>Parent: <span style="color:${PALETTE.textDim}">${meta.parent_agent_id}</span>`
        if (d.children) {
          const kids = d.descendants().length - 1
          html += `<br>${kids} descendant${kids !== 1 ? "s" : ""}`
        }

        tooltip
          .style("display", "block")
          .html(html)
          .style("left", `${event.offsetX + 16}px`)
          .style("top",  `${event.offsetY - 10}px`)
      })
      .on("mouseleave", () => tooltip.style("display", "none"))

    // Outer glow ring
    node.append("circle")
      .attr("r",            NODE_R + 5)
      .attr("fill",         "none")
      .attr("stroke",       d => {
        const c = d3.color(levelColor(d.data.level))
        if (c) c.opacity = 0.12
        return c ? c.toString() : "transparent"
      })
      .attr("stroke-width", 4)

    // Main circle
    node.append("circle")
      .attr("r",            NODE_R)
      .attr("fill",         d => {
        const c = d3.color(levelColor(d.data.level))
        if (c) c.opacity = 0.16
        return c ? c.toString() : "#333"
      })
      .attr("stroke",       d => levelColor(d.data.level))
      .attr("stroke-width", 1.8)

    // Status dot (bottom-right corner)
    node.append("circle")
      .attr("r",            4)
      .attr("cx",           NODE_R - 2)
      .attr("cy",           NODE_R - 2)
      .attr("fill",         d => statusColor(d.data.status))
      .attr("stroke",       PALETTE.bg)
      .attr("stroke-width", 1.5)

    // Short label inside node
    node.append("text")
      .attr("text-anchor",        "middle")
      .attr("dominant-baseline",  "central")
      .attr("fill",               PALETTE.text)
      .attr("fill-opacity",       0.9)
      .attr("font-size",          "7px")
      .attr("font-family",        "monospace")
      .attr("pointer-events",     "none")
      .text(d => abbreviate(d.data.name || d.data.id, 8))

    // Full label below node
    node.append("text")
      .attr("text-anchor",    "middle")
      .attr("y",              NODE_R + 13)
      .attr("fill",           d => levelColor(d.data.level))
      .attr("fill-opacity",   0.85)
      .attr("font-size",      "8px")
      .attr("font-family",    "monospace")
      .attr("pointer-events", "none")
      .text(d => {
        const name = d.data.name || d.data.id || ""
        return name.length > 18 ? name.substring(0, 17) + "…" : name
      })

    // ── Legend ────────────────────────────────────────────────────────────────
    const legendG = svg.append("g")
      .attr("class",     "dg-legend")
      .attr("transform", "translate(12, 12)")

    legendG.append("rect")
      .attr("x",            -4).attr("y", -4)
      .attr("width",        116)
      .attr("height",       LEVEL_ORDER.length * 18 + 24)
      .attr("rx",           6)
      .attr("fill",         "rgba(15,23,42,0.88)")
      .attr("stroke",       PALETTE.border)
      .attr("stroke-width", 1)

    legendG.append("text")
      .attr("x",          4).attr("y", 11)
      .attr("fill",       PALETTE.textDim)
      .attr("font-size",  "8px")
      .attr("font-family","monospace")
      .text("HIERARCHY LEVELS")

    legendG.selectAll(".legend-item")
      .data(LEVEL_ORDER)
      .enter()
      .append("g")
      .attr("class",     "legend-item")
      .attr("transform", (_, i) => `translate(4, ${i * 18 + 20})`)
      .each(function(level) {
        d3.select(this).append("circle")
          .attr("r",            5)
          .attr("cx",           5)
          .attr("cy",           4)
          .attr("fill",         levelColor(level))
          .attr("fill-opacity", 0.75)

        d3.select(this).append("text")
          .attr("x",          14)
          .attr("y",          8)
          .attr("fill",       PALETTE.text)
          .attr("font-size",  "10px")
          .attr("font-family","monospace")
          .text(levelLabel(level))
      })

    // Mode label (top-right)
    svg.append("text")
      .attr("x",          W - 10)
      .attr("y",          18)
      .attr("text-anchor","end")
      .attr("fill",       PALETTE.textDim)
      .attr("font-size",  "9px")
      .attr("font-family","monospace")
      .text("AGENTIC HIERARCHY")
  },

  _renderEmpty() {
    const rect = this.el.getBoundingClientRect()
    const W = Math.max(rect.width  || 800, 400)
    const H = Math.max(rect.height || 400, 300)

    this._container.selectAll("svg").remove()

    const svg = this._container.append("svg")
      .attr("width",  "100%")
      .attr("height", "100%")
    this._svg = svg

    svg.append("text")
      .attr("x",           W / 2)
      .attr("y",           H / 2 - 12)
      .attr("text-anchor", "middle")
      .attr("fill",        PALETTE.textDim)
      .attr("font-size",   "14px")
      .attr("font-family", "monospace")
      .text("No active formation data")

    svg.append("text")
      .attr("x",           W / 2)
      .attr("y",           H / 2 + 14)
      .attr("text-anchor", "middle")
      .attr("fill",        PALETTE.textMuted)
      .attr("font-size",   "11px")
      .attr("font-family", "monospace")
      .text("Register agents or deploy a formation to see the hierarchy")

    // Legend still visible in empty state
    const legendG = svg.append("g")
      .attr("class",     "dg-legend")
      .attr("transform", "translate(12, 12)")

    legendG.append("rect")
      .attr("x",            -4).attr("y", -4)
      .attr("width",        116)
      .attr("height",       LEVEL_ORDER.length * 18 + 24)
      .attr("rx",           6)
      .attr("fill",         "rgba(15,23,42,0.88)")
      .attr("stroke",       PALETTE.border)
      .attr("stroke-width", 1)

    legendG.append("text")
      .attr("x",          4).attr("y", 11)
      .attr("fill",       PALETTE.textDim)
      .attr("font-size",  "8px")
      .attr("font-family","monospace")
      .text("HIERARCHY LEVELS")

    LEVEL_ORDER.forEach((level, i) => {
      const item = legendG.append("g")
        .attr("transform", `translate(4, ${i * 18 + 20})`)

      item.append("circle")
        .attr("r",            5)
        .attr("cx",           5).attr("cy", 4)
        .attr("fill",         levelColor(level))
        .attr("fill-opacity", 0.75)

      item.append("text")
        .attr("x",          14).attr("y", 8)
        .attr("fill",       PALETTE.text)
        .attr("font-size",  "10px")
        .attr("font-family","monospace")
        .text(levelLabel(level))
    })
  },
}

export default DependencyGraph
