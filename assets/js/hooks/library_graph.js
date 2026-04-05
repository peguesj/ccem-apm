/**
 * LibraryGraph LiveView JS Hook
 *
 * Railway-inspired D3 force-directed graph of the CCEM library:
 *   skills / agents / commands / tools / patterns / learnings / MCP servers
 *
 * Visual style:
 *   - Dark bg #0f1420 with dot grid
 *   - Glassmorphic node cards
 *   - Soft glow on hover, pulse-in on node entry
 *
 * LiveView contract:
 *   - handleEvent("graph_data", {nodes, edges, metadata}) -> render
 *   - handleEvent("focus_node", id)                       -> center/highlight a node
 *   - pushEvent("focus_node", id)                         -> when user clicks a node
 *
 * Keyboard:
 *   arrows = pan, +/- = zoom, Enter = focus selected, Escape = reset
 */

const NODE_COLORS = {
  skill:    "#5daaff",
  agent:    "#7eef6d",
  command:  "#ffaa44",
  tool:     "#c084fc",
  pattern:  "#fde047",
  learning: "#9ca3af",
  mcp:      "#f472b6"
}

const NODE_RADIUS = 18
const BG_COLOR = "#0f1420"

// D3 lazy loading (mirrors alignment_graph.js pattern)
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
    script.onerror = () => reject(new Error("Failed to load D3"))
    document.head.appendChild(script)
  })
  return _d3LoadPromise
}

