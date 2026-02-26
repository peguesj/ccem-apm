import * as d3 from "../../vendor/d3.min.js"

const NODE_WIDTH = 200
const NODE_HEIGHT = 52

const WorkflowGraph = {
  mounted() {
    this.steps = []
    this.edges = []
    this.resizeObserver = new ResizeObserver(() => this.render())
    this.resizeObserver.observe(this.el)
    this.loadData()
    this.render()
  },

  updated() {
    this.loadData()
    this.render()
  },

  destroyed() {
    if (this.resizeObserver) this.resizeObserver.disconnect()
  },

  loadData() {
    try {
      this.steps = JSON.parse(this.el.dataset.steps || "[]")
      this.edges = JSON.parse(this.el.dataset.edges || "[]")
    } catch (e) {
      this.steps = []
      this.edges = []
    }
  },

  render() {
    const container = this.el
    const width = container.clientWidth || 800
    const height = container.clientHeight || 600

    d3.select(container).selectAll("svg").remove()

    if (this.steps.length === 0) return

    // Compute viewBox bounds from step positions
    const xs = this.steps.map(s => s.x || 0)
    const ys = this.steps.map(s => s.y || 0)
    const minX = Math.min(...xs) - 20
    const minY = Math.min(...ys) - 20
    const maxX = Math.max(...xs) + NODE_WIDTH + 40
    const maxY = Math.max(...ys) + NODE_HEIGHT + 60

    const svg = d3.select(container)
      .append("svg")
      .attr("width", "100%")
      .attr("height", "100%")
      .attr("viewBox", `${minX} ${minY} ${maxX - minX} ${maxY - minY}`)
      .attr("preserveAspectRatio", "xMidYMid meet")
      .style("background", "transparent")

    // Defs
    const defs = svg.append("defs")

    defs.append("marker")
      .attr("id", "wf-arrow")
      .attr("viewBox", "0 0 10 10")
      .attr("refX", 9)
      .attr("refY", 5)
      .attr("markerWidth", 7)
      .attr("markerHeight", 7)
      .attr("orient", "auto-start-reverse")
      .append("path")
      .attr("d", "M 0 0 L 10 5 L 0 10 z")
      .attr("fill", "#555")

    defs.append("style").text(`
      @keyframes wf-dash { to { stroke-dashoffset: -20; } }
      .wf-edge { stroke-dasharray: 6 3; animation: wf-dash 1.2s linear infinite; }
    `)

    // Build lookup
    const stepMap = {}
    this.steps.forEach(s => { stepMap[s.id] = s })

    // --- Edges ---
    const edgeG = svg.append("g")

    this.edges.forEach(edge => {
      const src = stepMap[edge.source]
      const tgt = stepMap[edge.target]
      if (!src || !tgt) return

      const srcX = (src.x || 0) + NODE_WIDTH / 2
      const srcY = (src.y || 0) + NODE_HEIGHT
      const tgtX = (tgt.x || 0) + NODE_WIDTH / 2
      const tgtY = tgt.y || 0

      const cx1 = srcX
      const cy1 = srcY + (tgtY - srcY) * 0.4
      const cx2 = tgtX
      const cy2 = srcY + (tgtY - srcY) * 0.6

      edgeG.append("path")
        .attr("d", `M ${srcX} ${srcY} C ${cx1} ${cy1}, ${cx2} ${cy2}, ${tgtX} ${tgtY}`)
        .attr("fill", "none")
        .attr("stroke", "#4a5568")
        .attr("stroke-width", 1.5)
        .attr("class", "wf-edge")
        .attr("marker-end", "url(#wf-arrow)")

      if (edge.label) {
        const mx = (srcX + tgtX) / 2
        const my = (srcY + tgtY) / 2

        edgeG.append("rect")
          .attr("x", mx - 18)
          .attr("y", my - 9)
          .attr("width", 36)
          .attr("height", 18)
          .attr("rx", 4)
          .attr("fill", "#1d232a")
          .attr("stroke", "#4a5568")
          .attr("stroke-width", 1)

        edgeG.append("text")
          .attr("x", mx)
          .attr("y", my + 4)
          .attr("text-anchor", "middle")
          .attr("font-size", "10px")
          .attr("fill", "#aaa")
          .text(edge.label)
      }
    })

    // --- Nodes ---
    const nodeG = svg.append("g")

    this.steps.forEach(step => {
      const nx = step.x || 0
      const ny = step.y || 0
      const color = step.color || "#6366f1"

      const g = nodeG.append("g")
        .attr("transform", `translate(${nx}, ${ny})`)
        .attr("cursor", "pointer")
        .style("opacity", 0)
        .on("click", () => {
          this.pushEvent("select_step", { id: step.id })
        })

      // Shadow
      g.append("rect")
        .attr("x", 2)
        .attr("y", 3)
        .attr("width", NODE_WIDTH)
        .attr("height", NODE_HEIGHT)
        .attr("rx", 8)
        .attr("fill", "rgba(0,0,0,0.25)")

      // Background
      g.append("rect")
        .attr("width", NODE_WIDTH)
        .attr("height", NODE_HEIGHT)
        .attr("rx", 8)
        .attr("fill", "#1a2234")
        .attr("stroke", color)
        .attr("stroke-width", 1.5)

      // Phase bar on left
      g.append("rect")
        .attr("x", 0)
        .attr("y", 0)
        .attr("width", 4)
        .attr("height", NODE_HEIGHT)
        .attr("rx", 2)
        .attr("fill", color)

      // Step number circle
      g.append("circle")
        .attr("cx", 22)
        .attr("cy", NODE_HEIGHT / 2)
        .attr("r", 10)
        .attr("fill", color)
        .attr("opacity", 0.85)

      g.append("text")
        .attr("x", 22)
        .attr("y", NODE_HEIGHT / 2 + 4)
        .attr("text-anchor", "middle")
        .attr("font-size", "10px")
        .attr("font-weight", "bold")
        .attr("fill", "#fff")
        .text(step.id)

      // Label
      g.append("text")
        .attr("x", 40)
        .attr("y", NODE_HEIGHT / 2 - 4)
        .attr("font-size", "12px")
        .attr("font-weight", "600")
        .attr("fill", "#e2e8f0")
        .text(truncate(step.label, 22))

      // Description
      g.append("text")
        .attr("x", 40)
        .attr("y", NODE_HEIGHT / 2 + 12)
        .attr("font-size", "9px")
        .attr("fill", "#718096")
        .text(truncate(step.description, 30))

      // Fade in
      g.transition()
        .duration(300)
        .delay((_, i) => i * 40)
        .style("opacity", 1)
    })
  }
}

function truncate(str, len) {
  if (!str) return ""
  return str.length > len ? str.slice(0, len) + "…" : str
}

export default WorkflowGraph
