/**
 * DependencyGraph LiveView JS Hook
 *
 * Force-directed graph with adaptive layout, tier lanes, namespace hulls,
 * agent type rendering, and zoom/pan support.
 */
import * as d3 from "../../vendor/d3.min.js"

const STATUS_COLORS = {
  active:     "#3fb950",
  idle:       "#8b949e",
  error:      "#f85149",
  discovered: "#58a6ff",
  completed:  "#d2a8ff",
  running:    "#3fb950",
  complete:   "#d2a8ff",
  standby:    "#f0883e"
}

const STATUS_FILL = {
  active:     "#3fb95033",
  idle:       "#8b949e22",
  error:      "#f8514933",
  discovered: "#58a6ff33",
  completed:  "#d2a8ff22",
  running:    "#3fb95033",
  complete:   "#d2a8ff22",
  standby:    "#f0883e22"
}

const AGENT_TYPE_CONFIG = {
  squadron:    { sizeMultiplier: 1.8, strokeDash: "6 3" },
  swarm:       { sizeMultiplier: 2.2, strokeDash: "3 2" },
  orchestrator:{ sizeMultiplier: 1.5, strokeDash: null },
  individual:  { sizeMultiplier: 1.0, strokeDash: null }
}

const UUID_RE = /^[0-9a-f]{7,8}$/i

function classify(agent) {
  const name = (agent.name || "").toLowerCase()
  const meta = agent.metadata || {}
  const type = (meta.type || "").toLowerCase()
  const at = (agent.agentType || "individual").toLowerCase()

  if (at === "squadron") return { label: "squadron", tag: "SQ" }
  if (at === "swarm")    return { label: "swarm",    tag: "SW" }
  if (type === "orchestrator" || at === "orchestrator") return { label: "orchestrator", tag: "ORC" }
  if (type === "session")                           return { label: "session",  tag: "SESS" }
  if (type === "tool-runner" || type === "tool_runner") return { label: "tool",  tag: "TOOL" }
  if (name.includes("explore") || name.includes("search")) return { label: "explore", tag: "EXPL" }
  if (name.includes("fix") || name.includes("repair"))     return { label: "fix",     tag: "FIX" }
  if (name.includes("test") || name.includes("spec"))      return { label: "test",    tag: "TEST" }
  if (name.includes("build") || name.includes("compile"))  return { label: "build",   tag: "BILD" }
  if (name.includes("monitor") || name.includes("watch"))  return { label: "watch",   tag: "WTCH" }
  if (name.includes("plan") || name.includes("analyze"))   return { label: "plan",    tag: "PLAN" }
  if (UUID_RE.test(name) || name === "unknown" || name === "") return { label: "agent", tag: "ANON" }

  const parts = name.split(":")
  return { label: name, tag: parts[parts.length - 1].substring(0, 4).toUpperCase() }
}

function isAnon(agent) {
  const name = agent.name || agent.id || ""
  return UUID_RE.test(name) || name === "unknown" || name === ""
}

const HULL_COLORS = ["#1f6feb", "#8957e5", "#f0883e", "#3fb950", "#f85149", "#58a6ff", "#d2a8ff"]

