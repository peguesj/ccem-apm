/**
 * RoutingGraph LiveView JS Hook
 *
 * D3.js force-directed graph for authorization routing visualization.
 * Renders sessions → agents → tools with risk levels and approval gates.
 *
 * Events:
 *   - "routing:data" — full graph data from LiveView
 *   - "routing:audit_trail" — agent-scoped audit entries
 */

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

const PALETTE = {
  bg:        "#0f172a",
  border:    "#1e293b",
  text:      "#e2e8f0",
  textDim:   "#94a3b8",
}

const NODE_COLORS = {
  session:       "#7c3aed",
  agent:         "#3b82f6",
  tool:          "#22c55e",
  approval_gate: "#f59e0b",
}

const RISK_COLORS = {
  critical: "#ef4444",
  high:     "#f97316",
  medium:   "#eab308",
  low:      "#22c55e",
  minimal:  "#6b7280",
}

const STATUS_COLORS = {
  active:    "#22c55e",
  idle:      "#6b7280",
  error:     "#ef4444",
  pending:   "#f59e0b",
  unknown:   "#475569",
}

function nodeColor(type) {
  return NODE_COLORS[type] || "#6b7280"
}

function riskColor(level) {
  return RISK_COLORS[(level || "").toLowerCase()] || RISK_COLORS.minimal
}

function statusDot(status) {
  return STATUS_COLORS[(status || "").toLowerCase()] || STATUS_COLORS.unknown
}

