/**
 * DependencyGraph LiveView JS Hook
 *
 * Renders a D3.js force-directed graph of agents as nodes with dependency edges.
 * Nodes are color-coded by status, draggable, and show tooltips on hover.
 * Receives agent data from LiveView via pushEvent/handleEvent.
 */
import * as d3 from "../../vendor/d3.min.js"

const STATUS_COLORS = {
  active: "#3fb950",
  idle: "#8b949e",
  error: "#f85149",
  discovered: "#58a6ff"
}

const STATUS_FILL = {
  active: "#3fb95033",
  idle: "#8b949e22",
  error: "#f8514933",
  discovered: "#58a6ff33"
}

const TIER_COLORS = {
  1: "#1f6feb",
  2: "#8957e5",
  3: "#f0883e"
}

const DependencyGraph = {
  mounted() {
    this.svg = d3.select(this.el).append("svg")
      .attr("width", "100%")
      .attr("height", "100%")

    // Tooltip div
    this.tooltip = d3.select(this.el).append("div")
      .attr("class", "absolute hidden bg-base-100 border border-base-300 rounded-lg shadow-xl p-3 text-xs z-50 pointer-events-none max-w-[200px]")
      .style("position", "absolute")

    this.simulation = null
    this.agents = []
    this.edges = []

    // Listen for agent data updates from LiveView
    this.handleEvent("agents_updated", (data) => {
      this.agents = data.agents || []
      this.edges = data.edges || []
      this.draw()
    })

    // Initial draw with empty state
    this.draw()

    // Handle resize
    this.resizeObserver = new ResizeObserver(() => this.draw())
    this.resizeObserver.observe(this.el)
  },

  updated() {
    // LiveView may push new data on update
  },

  destroyed() {
    if (this.simulation) this.simulation.stop()
    if (this.resizeObserver) this.resizeObserver.disconnect()
    if (this.tooltip) this.tooltip.remove()
  },

  draw() {
    const container = this.el
    const width = container.clientWidth || 400
    const height = container.clientHeight || 180

    // Clear previous
    this.svg.selectAll("*").remove()
    this.svg.attr("viewBox", `0 0 ${width} ${height}`)

    if (this.agents.length === 0) {
      this.svg.append("text")
        .attr("x", width / 2)
        .attr("y", height / 2)
        .attr("text-anchor", "middle")
        .attr("fill", "#8b949e")
        .attr("opacity", 0.4)
        .attr("font-size", 12)
        .text("No agents registered")
      return
    }

    // Build nodes and links
    const nodes = this.agents.map(a => ({
      id: a.id,
      name: a.name || a.id,
      tier: a.tier || 1,
      status: a.status || "idle",
      deps: a.deps || [],
      metadata: a.metadata || {}
    }))

    const nodeIds = new Set(nodes.map(n => n.id))
    const links = []

    // Build edges from deps arrays
    nodes.forEach(node => {
      (node.deps || []).forEach(depId => {
        if (nodeIds.has(depId)) {
          links.push({ source: depId, target: node.id })
        }
      })
    })

    // Also use explicit edges if provided
    this.edges.forEach(e => {
      if (nodeIds.has(e.source) && nodeIds.has(e.target)) {
        links.push({ source: e.source, target: e.target })
      }
    })

    // Arrow marker definition
    const defs = this.svg.append("defs")
    defs.append("marker")
      .attr("id", "arrowhead")
      .attr("viewBox", "0 0 10 10")
      .attr("refX", 22)
      .attr("refY", 5)
      .attr("markerWidth", 6)
      .attr("markerHeight", 6)
      .attr("orient", "auto")
      .append("path")
      .attr("d", "M 0 0 L 10 5 L 0 10 z")
      .attr("fill", "#30363d")

    // Glow filter for selected/active nodes
    const filter = defs.append("filter")
      .attr("id", "glow")
      .attr("x", "-50%")
      .attr("y", "-50%")
      .attr("width", "200%")
      .attr("height", "200%")
    filter.append("feGaussianBlur")
      .attr("stdDeviation", "3")
      .attr("result", "coloredBlur")
    const feMerge = filter.append("feMerge")
    feMerge.append("feMergeNode").attr("in", "coloredBlur")
    feMerge.append("feMergeNode").attr("in", "SourceGraphic")

    // Force simulation
    this.simulation = d3.forceSimulation(nodes)
      .force("link", d3.forceLink(links).id(d => d.id).distance(80))
      .force("charge", d3.forceManyBody().strength(-200))
      .force("center", d3.forceCenter(width / 2, height / 2))
      .force("collision", d3.forceCollide().radius(30))
      .force("x", d3.forceX(width / 2).strength(0.05))
      .force("y", d3.forceY(height / 2).strength(0.05))

    // Draw links (edges)
    const link = this.svg.append("g")
      .selectAll("line")
      .data(links)
      .enter().append("line")
      .attr("stroke", "#30363d")
      .attr("stroke-width", 1.5)
      .attr("stroke-opacity", 0.6)
      .attr("marker-end", "url(#arrowhead)")

    // Draw node groups
    const node = this.svg.append("g")
      .selectAll("g")
      .data(nodes)
      .enter().append("g")
      .style("cursor", "grab")
      .call(this.drag(this.simulation))

    // Node circles
    node.append("circle")
      .attr("r", 14)
      .attr("fill", d => STATUS_FILL[d.status] || STATUS_FILL.idle)
      .attr("stroke", d => STATUS_COLORS[d.status] || STATUS_COLORS.idle)
      .attr("stroke-width", 2)

    // Outer ring for status indication
    node.filter(d => d.status === "active")
      .append("circle")
      .attr("r", 18)
      .attr("fill", "none")
      .attr("stroke", STATUS_COLORS.active)
      .attr("stroke-width", 1)
      .attr("stroke-dasharray", "4 3")
      .attr("opacity", 0.5)
      .each(function() {
        d3.select(this)
          .append("animateTransform")
      })

    // Tier indicator inside the circle
    node.append("text")
      .attr("text-anchor", "middle")
      .attr("dy", "0.35em")
      .attr("font-size", 9)
      .attr("font-weight", "bold")
      .attr("fill", d => STATUS_COLORS[d.status] || STATUS_COLORS.idle)
      .text(d => "T" + d.tier)

    // Name labels below nodes
    node.append("text")
      .attr("text-anchor", "middle")
      .attr("dy", 26)
      .attr("font-size", 9)
      .attr("fill", "#c9d1d9")
      .text(d => d.name.length > 14 ? d.name.substring(0, 12) + ".." : d.name)

    // Tooltip on hover
    const tooltip = this.tooltip
    const pushEvent = this.pushEvent.bind(this)

    node.on("mouseover", function(event, d) {
      const deps = (d.deps || []).join(", ") || "none"
      tooltip
        .classed("hidden", false)
        .html(`
          <div class="font-semibold mb-1">${d.name}</div>
          <div><span class="text-base-content/50">ID:</span> ${d.id}</div>
          <div><span class="text-base-content/50">Tier:</span> ${d.tier}</div>
          <div><span class="text-base-content/50">Status:</span> <span style="color:${STATUS_COLORS[d.status] || '#8b949e'}">${d.status}</span></div>
          <div><span class="text-base-content/50">Deps:</span> ${deps}</div>
        `)

      const containerRect = container.getBoundingClientRect()
      tooltip
        .style("left", (event.clientX - containerRect.left + 12) + "px")
        .style("top", (event.clientY - containerRect.top - 10) + "px")

      // Highlight this node
      d3.select(this).select("circle")
        .attr("stroke-width", 3)
        .attr("filter", "url(#glow)")
    })
    .on("mousemove", function(event) {
      const containerRect = container.getBoundingClientRect()
      tooltip
        .style("left", (event.clientX - containerRect.left + 12) + "px")
        .style("top", (event.clientY - containerRect.top - 10) + "px")
    })
    .on("mouseout", function() {
      tooltip.classed("hidden", true)
      d3.select(this).select("circle")
        .attr("stroke-width", 2)
        .attr("filter", null)
    })
    .on("click", function(event, d) {
      pushEvent("select_agent", { agent_id: d.id })
    })

    // Tick function to update positions
    this.simulation.on("tick", () => {
      // Constrain nodes within bounds
      nodes.forEach(d => {
        d.x = Math.max(20, Math.min(width - 20, d.x))
        d.y = Math.max(20, Math.min(height - 20, d.y))
      })

      link
        .attr("x1", d => d.source.x)
        .attr("y1", d => d.source.y)
        .attr("x2", d => d.target.x)
        .attr("y2", d => d.target.y)

      node.attr("transform", d => `translate(${d.x},${d.y})`)
    })
  },

  drag(simulation) {
    function dragstarted(event) {
      if (!event.active) simulation.alphaTarget(0.3).restart()
      event.subject.fx = event.subject.x
      event.subject.fy = event.subject.y
      d3.select(this).style("cursor", "grabbing")
    }

    function dragged(event) {
      event.subject.fx = event.x
      event.subject.fy = event.y
    }

    function dragended(event) {
      if (!event.active) simulation.alphaTarget(0)
      event.subject.fx = null
      event.subject.fy = null
      d3.select(this).style("cursor", "grab")
    }

    return d3.drag()
      .on("start", dragstarted)
      .on("drag", dragged)
      .on("end", dragended)
  }
}

export default DependencyGraph
