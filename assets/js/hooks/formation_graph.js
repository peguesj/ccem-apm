/**
 * FormationGraph LiveView JS Hook
 *
 * D3.js tree layout for formation hierarchy visualization.
 * Renders formation > squadron > agent as a top-down tree with
 * status-colored nodes and animated connections.
 */
import * as d3 from "../../vendor/d3.min.js"

const COLORS = {
  bg: "#151b28",
  formation: { fill: "#6366f1", stroke: "#818cf8", text: "#e0e7ff" },
  squadron: { fill: "#0ea5e9", stroke: "#38bdf8", text: "#e0f2fe" },
  agent: {
    active: { fill: "#22c55e", stroke: "#4ade80" },
    idle: { fill: "#64748b", stroke: "#94a3b8" },
    error: { fill: "#ef4444", stroke: "#f87171" },
    default: { fill: "#475569", stroke: "#64748b" }
  },
  link: "#334155",
  text: "#e2e8f0",
  textDim: "#94a3b8"
}

const NODE_SIZES = {
  formation: { w: 140, h: 40, r: 8 },
  squadron: { w: 110, h: 32, r: 6 },
  agent: { w: 90, h: 28, r: 5 }
}

export default {
  mounted() {
    this.svg = null
    this.g = null
    this.initGraph()
    this.handleEvent("formation_data", (data) => this.render(data))
  },

  updated() {},

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
      .attr("fill", "#1e293b")

    this.svg.append("rect")
      .attr("width", "100%").attr("height", "100%")
      .attr("fill", "url(#formation-dots)")

    this.g = this.svg.append("g")

    // Zoom
    const zoom = d3.zoom()
      .scaleExtent([0.3, 3])
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
      .nodeSize([160, 100])
      .separation((a, b) => a.parent === b.parent ? 1.2 : 1.8)

    treeLayout(root)

    // Center the tree
    const allNodes = root.descendants()
    const minX = d3.min(allNodes, d => d.x) - 100
    const maxX = d3.max(allNodes, d => d.x) + 100
    const offsetX = width / 2 - (minX + maxX) / 2
    const offsetY = 60

    // Clear and re-render
    this.g.selectAll("*").remove()

    const container = this.g.append("g")
      .attr("transform", `translate(${offsetX}, ${offsetY})`)

    // Links
    container.selectAll(".link")
      .data(root.links())
      .join("path")
      .attr("class", "link")
      .attr("d", d3.linkVertical().x(d => d.x).y(d => d.y))
      .attr("fill", "none")
      .attr("stroke", COLORS.link)
      .attr("stroke-width", 1.5)
      .attr("stroke-dasharray", "4,3")
      .attr("opacity", 0.6)

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

      // Shadow
      g.append("rect")
        .attr("x", -size.w / 2 + 2)
        .attr("y", 2)
        .attr("width", size.w)
        .attr("height", size.h)
        .attr("rx", size.r)
        .attr("fill", "#000")
        .attr("opacity", 0.3)

      // Card
      g.append("rect")
        .attr("x", -size.w / 2)
        .attr("y", -size.h / 2 + size.h / 2)
        .attr("width", size.w)
        .attr("height", size.h)
        .attr("rx", size.r)
        .attr("fill", colors.fill)
        .attr("stroke", colors.stroke)
        .attr("stroke-width", 1.5)
        .attr("opacity", 0.9)

      // Status dot for agents
      if (d.data.level === "agent") {
        const statusColor = COLORS.agent[d.data.status] || COLORS.agent.default
        g.append("circle")
          .attr("cx", -size.w / 2 + 10)
          .attr("cy", size.h / 2)
          .attr("r", 3)
          .attr("fill", statusColor.fill)
      }

      // Label
      g.append("text")
        .attr("y", size.h / 2 + 1)
        .attr("text-anchor", "middle")
        .attr("fill", colors.text || COLORS.text)
        .attr("font-size", d.data.level === "agent" ? "10px" : "11px")
        .attr("font-weight", d.data.level === "formation" ? "600" : "500")
        .text(truncate(d.data.name, d.data.level === "agent" ? 12 : 16))

      // Count badge for non-agents
      if (d.data.count && d.data.count > 0) {
        g.append("circle")
          .attr("cx", size.w / 2 - 4)
          .attr("cy", 4)
          .attr("r", 8)
          .attr("fill", "#1e293b")
          .attr("stroke", colors.stroke)
          .attr("stroke-width", 1)
        g.append("text")
          .attr("x", size.w / 2 - 4)
          .attr("y", 7)
          .attr("text-anchor", "middle")
          .attr("fill", COLORS.text)
          .attr("font-size", "8px")
          .attr("font-weight", "600")
          .text(d.data.count)
      }

      // Story badge for agents
      if (d.data.story_id) {
        g.append("text")
          .attr("y", size.h + 12)
          .attr("text-anchor", "middle")
          .attr("fill", COLORS.textDim)
          .attr("font-size", "8px")
          .attr("font-family", "monospace")
          .text(d.data.story_id)
      }
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
  switch (data.level) {
    case "formation": return COLORS.formation
    case "squadron": return COLORS.squadron
    case "fleet": return { fill: "#1e1b4b", stroke: "#4338ca", text: "#c7d2fe" }
    default:
      const status = data.status || "default"
      const c = COLORS.agent[status] || COLORS.agent.default
      return { fill: c.fill, stroke: c.stroke, text: COLORS.text }
  }
}

function truncate(str, max) {
  if (!str) return ""
  return str.length > max ? str.slice(0, max - 1) + "..." : str
}