const RoutingGraph = {
  async mounted() {
    await ensureD3()
    this._container = d3.select(this.el)
    this._graphData = null
    this._simulation = null
    this._tooltip = null
    this._svg = null

    this.handleEvent("routing:data", (data) => {
      this._graphData = data
      this._render()
    })

    this.handleEvent("routing:audit_trail", (_data) => {
      // Audit trail handled by LiveView side panel
    })
  },

  destroyed() {
    if (this._simulation) this._simulation.stop()
    if (this._tooltip) this._tooltip.remove()
    if (this._svg) this._svg.remove()
  },

  _render() {
    const data = this._graphData
    if (!data) return this._renderEmpty()

    const { agents = [], sessions = [], tools = [], gates = [] } = data.graph || data

    // Build nodes and links
    const nodes = []
    const links = []

    sessions.forEach(s => {
      nodes.push({ ...s, nodeType: "session", radius: 18 })
    })

    agents.forEach(a => {
      nodes.push({ ...a, nodeType: "agent", radius: 14 })
      // Link agent to its parent session (if known)
      if (a.parent_id) {
        const parentNode = nodes.find(n => n.id === a.parent_id)
        if (parentNode) links.push({ source: a.parent_id, target: a.id, type: "parent" })
      }
    })

    tools.forEach(t => {
      nodes.push({ ...t, nodeType: "tool", radius: 10 })
    })

    gates.forEach(g => {
      nodes.push({ ...g, nodeType: "approval_gate", radius: 12 })
      if (g.agent_id) {
        links.push({ source: g.agent_id, target: g.id, type: "gate" })
      }
      if (g.tool_name) {
        const toolNode = nodes.find(n => n.id === g.tool_name)
        if (toolNode) links.push({ source: g.id, target: g.tool_name, type: "gate_tool" })
      }
    })

    // Link agents to tools (implicit: all agents can use all tools)
    // For a cleaner graph, only link if we have authorization data
    if (agents.length > 0 && tools.length > 0 && agents.length <= 20) {
      agents.forEach(a => {
        tools.slice(0, 5).forEach(t => {
          links.push({ source: a.id, target: t.id, type: "tool_access", opacity: 0.15 })
        })
      })
    }

    if (nodes.length === 0) return this._renderEmpty()

    const rect = this.el.getBoundingClientRect()
    const W = Math.max(rect.width || 800, 400)
    const H = Math.max(rect.height || 600, 350)

    // Clear previous
    this._container.selectAll("*").remove()
    if (this._simulation) this._simulation.stop()

    const svg = this._container.append("svg")
      .attr("width", "100%")
      .attr("height", "100%")
      .attr("viewBox", `0 0 ${W} ${H}`)
      .style("background", PALETTE.bg)

    this._svg = svg

    // Tooltip
    this._tooltip = this._container.append("div")
      .style("position", "absolute")
      .style("pointer-events", "none")
      .style("opacity", 0)
      .style("background", "rgba(15,23,42,0.95)")
      .style("border", `1px solid ${PALETTE.border}`)
      .style("border-radius", "8px")
      .style("padding", "8px 12px")
      .style("font-size", "11px")
      .style("color", PALETTE.text)
      .style("font-family", "monospace")
      .style("z-index", "1000")
      .style("max-width", "250px")

    // Arrowhead markers
    const defs = svg.append("defs")
    ;["parent", "gate", "gate_tool", "tool_access"].forEach(type => {
      defs.append("marker")
        .attr("id", `arrow-${type}`)
        .attr("viewBox", "0 -5 10 10")
        .attr("refX", 20)
        .attr("refY", 0)
        .attr("markerWidth", 6)
        .attr("markerHeight", 6)
        .attr("orient", "auto")
        .append("path")
        .attr("d", "M0,-5L10,0L0,5")
        .attr("fill", type === "gate" ? "#f59e0b" : "#334155")
    })

    // Zoom
    const g = svg.append("g")
    svg.call(d3.zoom()
      .scaleExtent([0.3, 4])
      .on("zoom", (event) => g.attr("transform", event.transform))
    )

    // Force simulation
    const simulation = d3.forceSimulation(nodes)
      .force("link", d3.forceLink(links).id(d => d.id).distance(80))
      .force("charge", d3.forceManyBody().strength(-300))
      .force("center", d3.forceCenter(W / 2, H / 2))
      .force("collision", d3.forceCollide().radius(d => d.radius + 5))
      .force("x", d3.forceX(W / 2).strength(0.05))
      .force("y", d3.forceY(H / 2).strength(0.05))

    this._simulation = simulation

    // Links
    const link = g.append("g")
      .selectAll("line")
      .data(links)
      .join("line")
      .attr("stroke", d => d.type === "gate" ? "#f59e0b" : "#1e293b")
      .attr("stroke-width", d => d.type === "tool_access" ? 0.5 : 1.5)
      .attr("stroke-opacity", d => d.opacity || 0.6)
      .attr("marker-end", d => `url(#arrow-${d.type})`)

    // Nodes
    const self = this
    const node = g.append("g")
      .selectAll("g")
      .data(nodes)
      .join("g")
      .attr("cursor", "pointer")
      .call(d3.drag()
        .on("start", (event, d) => {
          if (!event.active) simulation.alphaTarget(0.3).restart()
          d.fx = d.x; d.fy = d.y
        })
        .on("drag", (event, d) => { d.fx = event.x; d.fy = event.y })
        .on("end", (event, d) => {
          if (!event.active) simulation.alphaTarget(0)
          d.fx = null; d.fy = null
        })
      )
      .on("click", (_event, d) => {
        if (d.nodeType === "agent") {
          self.pushEvent("select_agent", { id: d.id })
        }
      })

    // Node shapes
    node.each(function(d) {
      const el = d3.select(this)
      const color = nodeColor(d.nodeType)

      if (d.nodeType === "approval_gate") {
        // Diamond shape for gates
        el.append("rect")
          .attr("width", d.radius * 1.4)
          .attr("height", d.radius * 1.4)
          .attr("x", -d.radius * 0.7)
          .attr("y", -d.radius * 0.7)
          .attr("transform", "rotate(45)")
          .attr("fill", color)
          .attr("fill-opacity", 0.2)
          .attr("stroke", color)
          .attr("stroke-width", 1.5)
      } else {
        // Circle for sessions, agents, tools
        el.append("circle")
          .attr("r", d.radius)
          .attr("fill", color)
          .attr("fill-opacity", 0.15)
          .attr("stroke", color)
          .attr("stroke-width", 1.5)
      }

      // Status dot
      if (d.status) {
        el.append("circle")
          .attr("cx", d.radius * 0.7)
          .attr("cy", -d.radius * 0.7)
          .attr("r", 3)
          .attr("fill", statusDot(d.status))
      }

      // Risk badge for tools
      if (d.risk_level) {
        el.append("circle")
          .attr("cx", -d.radius * 0.7)
          .attr("cy", -d.radius * 0.7)
          .attr("r", 3)
          .attr("fill", riskColor(d.risk_level))
      }

      // Label
      el.append("text")
        .attr("y", d.radius + 14)
        .attr("text-anchor", "middle")
        .attr("fill", PALETTE.textDim)
        .attr("font-size", "10px")
        .attr("font-family", "monospace")
        .text((d.role || d.id || "").substring(0, 16))
    })

    // Tooltip interactions
    node
      .on("mouseenter", (event, d) => {
        const lines = [
          `<b>${d.nodeType}</b>: ${d.id}`,
          d.status ? `Status: ${d.status}` : null,
          d.risk_level ? `Risk: ${d.risk_level}` : null,
          d.trust_ceiling ? `Trust: ${d.trust_ceiling}` : null,
          d.role ? `Role: ${d.role}` : null,
          d.tool_calls != null ? `Tool calls: ${d.tool_calls}` : null,
          d.denied != null ? `Denied: ${d.denied}` : null,
        ].filter(Boolean).join("<br>")

        self._tooltip
          .html(lines)
          .style("opacity", 1)
          .style("left", `${event.offsetX + 12}px`)
          .style("top", `${event.offsetY - 12}px`)
      })
      .on("mouseleave", () => {
        self._tooltip.style("opacity", 0)
      })

    // Tick
    simulation.on("tick", () => {
      link
        .attr("x1", d => d.source.x)
        .attr("y1", d => d.source.y)
        .attr("x2", d => d.target.x)
        .attr("y2", d => d.target.y)

      node.attr("transform", d => `translate(${d.x},${d.y})`)
    })

    // Legend
    this._renderLegend(svg, W)
  },

  _renderLegend(svg, W) {
    const legend = svg.append("g")
      .attr("transform", `translate(${W - 160}, 16)`)

    const items = [
      { label: "Session", color: NODE_COLORS.session },
      { label: "Agent", color: NODE_COLORS.agent },
      { label: "Tool", color: NODE_COLORS.tool },
      { label: "Approval Gate", color: NODE_COLORS.approval_gate },
    ]

    items.forEach((item, i) => {
      const g = legend.append("g").attr("transform", `translate(0, ${i * 18})`)
      g.append("circle").attr("r", 5).attr("fill", item.color).attr("fill-opacity", 0.4).attr("stroke", item.color)
      g.append("text").attr("x", 12).attr("y", 4).attr("fill", PALETTE.textDim).attr("font-size", "10px").text(item.label)
    })
  },

  _renderEmpty() {
    const rect = this.el.getBoundingClientRect()
    const W = rect.width || 800
    const H = rect.height || 400

    this._container.selectAll("*").remove()
    const svg = this._container.append("svg")
      .attr("width", "100%")
      .attr("height", "100%")
      .attr("viewBox", `0 0 ${W} ${H}`)
      .style("background", PALETTE.bg)

    svg.append("text")
      .attr("x", W / 2)
      .attr("y", H / 2)
      .attr("text-anchor", "middle")
      .attr("fill", "#475569")
      .attr("font-size", "14px")
      .attr("font-family", "monospace")
      .text("No authorization routing data available")

    svg.append("text")
      .attr("x", W / 2)
      .attr("y", H / 2 + 22)
      .attr("text-anchor", "middle")
      .attr("fill", "#334155")
      .attr("font-size", "11px")
      .attr("font-family", "monospace")
      .text("Authorization events will appear here when agents are active")
  },
}

export default RoutingGraph
