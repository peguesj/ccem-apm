/**
 * FormationGraph LiveView JS Hook
 *
 * D3.js tree layout for formation hierarchy visualization.
 * Renders formation > squadron > swarm > cluster > agent as a
 * top-down tree with status-colored nodes, agent_type styling,
 * wave swim lanes, and full metadata labels.
 *
 * Colors are sourced from design_tokens.js to stay in sync with the
 * daisyUI dark theme used across the CCEM APM dashboard.
 */
import { TOKENS, nodeColors as tokenNodeColors } from "../design_tokens.js"

// D3 lazy loading — only fetched on routes that render this hook
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

// Derived from TOKENS for backward-compatibility with inline references below
const COLORS = {
  bg:        TOKENS.bg.canvas,
  formation: TOKENS.formation.formation,
  squadron:  TOKENS.formation.squadron,
  swarm:     TOKENS.formation.swarm,
  cluster:   TOKENS.formation.cluster,
  session:   TOKENS.formation.session,
  task:      TOKENS.formation.task,
  fleet:     TOKENS.formation.fleet,
  agent:     TOKENS.formation.agent,
  link:      TOKENS.edge.default,
  text:      TOKENS.text.primary,
  textDim:   TOKENS.text.secondary,
}

// Node dimensions per hierarchy level
const NODE_SIZES = {
  formation: { w: 150, h: 42, r: 8 },
  squadron:  { w: 120, h: 34, r: 6 },
  swarm:     { w: 100, h: 30, r: 5 },
  cluster:   { w: 90,  h: 28, r: 5 },
  agent:     { w: 90,  h: 28, r: 5 },
}

// Agent type indicators (border style modifier)
const AGENT_TYPE_STYLES = {
  orchestrator:   { strokeWidth: 2.5, dashArray: null,  strokeBoost: "#a78bfa" },
  squadron_lead:  { strokeWidth: 2.0, dashArray: null,  strokeBoost: "#38bdf8" },
  swarm_agent:    { strokeWidth: 1.5, dashArray: "4,2", strokeBoost: null },
  cluster_agent:  { strokeWidth: 1.5, dashArray: "2,2", strokeBoost: null },
  individual:     { strokeWidth: 1.5, dashArray: null,  strokeBoost: null },
}