const DependencyGraph = {
  mounted() {
    this.svg = d3.select(this.el).append("svg")
      .attr("width", "100%")
      .attr("height", "100%")
      .attr("role", "img")
      .attr("aria-labelledby", "dep-graph-title dep-graph-desc")

    this.tooltip = d3.select(this.el).append("div")
      .attr("class", "absolute hidden bg-base-100 border border-base-300 rounded-lg shadow-xl p-3 text-xs z-50 pointer-events-none max-w-[260px]")
      .style("position", "absolute")

    this.simulation = null
    this.agents = []
    this.edges = []
    this.showAnon = false  // hide ANON by default

    this.handleEvent("agents_updated", (data) => {
      this.agents = data.agents || []
      this.edges = data.edges || []
      this.draw()
    })

    // Listen for filter toggle from LiveView
    this.handleEvent("graph_toggle_anon", () => {
      this.showAnon = !this.showAnon
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
    const width  = container.clientWidth  || 600
    const height = container.clientHeight || 400

    this.svg.selectAll("*").remove()
    this.svg.attr("viewBox", `0 0 ${width} ${height}`)

    // Accessible title and description
    const statusCounts = {}
    this.agents.forEach(a => {
      const s = a.status || "idle"
      statusCounts[s] = (statusCounts[s] || 0) + 1
    })
    const summaryParts = Object.entries(statusCounts).map(([s, c]) => `${c} ${s}`)
    const summaryText = summaryParts.length > 0
      ? `${this.agents.length} agents: ${summaryParts.join(", ")}`
      : "No agents registered"

    this.svg.append("title").attr("id", "dep-graph-title").text("Agent Dependency Graph")
    this.svg.append("desc").attr("id", "dep-graph-desc").text(summaryText)

    if (this.agents.length === 0) {
      this.svg.append("text")
        .attr("x", width / 2).attr("y", height / 2)
        .attr("text-anchor", "middle")
        .attr("fill", "#8b949e").attr("opacity", 0.4).attr("font-size", 13)
        .text("No agents registered")
      return
    }

    // Build nodes, optionally filtering ANON
    let allAgents = this.agents.map(a => {
      const meta = a.metadata || {}
      return {
        id:          a.id,
        name:        a.name || a.id,
        tier:        a.tier ?? 1,
        status:      a.status || "idle",
        deps:        a.deps || [],
        metadata:    meta,
        project:     meta.project || meta["project"] || a.project_name || null,
        namespace:   a.namespace  || meta.namespace   || null,
        agentType:   a.agent_type || meta.agent_type  || "individual",
        memberCount: a.member_count || meta.member_count || null,
        path:        a.path || meta.path || null,
        startTime:   meta.start_time || meta["start_time"] || null,
      }
    })

    const totalCount = allAgents.length
    const anonCount = allAgents.filter(isAnon).length

    // Filter ANON unless toggled on
    const nodes = this.showAnon ? allAgents : allAgents.filter(n => !isAnon(n))

    if (nodes.length === 0) {
      this.svg.append("text")
        .attr("x", width / 2).attr("y", height / 2)
        .attr("text-anchor", "middle")
        .attr("fill", "#8b949e").attr("opacity", 0.4).attr("font-size", 13)
        .text(`${anonCount} unnamed agents hidden`)
      return
    }

    // Adaptive layout params based on node count and canvas size
    const n = nodes.length
    const density = n / (width * height / 10000) // nodes per 100x100 area
    const baseRadius = n > 40 ? 10 : n > 20 ? 12 : 14
    const chargeStrength = Math.min(-120, -60 * Math.sqrt(n))   // scales with node count
    const linkDistance = Math.max(50, Math.min(120, width / (n * 0.3)))
    const collisionPad = n > 40 ? 3 : 6

    // Compute degree map
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

    const nodeRadius = nd => {
      const conf = AGENT_TYPE_CONFIG[nd.agentType] || AGENT_TYPE_CONFIG.individual
      const base = baseRadius + Math.min(degree[nd.id] || 0, 5) * 1.5
      return base * conf.sizeMultiplier
    }

    // Compute tier positions adaptively -- spread across full canvas height
    const tierSet = [...new Set(nodes.map(n => n.tier))].sort()
    const tierCount = tierSet.length
    const tierYMap = {}
    const margin = 0.12  // 12% padding top/bottom
    tierSet.forEach((t, i) => {
      if (tierCount === 1) {
        tierYMap[t] = 0.5
      } else {
        tierYMap[t] = margin + (1 - 2 * margin) * (i / (tierCount - 1))
      }
    })
    const getTierY = (tier) => (tierYMap[tier] ?? 0.5) * height

    // Tier force strength -- weaker with more agents so they can spread
    const tierStrength = n > 30 ? 0.12 : n > 15 ? 0.18 : 0.25

    // Namespace groups
    const groupMap = {}
    nodes.forEach(nd => {
      const key = nd.namespace || nd.project
      if (key) {
        if (!groupMap[key]) groupMap[key] = { nodes: [], isNamespace: !!nd.namespace }
        groupMap[key].nodes.push(nd)
      }
    })
    const groupKeys = Object.keys(groupMap)

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

    // Zoom container
    const zoomG = this.svg.append("g")
    const zoom = d3.zoom()
      .scaleExtent([0.3, 4])
      .on("zoom", (event) => { zoomG.attr("transform", event.transform) })
    this.svg.call(zoom)

    // Hull layer
    const hullLayer = zoomG.append("g").attr("class", "hull-layer")

    // Tier lane dividers
    if (tierCount > 1) {
      const laneG = zoomG.append("g")
      for (let i = 0; i < tierSet.length - 1; i++) {
        const y = (getTierY(tierSet[i]) + getTierY(tierSet[i + 1])) / 2
        laneG.append("line")
          .attr("x1", 0).attr("x2", width).attr("y1", y).attr("y2", y)
          .attr("stroke", "#30363d").attr("stroke-width", 0.5)
          .attr("stroke-dasharray", "4 6").attr("opacity", 0.25)
      }
      tierSet.forEach(t => {
        laneG.append("text")
          .attr("x", 6).attr("y", getTierY(t) - 6)
          .attr("font-size", 9).attr("fill", "#8b949e").attr("opacity", 0.35)
          .text("T" + t)
      })
    }

    // Force simulation -- adaptive params
    this.simulation = d3.forceSimulation(nodes)
      .force("link",      d3.forceLink(allLinks).id(d => d.id).distance(linkDistance).strength(0.3))
      .force("charge",    d3.forceManyBody().strength(chargeStrength))
      .force("collision", d3.forceCollide().radius(d => nodeRadius(d) + collisionPad))
      .force("x",         d3.forceX(width / 2).strength(0.03))
      .force("tierY",     d3.forceY(d => getTierY(d.tier)).strength(tierStrength))

    // Links
    const link = zoomG.append("g")
      .selectAll("line").data(allLinks).enter().append("line")
      .attr("stroke", "#30363d").attr("stroke-width", 1.5)
      .attr("stroke-opacity", 0.45).attr("marker-end", "url(#arrowhead)")

    // Nodes
    const node = zoomG.append("g")
      .selectAll("g").data(nodes).enter().append("g")
      .attr("class", "graph-node")
      .attr("tabindex", "0")
      .attr("role", "button")
      .attr("aria-label", d => `Agent ${d.name || d.id}, status ${d.status}`)
      .style("cursor", "grab")
      .call(this.drag(this.simulation))

    // Main circle
    node.append("circle")
      .attr("r", d => nodeRadius(d))
      .attr("fill",   d => STATUS_FILL[d.status]   || STATUS_FILL.idle)
      .attr("stroke", d => STATUS_COLORS[d.status] || STATUS_COLORS.idle)
      .attr("stroke-width", d => d.agentType !== "individual" ? 3 : 2)
      .attr("stroke-dasharray", d => {
        const conf = AGENT_TYPE_CONFIG[d.agentType]
        return conf ? conf.strokeDash : null
      })

    // Outer ring for squadrons/swarms
    node.filter(d => d.agentType === "squadron" || d.agentType === "swarm")
      .append("circle")
      .attr("r", d => nodeRadius(d) + 5)
      .attr("fill", "none")
      .attr("stroke", d => STATUS_COLORS[d.status] || STATUS_COLORS.idle)
      .attr("stroke-width", 1)
      .attr("stroke-dasharray", d => d.agentType === "swarm" ? "2 2" : "4 3")
      .attr("opacity", 0.5)

    // Member count badge
    node.filter(d => d.memberCount && d.memberCount > 1)
      .append("circle")
      .attr("cx", d => nodeRadius(d) * 0.7)
      .attr("cy", d => -nodeRadius(d) * 0.7)
      .attr("r", 8).attr("fill", "#1f6feb").attr("stroke", "#0d1117").attr("stroke-width", 1.5)

    node.filter(d => d.memberCount && d.memberCount > 1)
      .append("text")
      .attr("x", d => nodeRadius(d) * 0.7)
      .attr("y", d => -nodeRadius(d) * 0.7)
      .attr("text-anchor", "middle").attr("dy", "0.35em")
      .attr("font-size", 7).attr("font-weight", "bold").attr("fill", "#fff")
      .text(d => d.memberCount)

    // Animated ring for active
    node.filter(d => d.status === "active" || d.status === "running")
      .append("circle")
      .attr("r", d => nodeRadius(d) + 4)
      .attr("fill", "none")
      .attr("stroke", STATUS_COLORS.active)
      .attr("stroke-width", 1).attr("stroke-dasharray", "4 3").attr("opacity", 0.5)

    // Checkmark for completed
    node.filter(d => d.status === "completed" || d.status === "complete")
      .append("text")
      .attr("text-anchor", "middle").attr("dy", "0.35em")
      .attr("font-size", d => d.agentType !== "individual" ? 14 : 10)
      .attr("fill", STATUS_COLORS.completed)
      .text("\u2713")

    // Classification tag for non-completed
    node.filter(d => d.status !== "completed" && d.status !== "complete")
      .append("text")
      .attr("text-anchor", "middle").attr("dy", "0.35em")
      .attr("font-size", d => d.agentType !== "individual" ? 10 : 8)
      .attr("font-weight", "bold")
      .attr("fill", d => STATUS_COLORS[d.status] || STATUS_COLORS.idle)
      .text(d => classify(d).tag)

    // Name label
    node.append("text")
      .attr("text-anchor", "middle")
      .attr("dy", d => nodeRadius(d) + 11)
      .attr("font-size", 8).attr("fill", "#c9d1d9")
      .text(d => {
        const parts = (d.name || d.id).split(":")
        const seg = parts[parts.length - 1]
        return seg.length > 16 ? seg.substring(0, 14) + ".." : seg
      })

    // Namespace label (below name)
    node.filter(d => d.namespace)
      .append("text")
      .attr("text-anchor", "middle")
      .attr("dy", d => nodeRadius(d) + 21)
      .attr("font-size", 6).attr("fill", "#8b949e").attr("opacity", 0.6)
      .text(d => d.namespace.length > 14 ? d.namespace.substring(0, 12) + ".." : d.namespace)

    // Tooltip
    const tooltip = this.tooltip
    const pushEvent = this.pushEvent.bind(this)

    node
      .on("mouseover", function(event, d) {
        const cl = classify(d)
        const depsStr = d.deps.length > 0
          ? d.deps.slice(0, 3).join(", ") + (d.deps.length > 3 ? ` +${d.deps.length - 3}` : "")
          : "none"
        tooltip.classed("hidden", false).html(`
          <div class="font-semibold mb-1 truncate">${d.name}${d.memberCount ? ` (${d.memberCount})` : ""}</div>
          <div class="space-y-0.5 text-base-content/60">
            <div><span class="text-base-content/40">ID:</span> <span class="font-mono">${d.id.substring(0, 12)}</span></div>
            <div><span class="text-base-content/40">Tier:</span> T${d.tier} <span class="text-base-content/40 ml-2">Type:</span> ${cl.label} (${d.agentType})</div>
            <div><span class="text-base-content/40">Status:</span> <span style="color:${STATUS_COLORS[d.status] || '#8b949e'}">${d.status}</span></div>
            ${d.namespace ? `<div><span class="text-base-content/40">NS:</span> ${d.namespace}</div>` : ""}
            ${d.project ? `<div><span class="text-base-content/40">Project:</span> ${d.project}</div>` : ""}
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
          .attr("stroke-width", d => d.agentType !== "individual" ? 3 : 2)
          .attr("filter", null)
      })
      .on("click", function(event, d) {
        pushEvent("select_agent", { agent_id: d.id })
      })

    // Keyboard navigation for nodes
    node.on("keydown", function(event, d) {
      if (event.key === "Enter" || event.key === " ") {
        event.preventDefault()
        pushEvent("select_agent", { agent_id: d.id })
      }
      // Arrow key navigation between nodes
      const allNodes = node.nodes()
      const currentIndex = allNodes.indexOf(this)
      let targetIndex = -1
      if (event.key === "ArrowRight" || event.key === "ArrowDown") {
        event.preventDefault()
        targetIndex = (currentIndex + 1) % allNodes.length
      } else if (event.key === "ArrowLeft" || event.key === "ArrowUp") {
        event.preventDefault()
        targetIndex = (currentIndex - 1 + allNodes.length) % allNodes.length
      }
      if (targetIndex >= 0) {
        allNodes[targetIndex].focus()
      }
    })

    // Mark decorative SVG elements
    this.svg.selectAll("defs").attr("aria-hidden", "true").attr("focusable", "false")

    // ANON count indicator (bottom-right of canvas, outside zoom)
    if (anonCount > 0 && !this.showAnon) {
      this.svg.append("text")
        .attr("x", width - 8).attr("y", height - 8)
        .attr("text-anchor", "end")
        .attr("font-size", 10).attr("fill", "#8b949e").attr("opacity", 0.5)
        .attr("cursor", "pointer")
        .text(`+${anonCount} unnamed hidden`)
        .on("click", () => {
          this.showAnon = true
          this.draw()
          pushEvent("graph_anon_toggled", { show: true })
        })
    }

    // Tick
    this.simulation.on("tick", () => {
      const pad = 20
      nodes.forEach(d => {
        const r = nodeRadius(d)
        d.x = Math.max(r + pad, Math.min(width  - r - pad, d.x))
        d.y = Math.max(r + pad, Math.min(height - r - pad, d.y))
      })

      // Convex hulls
      if (groupKeys.length > 0) {
        hullLayer.selectAll("*").remove()
        groupKeys.forEach((key, i) => {
          const group = groupMap[key]
          const members = group.nodes.filter(nd => nd.x !== undefined)
          if (members.length < 2) return
          const hullPad = group.isNamespace ? 22 : 16
          const pts = members.flatMap(nd => [
            [nd.x - hullPad, nd.y - hullPad], [nd.x + hullPad, nd.y - hullPad],
            [nd.x - hullPad, nd.y + hullPad], [nd.x + hullPad, nd.y + hullPad]
          ])
          const hull = d3.polygonHull(pts)
          if (!hull) return
          const color = HULL_COLORS[i % HULL_COLORS.length]
          const fillOp = group.isNamespace ? "28" : "14"
          const strokeOp = group.isNamespace ? "77" : "44"
          hullLayer.append("path")
            .attr("d", "M" + hull.map(p => p.join(",")).join("L") + "Z")
            .attr("fill", color + fillOp)
            .attr("stroke", color + strokeOp)
            .attr("stroke-width", group.isNamespace ? 1.5 : 1)
            .attr("stroke-dasharray", group.isNamespace ? null : "5 3")
            .attr("rx", 8)

          if (group.isNamespace) {
            const cx = d3.mean(members, nd => nd.x)
            const minY = d3.min(members, nd => nd.y) - hullPad - 8
            hullLayer.append("text")
              .attr("x", cx).attr("y", minY)
              .attr("text-anchor", "middle")
              .attr("font-size", 10).attr("font-weight", "600")
              .attr("fill", color).attr("opacity", 0.65)
              .text(key)
          }
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
