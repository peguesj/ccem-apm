/**
 * DependencyGraph LiveView JS Hook
 *
 * Renders a D3.js force-directed graph of agents with:
 *   - Tier-lane hierarchy: T0 top, T1 middle, T2+ bottom (forceY by tier)
 *   - Agent classification: unnamed agents typed by UUID/metadata heuristics
 *   - Degree-scaled nodes: r = 12 + min(degree, 5) * 2
 *   - Project group outlines: convex hull per project
 *   - Richer tooltips: type, project, start_time, deps
 *   - Completed nodes: ✓ badge
 */
import * as d3 from "../../vendor/d3.min.js"

const STATUS_COLORS = {
  active:     "#3fb950",
  idle:       "#8b949e",
  error:      "#f85149",
  discovered: "#58a6ff",
  completed:  "#d2a8ff"
}

const STATUS_FILL = {
  active:     "#3fb95033",
  idle:       "#8b949e22",
  error:      "#f8514933",
  discovered: "#58a6ff33",
  completed:  "#d2a8ff22"
}

// UUID-like short ID pattern
const UUID_SHORT_RE = /^[0-9a-f]{7,8}$/i

function classify(agent) {
  const name = (agent.name || "").toLowerCase()
  const meta = agent.metadata || {}
  const type = (meta.type || meta["type"] || "").toLowerCase()

  if (type === "session")                           return { label: "session", tag: "SESS" }
  if (type === "tool-runner" || type === "tool_runner") return { label: "tool",    tag: "TOOL" }
  if (name.includes("explore") || name.includes("search")) return { label: "explore", tag: "EXPL" }
  if (name.includes("fix") || name.includes("repair"))     return { label: "fix",     tag: "FIX" }
  if (name.includes("test") || name.includes("spec"))      return { label: "test",    tag: "TEST" }
  if (name.includes("build") || name.includes("compile"))  return { label: "build",   tag: "BILD" }
  if (name.includes("monitor") || name.includes("watch"))  return { label: "watch",   tag: "WTCH" }
  if (name.includes("plan") || name.includes("analyze"))   return { label: "plan",    tag: "PLAN" }
  if (UUID_SHORT_RE.test(name) || name === "unknown" || name === "") return { label: "agent", tag: "ANON" }

  const parts = name.split(":")
  const short = parts[parts.length - 1].substring(0, 4).toUpperCase()
  return { label: name, tag: short }
}

// Tier-lane Y anchors as fraction of height
const TIER_Y = { 0: 0.13, 1: 0.38, 2: 0.63, 3: 0.83 }
function tierY(tier, height) {
  return (TIER_Y[tier] ?? 0.75) * height
}

// Project group hull colors
const HULL_COLORS = ["#1f6feb", "#8957e5", "#f0883e", "#3fb950", "#f85149"]