export default {
  async mounted() {
    await ensureD3()
    this._data = null
    this._sim = null
    this._svg = null
    this._zoomBehavior = null
    this._g = null
    this._selectedId = null
    this._resizeObserver = null

    this._initSvg()
    this._initKeyboard()

    this.handleEvent("graph_data", (data) => {
      this._data = data
      this._render(data)
    })

    this.handleEvent("focus_node", (payload) => {
      const id = typeof payload === "string" ? payload : payload && payload.id
      if (id) this._focusNode(id)
    })

    this._resizeObserver = new ResizeObserver(() => {
      if (this._data) this._render(this._data)
    })
    this._resizeObserver.observe(this.el)
  },

  destroyed() {
    if (this._sim) this._sim.stop()
    if (this._resizeObserver) this._resizeObserver.disconnect()
    if (this._keyHandler) window.removeEventListener("keydown", this._keyHandler)
  },

  _initSvg() {
    this.el.innerHTML = ""
    this.el.style.background = BG_COLOR
    this.el.style.backgroundImage =
      "radial-gradient(rgba(255,255,255,0.06) 1px, transparent 1px)"
    this.el.style.backgroundSize = "18px 18px"
    this.el.style.position = "relative"
    this.el.style.overflow = "hidden"

    const { width, height } = this.el.getBoundingClientRect()
    const w = Math.max(width, 400)
    const h = Math.max(height, 300)

    this._svg = d3.select(this.el)
      .append("svg")
      .attr("width", "100%")
      .attr("height", "100%")
      .attr("viewBox", `0 0 ${w} ${h}`)
      .style("display", "block")

    // Defs: glow filter
    const defs = this._svg.append("defs")
    const glow = defs.append("filter").attr("id", "library-glow")
    glow.append("feGaussianBlur").attr("stdDeviation", "3").attr("result", "blur")
    const feMerge = glow.append("feMerge")
    feMerge.append("feMergeNode").attr("in", "blur")
    feMerge.append("feMergeNode").attr("in", "SourceGraphic")

    // Top-level group for zoom/pan
    this._g = this._svg.append("g").attr("class", "library-root")

    this._zoomBehavior = d3.zoom()
      .scaleExtent([0.2, 4])
      .on("zoom", (event) => this._g.attr("transform", event.transform))
    this._svg.call(this._zoomBehavior)
  },

  _initKeyboard() {
    this._keyHandler = (e) => {
      if (!this._svg) return
      const step = 40
      const current = d3.zoomTransform(this._svg.node())
      switch (e.key) {
        case "ArrowLeft":
          this._svg.call(this._zoomBehavior.translateBy, step, 0); break
        case "ArrowRight":
          this._svg.call(this._zoomBehavior.translateBy, -step, 0); break
        case "ArrowUp":
          this._svg.call(this._zoomBehavior.translateBy, 0, step); break
        case "ArrowDown":
          this._svg.call(this._zoomBehavior.translateBy, 0, -step); break
        case "+":
        case "=":
          this._svg.transition().call(this._zoomBehavior.scaleBy, 1.25); break
        case "-":
        case "_":
          this._svg.transition().call(this._zoomBehavior.scaleBy, 0.8); break
        case "Enter":
          if (this._selectedId) {
            this.pushEvent("focus_node", this._selectedId)
            this._focusNode(this._selectedId)
          }
          break
        case "Escape":
          this._svg.transition().call(this._zoomBehavior.transform, d3.zoomIdentity)
          this._selectedId = null
          this._g.selectAll(".library-node").classed("is-focused", false)
          break
        default:
          return
      }
    }
    window.addEventListener("keydown", this._keyHandler)
  },

  _render(data) {
    if (!data || !data.nodes) return
    const { width, height } = this.el.getBoundingClientRect()
    const w = Math.max(width, 400)
    const h = Math.max(height, 300)

    // Clear previous contents except defs
    this._g.selectAll("*").remove()

    const nodes = data.nodes.map(n => ({ ...n }))
    const edges = data.edges.map(e => ({ ...e }))

    if (this._sim) this._sim.stop()
    this._sim = d3.forceSimulation(nodes)
      .force("link", d3.forceLink(edges).id(d => d.id).distance(80))
      .force("charge", d3.forceManyBody().strength(-400))
      .force("center", d3.forceCenter(w / 2, h / 2))
      .force("collision", d3.forceCollide().radius(NODE_RADIUS + 6))

    // Edges
    const link = this._g.append("g")
      .attr("class", "library-edges")
      .attr("stroke", "rgba(148,163,184,0.35)")
      .attr("stroke-width", 1)
      .selectAll("line")
      .data(edges)
      .join("line")
      .attr("stroke-dasharray", d => d.relationship === "wraps" ? "4 3" : null)

    link.append("title").text(d => d.relationship)

    // Nodes
    const node = this._g.append("g")
      .attr("class", "library-nodes")
      .selectAll("g")
      .data(nodes, d => d.id)
      .join("g")
      .attr("class", "library-node")
      .style("cursor", "pointer")
      .on("click", (_event, d) => {
        this._selectedId = d.id
        this.pushEvent("focus_node", d.id)
        this._g.selectAll(".library-node").classed("is-focused", false)
        d3.select(_event.currentTarget).classed("is-focused", true)
      })
      .on("mouseover", (_event, _d) => {
        d3.select(_event.currentTarget).select("circle")
          .attr("filter", "url(#library-glow)")
      })
      .on("mouseout", (_event, _d) => {
        d3.select(_event.currentTarget).select("circle").attr("filter", null)
      })
      .call(
        d3.drag()
          .on("start", (event, d) => {
            if (!event.active) this._sim.alphaTarget(0.3).restart()
            d.fx = d.x; d.fy = d.y
          })
          .on("drag", (event, d) => { d.fx = event.x; d.fy = event.y })
          .on("end", (event, d) => {
            if (!event.active) this._sim.alphaTarget(0)
            d.fx = null; d.fy = null
          })
      )

    node.append("circle")
      .attr("r", 0)
      .attr("fill", d => NODE_COLORS[d.type] || "#94a3b8")
      .attr("fill-opacity", 0.85)
      .attr("stroke", "rgba(255,255,255,0.6)")
      .attr("stroke-width", 1.25)
      .transition().duration(300)
      .attr("r", NODE_RADIUS)

    node.append("text")
      .attr("dy", NODE_RADIUS + 14)
      .attr("text-anchor", "middle")
      .attr("fill", "#e2e8f0")
      .attr("font-size", "11px")
      .attr("font-family", "system-ui, -apple-system, sans-serif")
      .text(d => (d.label || d.id).slice(0, 20))

    node.append("title")
      .text(d => `${d.type}: ${d.label || d.id}`)

    this._sim.on("tick", () => {
      link
        .attr("x1", d => d.source.x)
        .attr("y1", d => d.source.y)
        .attr("x2", d => d.target.x)
        .attr("y2", d => d.target.y)
      node.attr("transform", d => `translate(${d.x},${d.y})`)
    })
  },

  _focusNode(id) {
    if (!this._data || !this._svg || !this._zoomBehavior) return
    const target = this._data.nodes.find(n => n.id === id)
    if (!target || target.x == null) return

    const { width, height } = this.el.getBoundingClientRect()
    const tx = width / 2 - target.x
    const ty = height / 2 - target.y
    const transform = d3.zoomIdentity.translate(tx, ty).scale(1.3)
    this._svg.transition().duration(500).call(this._zoomBehavior.transform, transform)

    this._selectedId = id
    this._g.selectAll(".library-node").classed("is-focused", n => n.id === id)
  }
}