export default {
  async mounted() {
    await ensureD3()
    this.svg = null
    this.g = null
    this.initGraph()
    this.handleEvent("formation_data", (data) => this.render(data))
  },

  async updated() {},

  destroyed() {
    if (this._resizeObs) this._resizeObs.disconnect()
  },

  initGraph() {
    const el = this.el
    const { width, height } = el.getBoundingClientRect()

    this.svg = d3.select(el)
      .append("svg")
      .attr("width", "100%")
      .attr("height", "100%")
      .attr("viewBox", `0 0 ${width} ${height}`)

    // Dot grid background
    const defs = this.svg.append("defs")
    const pattern = defs.append("pattern")
      .attr("id", "formation-dots")
      .attr("width", 20).attr("height", 20)
      .attr("patternUnits", "userSpaceOnUse")
    pattern.append("circle")
      .attr("cx", 10).attr("cy", 10).attr("r", 0.8)
      .attr("fill", TOKENS.dotGrid.dot)

    this.svg.append("rect")
      .attr("width", "100%").attr("height", "100%")
      .attr("fill", "url(#formation-dots)")

    this.g = this.svg.append("g")

    // Zoom
    const zoom = d3.zoom()
      .scaleExtent([0.2, 4])
      .on("zoom", (e) => this.g.attr("transform", e.transform))
    this.svg.call(zoom)

    // Resize observer
    this._resizeObs = new ResizeObserver(() => {
      const r = el.getBoundingClientRect()
      this.svg.attr("viewBox", `0 0 ${r.width} ${r.height}`)
    })
    this._resizeObs.observe(el)
  },

  render(data) {
    const { nodes, edges } = data
    if (!nodes || nodes.length === 0) return

    const { width, height } = this.el.getBoundingClientRect()

    // Build hierarchy from edges
    const root = this.buildTree(nodes, edges)
    if (!root) return

    const treeLayout = d3.tree()
      .nodeSize([170, 110])
      .separation((a, b) => a.parent === b.parent ? 1.2 : 1.8)

    treeLayout(root)

    // Center the tree
    const allNodes = root.descendants()
    const minX = d3.min(allNodes, d => d.x) - 110
    const maxX = d3.max(allNodes, d => d.x) + 110
    const offsetX = width / 2 - (minX + maxX) / 2
    const offsetY = 60

    // Clear and re-render
    this.g.selectAll("*").remove()

    const container = this.g.append("g")
      .attr("transform", `translate(${offsetX}, ${offsetY})`)

    // Wave swim-lane backgrounds (group agents by wave_number)
    this._renderWaveLanes(container, allNodes)

    // Links
    container.selectAll(".link")
      .data(root.links())
      .join("path")
      .attr("class", "link")
      .attr("d", d3.linkVertical().x(d => d.x).y(d => d.y))
      .attr("fill", "none")
      .attr("stroke", d => {
        const lvl = d.target.data.level
        if (lvl === "swarm") return COLORS.swarm.stroke
        if (lvl === "cluster") return COLORS.cluster.stroke
        return COLORS.link
      })
      .attr("stroke-width", d => {
        const lvl = d.target.data.level
        return (lvl === "formation" || lvl === "squadron") ? 1.5 : 1
      })
      .attr("stroke-dasharray", d => {
        const lvl = d.target.data.level
        return (lvl === "agent") ? "3,3" : "5,3"
      })
      .attr("opacity", 0.5)

    // Nodes
    const nodeGroups = container.selectAll(".node")
      .data(allNodes)
      .join("g")
      .attr("class", "node")
      .attr("transform", d => `translate(${d.x}, ${d.y})`)
      .style("cursor", "pointer")
      .on("click", (event, d) => {
        this.pushEvent("node_clicked", { id: d.data.id, level: d.data.level })
      })

    // Node rectangles
    nodeGroups.each(function(d) {
      const g = d3.select(this)
      const size = NODE_SIZES[d.data.level] || NODE_SIZES.agent
      const colors = getNodeColors(d.data)
      const agentStyle = d.data.level === "agent"
        ? (AGENT_TYPE_STYLES[d.data.agent_type] || AGENT_TYPE_STYLES.individual)
        : null

      const strokeColor = (agentStyle && agentStyle.strokeBoost) || colors.stroke
      const strokeWidth = agentStyle ? agentStyle.strokeWidth : 1.5

      // Shadow
      g.append("rect")
        .attr("x", -size.w / 2 + 2)
        .attr("y", 2)
        .attr("width", size.w)
        .attr("height", size.h)
        .attr("rx", size.r)
        .attr("fill", "#000")
        .attr("opacity", 0.25)

      // Card
      g.append("rect")
        .attr("x", -size.w / 2)
        .attr("y", 0)
        .attr("width", size.w)
        .attr("height", size.h)
        .attr("rx", size.r)
        .attr("fill", colors.fill)
        .attr("stroke", strokeColor)
        .attr("stroke-width", strokeWidth)
        .attr("stroke-dasharray", agentStyle ? (agentStyle.dashArray || "none") : "none")
        .attr("opacity", 0.95)

      // Status dot (agents, swarms, clusters)
      if (d.data.level === "agent" || d.data.level === "swarm" || d.data.level === "cluster") {
        const statusCol = statusDotColor(d.data.status)
        g.append("circle")
          .attr("cx", -size.w / 2 + 9)
          .attr("cy", size.h / 2)
          .attr("r", 3)
          .attr("fill", statusCol)
      }

      // Agent type badge top-right corner (orchestrator / squadron_lead)
      if (d.data.level === "agent" && d.data.agent_type &&
          d.data.agent_type !== "individual" && d.data.agent_type !== null) {
        const badgeLabel = agentTypeBadge(d.data.agent_type)
        if (badgeLabel) {
          g.append("rect")
            .attr("x", size.w / 2 - 26)
            .attr("y", -2)
            .attr("width", 24)
            .attr("height", 10)
            .attr("rx", 3)
            .attr("fill", "#1e1b4b")
            .attr("stroke", strokeColor)
            .attr("stroke-width", 0.8)
            .attr("opacity", 0.9)
          g.append("text")
            .attr("x", size.w / 2 - 14)
            .attr("y", 7)
            .attr("text-anchor", "middle")
            .attr("fill", strokeColor)
            .attr("font-size", "7px")
            .attr("font-weight", "600")
            .text(badgeLabel)
        }
      }

      // Primary label
      const labelX = (d.data.level === "agent" || d.data.level === "swarm" || d.data.level === "cluster")
        ? -size.w / 2 + 18 : 0
      const labelAnchor = (d.data.level === "agent" || d.data.level === "swarm" || d.data.level === "cluster")
        ? "start" : "middle"

      g.append("text")
        .attr("x", labelX)
        .attr("y", size.h / 2 + 1)
        .attr("text-anchor", labelAnchor)
        .attr("dominant-baseline", "middle")
        .attr("fill", colors.text || COLORS.text)
        .attr("font-size", d.data.level === "agent" ? "10px" : "11px")
        .attr("font-weight", d.data.level === "formation" ? "600" : "500")
        .text(truncate(d.data.name, d.data.level === "agent" ? 11 : 15))

      // Count badge (non-agents)
      if (d.data.count && d.data.count > 0) {
        g.append("circle")
          .attr("cx", size.w / 2 - 4)
          .attr("cy", size.h / 2)
          .attr("r", 9)
          .attr("fill", "#1e293b")
          .attr("stroke", colors.stroke)
          .attr("stroke-width", 1)
        g.append("text")
          .attr("x", size.w / 2 - 4)
          .attr("y", size.h / 2 + 1)
          .attr("text-anchor", "middle")
          .attr("dominant-baseline", "middle")
          .attr("fill", COLORS.text)
          .attr("font-size", "8px")
          .attr("font-weight", "600")
          .text(d.data.count)
      }

      // Story / work item label below agent node
      const subLabel = d.data.story_id || d.data.work_item_title
      if (subLabel && d.data.level === "agent") {
        g.append("text")
          .attr("y", size.h + 11)
          .attr("text-anchor", "middle")
          .attr("fill", d.data.story_id ? TOKENS.text.code : COLORS.textDim)
          .attr("font-size", "8px")
          .attr("font-family", "monospace")
          .text(truncate(subLabel, 14))
      }

      // Wave number badge (agents only, if wave_number present)
      if (d.data.wave_number != null && d.data.level === "agent") {
        g.append("text")
          .attr("x", size.w / 2 - 4)
          .attr("y", size.h + 11)
          .attr("text-anchor", "middle")
          .attr("fill", TOKENS.text.muted)
          .attr("font-size", "7px")
          .text(`W${d.data.wave_number}`)
      }
    })
  },

  // Draw subtle horizontal swim-lane bands for each wave_number group
  _renderWaveLanes(container, allNodes) {
    const agentNodes = allNodes.filter(d => d.data.level === "agent" && d.data.wave_number != null)
    if (agentNodes.length === 0) return

    const byWave = d3.group(agentNodes, d => d.data.wave_number)
    byWave.forEach((waveNodes, waveNum) => {
      const minX = d3.min(waveNodes, d => d.x) - 60
      const maxX = d3.max(waveNodes, d => d.x) + 60
      const minY = d3.min(waveNodes, d => d.y) - 18
      const maxY = d3.max(waveNodes, d => d.y) + 46

      container.insert("rect", ":first-child")
        .attr("x", minX)
        .attr("y", minY)
        .attr("width", maxX - minX)
        .attr("height", maxY - minY)
        .attr("rx", 8)
        .attr("fill", "none")
        .attr("stroke", "#334155")
        .attr("stroke-width", 1)
        .attr("stroke-dasharray", "6,4")
        .attr("opacity", 0.4)

      container.insert("text", ":first-child")
        .attr("x", minX + 8)
        .attr("y", minY + 12)
        .attr("fill", TOKENS.text.muted)
        .attr("font-size", "9px")
        .attr("font-family", "monospace")
        .text(`wave ${waveNum}`)
    })
  },

  buildTree(nodes, edges) {
    if (nodes.length === 0) return null

    const nodeMap = new Map(nodes.map(n => [n.id, { ...n, children: [] }]))
    const childIds = new Set()

    edges.forEach(e => {
      const parent = nodeMap.get(e.source)
      const child = nodeMap.get(e.target)
      if (parent && child) {
        parent.children.push(child)
        childIds.add(e.target)
      }
    })

    // Root is the node that's never a child
    const roots = nodes.filter(n => !childIds.has(n.id)).map(n => nodeMap.get(n.id))

    if (roots.length === 0) return null
    if (roots.length === 1) return d3.hierarchy(roots[0])

    // Multiple roots: wrap in virtual root
    const virtualRoot = { id: "__root__", name: "Fleet", level: "fleet", children: roots }
    return d3.hierarchy(virtualRoot)
  }
}

function getNodeColors(data) {
  return tokenNodeColors(data.level, data.status)
}

function statusDotColor(status) {
  switch ((status || "").toLowerCase()) {
    case "active":
    case "working":
    case "running":    return TOKENS.status.success
    case "complete":
    case "pass":
    case "done":       return TOKENS.status.info
    case "error":
    case "failed":     return TOKENS.status.error
    case "idle":
    case "pending":    return TOKENS.status.warning
    default:           return TOKENS.text.muted
  }
}

function agentTypeBadge(type) {
  switch (type) {
    case "orchestrator":  return "ORCH"
    case "squadron_lead": return "LEAD"
    case "swarm_agent":   return "SWM"
    case "cluster_agent": return "CLU"
    default:              return null
  }
}

function truncate(str, max) {
  if (!str) return ""
  return str.length > max ? str.slice(0, max - 1) + "…" : str
}