const DependencyGraph = {
  mounted() {
    this.svg = d3.select(this.el).append("svg")
      .attr("width", "100%")
      .attr("height", "100%")

    this.tooltip = d3.select(this.el).append("div")
      .attr("class", "absolute hidden bg-base-100 border border-base-300 rounded-lg shadow-xl p-3 text-xs z-50 pointer-events-none max-w-[220px]")
      .style("position", "absolute")

    this.simulation = null
    this.agents = []
    this.edges = []

    this.handleEvent("agents_updated", (data) => {
      this.agents = data.agents || []
      this.edges = data.edges || []
      this.draw()
    })

    this.draw()

    this.resizeObserver = new ResizeObserver(() => this.draw())
    this.resizeObserver.observe(this.el)
  },

  updated() {},

  destroyed() {
    if (this.simulation) this.simulation.stop()
    if (this.resizeObserver) this.resizeObserver.disconnect()
    if (this.tooltip) this.tooltip.remove()
  },

  draw() {
    const container = this.el
    const width  = container.clientWidth  || 400
    const height = container.clientHeight || 220

    this.svg.selectAll("*").remove()
    this.svg.attr("viewBox", `0 0 ${width} ${height}`)

    if (this.agents.length === 0) {
      this.svg.append("text")
        .attr("x", width / 2).attr("y", height / 2)
        .attr("text-anchor", "middle")
        .attr("fill", "#8b949e").attr("opacity", 0.4).attr("font-size", 12)
        .text("No agents registered")
      return
    }

    // Build nodes with enriched metadata
    const nodes = this.agents.map(a => {
      const meta = a.metadata || {}
      return {
        id:        a.id,
        name:      a.name || a.id,
        tier:      a.tier ?? 1,
        status:    a.status || "idle",
        deps:      a.deps || [],
        metadata:  meta,
        project:   meta.project   || meta["project"]    || null,
        startTime: meta.start_time || meta["start_time"] || null,
        agType:    meta.type       || meta["type"]       || null
      }
    })

    // Compute degree map for node sizing
    const degree = {}
    nodes.forEach(n => { degree[n.id] = 0 })

    const nodeIds = new Set(nodes.map(n => n.id))
    const allLinks = []

    nodes.forEach(n => {
      (n.deps || []).forEach(depId => {
        if (nodeIds.has(depId)) {
          allLinks.push({ source: depId, target: n.id })
          degree[depId] = (degree[depId] || 0) + 1
          degree[n.id]  = (degree[n.id]  || 0) + 1
        }
      })
    })
    this.edges.forEach(e => {
      if (nodeIds.has(e.source) && nodeIds.has(e.target)) {
        allLinks.push({ source: e.source, target: e.target })
        degree[e.source] = (degree[e.source] || 0) + 1
        degree[e.target] = (degree[e.target] || 0) + 1
      }
    })

    const nodeRadius = n => 12 + Math.min(degree[n.id] || 0, 5) * 2

    // Project groups for convex hull outlines
    const projectMap = {}
    nodes.forEach(n => {
      if (n.project) {
        if (!projectMap[n.project]) projectMap[n.project] = []
        projectMap[n.project].push(n)
      }
    })
    const projectKeys = Object.keys(projectMap)

    // SVG defs
    const defs = this.svg.append("defs")
    defs.append("marker")
      .attr("id", "arrowhead")
      .attr("viewBox", "0 0 10 10").attr("refX", 24).attr("refY", 5)
      .attr("markerWidth", 5).attr("markerHeight", 5).attr("orient", "auto")
      .append("path").attr("d", "M 0 0 L 10 5 L 0 10 z").attr("fill", "#30363d")

    const glow = defs.append("filter").attr("id", "glow")
      .attr("x", "-50%").attr("y", "-50%").attr("width", "200%").attr("height", "200%")
    glow.append("feGaussianBlur").attr("stdDeviation", "3").attr("result", "coloredBlur")
    const feMerge = glow.append("feMerge")
    feMerge.append("feMergeNode").attr("in", "coloredBlur")
    feMerge.append("feMergeNode").attr("in", "SourceGraphic")

    // Group hull layer (behind everything)
    const hullLayer = this.svg.append("g").attr("class", "hull-layer")

    // Tier lane dividers
    const tierSet = [...new Set(nodes.map(n => n.tier))].sort()
    if (tierSet.length > 1) {
      const laneG = this.svg.append("g")
      for (let i = 0; i < tierSet.length - 1; i++) {
        const y = (tierY(tierSet[i], height) + tierY(tierSet[i + 1], height)) / 2
        laneG.append("line")
          .attr("x1", 0).attr("x2", width).attr("y1", y).attr("y2", y)
          .attr("stroke", "#30363d").attr("stroke-width", 0.5)
          .attr("stroke-dasharray", "4 6").attr("opacity", 0.3)
      }
      tierSet.forEach(t => {
        laneG.append("text")
          .attr("x", 4).attr("y", tierY(t, height) - 4)
          .attr("font-size", 8).attr("fill", "#8b949e").attr("opacity", 0.4)
          .text("T" + t)
      })
    }

    // Force simulation with tier Y anchoring
    this.simulation = d3.forceSimulation(nodes)
      .force("link",      d3.forceLink(allLinks).id(d => d.id).distance(75).strength(0.4))
      .force("charge",    d3.forceManyBody().strength(-180))
      .force("collision", d3.forceCollide().radius(d => nodeRadius(d) + 5))
      .force("x",         d3.forceX(width / 2).strength(0.04))
      .force("tierY",     d3.forceY(d => tierY(d.tier, height)).strength(0.35))

    // Links
    const link = this.svg.append("g")
      .selectAll("line").data(allLinks).enter().append("line")
      .attr("stroke", "#30363d").attr("stroke-width", 1.5)
      .attr("stroke-opacity", 0.55).attr("marker-end", "url(#arrowhead)")

    // Nodes
    const node = this.svg.append("g")
      .selectAll("g").data(nodes).enter().append("g")
      .style("cursor", "grab")
      .call(this.drag(this.simulation))

    // Main circle
    node.append("circle")
      .attr("r", d => nodeRadius(d))
      .attr("fill",   d => STATUS_FILL[d.status]   || STATUS_FILL.idle)
      .attr("stroke", d => STATUS_COLORS[d.status] || STATUS_COLORS.idle)
      .attr("stroke-width", 2)

    // Animated ring for active nodes
    node.filter(d => d.status === "active")
      .append("circle")
      .attr("r", d => nodeRadius(d) + 4)
      .attr("fill", "none")
      .attr("stroke", STATUS_COLORS.active)
      .attr("stroke-width", 1).attr("stroke-dasharray", "4 3").attr("opacity", 0.5)

    // ✓ for completed
    node.filter(d => d.status === "completed")
      .append("text")
      .attr("text-anchor", "middle").attr("dy", "0.35em")
      .attr("font-size", 10).attr("fill", STATUS_COLORS.completed)
      .text("✓")

    // Classification tag for non-completed
    node.filter(d => d.status !== "completed")
      .append("text")
      .attr("text-anchor", "middle").attr("dy", "0.35em")
      .attr("font-size", 8).attr("font-weight", "bold")
      .attr("fill", d => STATUS_COLORS[d.status] || STATUS_COLORS.idle)
      .text(d => classify(d).tag)

    // Name label below
    node.append("text")
      .attr("text-anchor", "middle")
      .attr("dy", d => nodeRadius(d) + 11)
      .attr("font-size", 8).attr("fill", "#c9d1d9")
      .text(d => {
        const parts = (d.name || d.id).split(":")
        const seg = parts[parts.length - 1]
        return seg.length > 12 ? seg.substring(0, 10) + ".." : seg
      })

    // Tooltip
    const tooltip   = this.tooltip
    const pushEvent = this.pushEvent.bind(this)

    node
      .on("mouseover", function(event, d) {
        const cl = classify(d)
        const depsStr = d.deps.length > 0
          ? d.deps.slice(0, 3).join(", ") + (d.deps.length > 3 ? ` +${d.deps.length - 3}` : "")
          : "none"
        const proj  = d.project   || "—"
        const start = d.startTime ? d.startTime.substring(0, 16).replace("T", " ") : "—"

        tooltip.classed("hidden", false).html(`
          <div class="font-semibold mb-1 truncate">${d.name}</div>
          <div class="space-y-0.5 text-base-content/60">
            <div><span class="text-base-content/40">ID:</span> <span class="font-mono">${d.id.substring(0, 12)}</span></div>
            <div><span class="text-base-content/40">Tier:</span> T${d.tier}</div>
            <div><span class="text-base-content/40">Status:</span> <span style="color:${STATUS_COLORS[d.status] || '#8b949e'}">${d.status}</span></div>
            <div><span class="text-base-content/40">Type:</span> ${cl.label}</div>
            <div><span class="text-base-content/40">Project:</span> ${proj}</div>
            <div><span class="text-base-content/40">Started:</span> ${start}</div>
            <div><span class="text-base-content/40">Deps:</span> ${depsStr}</div>
          </div>
        `)

        const rect = container.getBoundingClientRect()
        tooltip
          .style("left", (event.clientX - rect.left + 14) + "px")
          .style("top",  (event.clientY - rect.top  - 12) + "px")

        d3.select(this).select("circle")
          .attr("stroke-width", 3).attr("filter", "url(#glow)")
      })
      .on("mousemove", function(event) {
        const rect = container.getBoundingClientRect()
        tooltip
          .style("left", (event.clientX - rect.left + 14) + "px")
          .style("top",  (event.clientY - rect.top  - 12) + "px")
      })
      .on("mouseout", function() {
        tooltip.classed("hidden", true)
        d3.select(this).select("circle")
          .attr("stroke-width", 2).attr("filter", null)
      })
      .on("click", function(event, d) {
        pushEvent("select_agent", { agent_id: d.id })
      })

    // Tick
    this.simulation.on("tick", () => {
      nodes.forEach(d => {
        const r = nodeRadius(d)
        d.x = Math.max(r + 2, Math.min(width  - r - 2, d.x))
        d.y = Math.max(r + 2, Math.min(height - r - 16, d.y))
      })

      // Convex hull group indicators
      if (projectKeys.length > 1) {
        hullLayer.selectAll("*").remove()
        projectKeys.forEach((proj, i) => {
          const members = projectMap[proj].filter(n => n.x !== undefined)
          if (members.length < 2) return
          const pad = 14
          const pts = members.flatMap(n => [
            [n.x - pad, n.y - pad], [n.x + pad, n.y - pad],
            [n.x - pad, n.y + pad], [n.x + pad, n.y + pad]
          ])
          const hull = d3.polygonHull(pts)
          if (!hull) return
          const color = HULL_COLORS[i % HULL_COLORS.length]
          hullLayer.append("path")
            .attr("d", "M" + hull.map(p => p.join(",")).join("L") + "Z")
            .attr("fill", color + "22")
            .attr("stroke", color + "66")
            .attr("stroke-width", 1).attr("stroke-dasharray", "5 3")
        })
      }

      link
        .attr("x1", d => d.source.x).attr("y1", d => d.source.y)
        .attr("x2", d => d.target.x).attr("y2", d => d.target.y)

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
      .on("drag",  dragged)
      .on("end",   dragended)
  }
}

export default DependencyGraph
