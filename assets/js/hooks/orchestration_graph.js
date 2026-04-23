/**
 * OrchestrationGraph LiveView JS Hook
 *
 * Renders a DAG of orchestration run steps using D3 v7.
 * Nodes = steps colored by status, Edges = dependencies with arrows.
 * Click node → pushEvent step details to LiveView.
 *
 * Status colors:
 *   gray   = pending
 *   blue   = running (pulsing)
 *   green  = completed
 *   red    = failed
 *   yellow = skipped
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

const STATUS_COLORS = {
  pending:   "#6b7280",
  running:   "#3b82f6",
  completed: "#22c55e",
  failed:    "#ef4444",
  skipped:   "#eab308"
}

const OrchestrationGraph = {
  mounted() {
    this._render()

    this.handleEvent("run_updated", (data) => {
      if (data.steps && data.edges) {
        this.el.dataset.run = JSON.stringify(data)
        this._render()
      }
    })
  },

  updated() {
    this._render()
  },

  _render() {
    const raw = this.el.dataset.run
    if (!raw) return

    let data
    try { data = JSON.parse(raw) } catch { return }
    if (!data.steps || !data.edges) return

    const self = this

    ensureD3().then((d3) => {
      self._drawDAG(d3, data)
    })
  },

  _drawDAG(d3, data) {
    const container = this.el
    // Clear previous SVG using DOM API
    while (container.firstChild) {
      container.removeChild(container.firstChild)
    }

    const width = container.clientWidth || 600
    const height = container.clientHeight || 400
    const margin = { top: 40, right: 40, bottom: 40, left: 40 }

    const svg = d3.select(container)
      .append("svg")
      .attr("width", width)
      .attr("height", height)
      .style("background", "#1e1e2e")

    // Arrow marker
    svg.append("defs").append("marker")
      .attr("id", "orch-arrow")
      .attr("viewBox", "0 -5 10 10")
      .attr("refX", 25)
      .attr("refY", 0)
      .attr("markerWidth", 6)
      .attr("markerHeight", 6)
      .attr("orient", "auto")
      .append("path")
      .attr("d", "M0,-5L10,0L0,5")
      .attr("fill", "#475569")

    // Simple force layout
    const steps = data.steps.map(s => ({
      ...s,
      id: s.id,
      status: s.status || "pending"
    }))

    const edges = data.edges.map(e => ({
      source: e.source,
      target: e.target,
      label: e.label
    }))

    const stepMap = new Map(steps.map(s => [s.id, s]))

    // Use a simple hierarchical layout
    const levels = this._computeLevels(steps, edges)
    const maxLevel = Math.max(...Object.values(levels), 0)
    const levelWidth = (width - margin.left - margin.right) / (maxLevel + 1 || 1)

    // Group by level
    const byLevel = {}
    steps.forEach(s => {
      const lv = levels[s.id] || 0
      if (!byLevel[lv]) byLevel[lv] = []
      byLevel[lv].push(s)
    })

    // Position nodes
    Object.entries(byLevel).forEach(([lv, nodes]) => {
      const levelNum = parseInt(lv)
      const slotHeight = (height - margin.top - margin.bottom) / (nodes.length + 1)
      nodes.forEach((n, i) => {
        n.x = margin.left + levelNum * levelWidth + levelWidth / 2
        n.y = margin.top + (i + 1) * slotHeight
      })
    })

    const g = svg.append("g")

    // Draw edges
    g.selectAll(".edge")
      .data(edges)
      .join("line")
      .attr("class", "edge")
      .attr("x1", d => { const s = stepMap.get(d.source); return s ? s.x : 0 })
      .attr("y1", d => { const s = stepMap.get(d.source); return s ? s.y : 0 })
      .attr("x2", d => { const t = stepMap.get(d.target); return t ? t.x : 0 })
      .attr("y2", d => { const t = stepMap.get(d.target); return t ? t.y : 0 })
      .attr("stroke", "#475569")
      .attr("stroke-width", 1.5)
      .attr("marker-end", "url(#orch-arrow)")

    // Draw edge labels
    g.selectAll(".edge-label")
      .data(edges.filter(e => e.label))
      .join("text")
      .attr("class", "edge-label")
      .attr("x", d => {
        const s = stepMap.get(d.source)
        const t = stepMap.get(d.target)
        return s && t ? (s.x + t.x) / 2 : 0
      })
      .attr("y", d => {
        const s = stepMap.get(d.source)
        const t = stepMap.get(d.target)
        return s && t ? (s.y + t.y) / 2 - 5 : 0
      })
      .attr("fill", "#94a3b8")
      .attr("font-size", 10)
      .attr("text-anchor", "middle")
      .text(d => d.label)

    // Draw nodes
    const nodeG = g.selectAll(".node")
      .data(steps)
      .join("g")
      .attr("class", "node")
      .attr("transform", d => `translate(${d.x},${d.y})`)
      .style("cursor", "pointer")
      .on("click", (event, d) => {
        this.pushEvent("select_step", { step_id: d.id })
      })

    nodeG.append("circle")
      .attr("r", 18)
      .attr("fill", d => STATUS_COLORS[d.status] || STATUS_COLORS.pending)
      .attr("stroke", "#1e293b")
      .attr("stroke-width", 2)
      .each(function(d) {
        if (d.status === "running") {
          d3.select(this)
            .append("animate")
            .attr("attributeName", "opacity")
            .attr("values", "1;0.5;1")
            .attr("dur", "1.5s")
            .attr("repeatCount", "indefinite")
        }
      })

    nodeG.append("text")
      .attr("text-anchor", "middle")
      .attr("dy", 4)
      .attr("fill", "#fff")
      .attr("font-size", 10)
      .attr("font-weight", "bold")
      .text(d => d.id)

    // Labels below nodes
    nodeG.append("text")
      .attr("text-anchor", "middle")
      .attr("dy", 32)
      .attr("fill", "#94a3b8")
      .attr("font-size", 9)
      .text(d => {
        const label = (d.payload && (d.payload.label || d.payload.name)) || ""
        return label.length > 20 ? label.slice(0, 17) + "..." : label
      })

    // Zoom
    const zoom = d3.zoom()
      .scaleExtent([0.3, 3])
      .on("zoom", (event) => {
        g.attr("transform", event.transform)
      })

    svg.call(zoom)
  },

  _computeLevels(steps, edges) {
    const levels = {}
    const incoming = {}

    steps.forEach(s => {
      levels[s.id] = 0
      incoming[s.id] = []
    })

    edges.forEach(e => {
      if (incoming[e.target]) {
        incoming[e.target].push(e.source)
      }
    })

    // BFS topological ordering
    let changed = true
    let iterations = 0
    while (changed && iterations < 100) {
      changed = false
      iterations++
      edges.forEach(e => {
        const newLevel = (levels[e.source] || 0) + 1
        if (newLevel > (levels[e.target] || 0)) {
          levels[e.target] = newLevel
          changed = true
        }
      })
    }

    return levels
  }
}

export default OrchestrationGraph
