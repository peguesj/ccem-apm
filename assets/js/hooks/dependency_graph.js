/**
 * DependencyGraph LiveView JS Hook
 *
 * Renders a D3.js force-directed graph of agents with:
 *   - Tier-lane hierarchy: T0 top, T1 middle, T2+ bottom (forceY by tier)
 *   - Agent classification: unnamed agents typed by UUID/metadata heuristics
 *   - Degree-scaled nodes: r = 12 + min(degree, 5) * 2
 *   - Namespace group outlines: convex hull per namespace (or project fallback)
 *   - Squadron/swarm nodes: larger, distinct rendering with member count badge
 *   - Richer tooltips: type, project, namespace, agent_type, start_time, deps
 *   - Completed nodes: check badge
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

// Agent type visual config
const AGENT_TYPE_CONFIG = {
  squadron:    { sizeMultiplier: 1.8, strokeDash: "6 3", icon: "SQ" },
  swarm:       { sizeMultiplier: 2.2, strokeDash: "3 2", icon: "SW" },
  orchestrator:{ sizeMultiplier: 1.5, strokeDash: null,   icon: "ORC" },
  individual:  { sizeMultiplier: 1.0, strokeDash: null,   icon: null }
}

const UUID_SHORT_RE = /^[0-9a-f]{7,8}$/i

function classify(agent) {
  const name = (agent.name || "").toLowerCase()
  const meta = agent.metadata || {}
  const type = (meta.type || "").toLowerCase()
  const agentType = (agent.agentType || "individual").toLowerCase()

  // Squadron/swarm gets special classification
  if (agentType === "squadron") return { label: "squadron", tag: "SQ" }
  if (agentType === "swarm")    return { label: "swarm",    tag: "SW" }

  if (type === "orchestrator" || agentType === "orchestrator") return { label: "orchestrator", tag: "ORC" }
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

const TIER_Y = { 0: 0.13, 1: 0.38, 2: 0.63, 3: 0.83 }
function tierY(tier, height) {
  return (TIER_Y[tier] ?? 0.75) * height
}

// Namespace/project hull colors
const HULL_COLORS = ["#1f6feb", "#8957e5", "#f0883e", "#3fb950", "#f85149", "#58a6ff", "#d2a8ff"]

const DependencyGraph = {
  mounted() {
    this.svg = d3.select(this.el).append("svg")
      .attr("width", "100%")
      .attr("height", "100%")

    this.tooltip = d3.select(this.el).append("div")
      .attr("class", "absolute hidden bg-base-100 border border-base-300 rounded-lg shadow-xl p-3 text-xs z-50 pointer-events-none max-w-[260px]")
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
        id:          a.id,
        name:        a.name || a.id,
        tier:        a.tier ?? 1,
        status:      a.status || "idle",
        deps:        a.deps || [],
        metadata:    meta,
        project:     meta.project    || meta["project"]     || a.project_name || null,
        namespace:   a.namespace     || meta.namespace       || null,
        agentType:   a.agent_type    || meta.agent_type      || "individual",
        memberCount: a.member_count  || meta.member_count    || null,
        path:        a.path          || meta.path            || null,
        startTime:   meta.start_time || meta["start_time"]   || null,
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

    // Node radius: base + degree bonus, scaled by agent type
    const nodeRadius = n => {
      const typeConf = AGENT_TYPE_CONFIG[n.agentType] || AGENT_TYPE_CONFIG.individual
      const base = 12 + Math.min(degree[n.id] || 0, 5) * 2
      return base * typeConf.sizeMultiplier
    }

    // Namespace groups (prefer namespace, fall back to project)
    const groupMap = {}
    nodes.forEach(n => {
      const groupKey = n.namespace || n.project
      if (groupKey) {
        if (!groupMap[groupKey]) groupMap[groupKey] = { nodes: [], isNamespace: !!n.namespace }
        groupMap[groupKey].nodes.push(n)
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

    // Main circle -- squadrons/swarms get double ring
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

    // Member count badge for squadrons/swarms (top-right)
    node.filter(d => d.memberCount && d.memberCount > 1)
      .append("circle")
      .attr("cx", d => nodeRadius(d) * 0.7)
      .attr("cy", d => -nodeRadius(d) * 0.7)
      .attr("r", 8)
      .attr("fill", "#1f6feb")
      .attr("stroke", "#0d1117")
      .attr("stroke-width", 1.5)

    node.filter(d => d.memberCount && d.memberCount > 1)
      .append("text")
      .attr("x", d => nodeRadius(d) * 0.7)
      .attr("y", d => -nodeRadius(d) * 0.7)
      .attr("text-anchor", "middle").attr("dy", "0.35em")
      .attr("font-size", 7).attr("font-weight", "bold").attr("fill", "#fff")
      .text(d => d.memberCount)

    // Animated ring for active nodes
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

    // Name label below
    node.append("text")
      .attr("text-anchor", "middle")
      .attr("dy", d => nodeRadius(d) + 11)
      .attr("font-size", 8).attr("fill", "#c9d1d9")
      .text(d => {
        const parts = (d.name || d.id).split(":")
        const seg = parts[parts.length - 1]
        return seg.length > 14 ? seg.substring(0, 12) + ".." : seg
      })

    // Namespace label (smaller, above name, only for namespaced agents)
    node.filter(d => d.namespace)
      .append("text")
      .attr("text-anchor", "middle")
      .attr("dy", d => nodeRadius(d) + 21)
      .attr("font-size", 6).attr("fill", "#8b949e").attr("opacity", 0.6)
      .text(d => d.namespace.length > 12 ? d.namespace.substring(0, 10) + ".." : d.namespace)

    // Tooltip
    const tooltip   = this.tooltip
    const pushEvent = this.pushEvent.bind(this)

    node
      .on("mouseover", function(event, d) {
        const cl = classify(d)
        const depsStr = d.deps.length > 0
          ? d.deps.slice(0, 3).join(", ") + (d.deps.length > 3 ? ` +${d.deps.length - 3}` : "")
          : "none"
        const proj  = d.project   || "\u2014"
        const ns    = d.namespace || "\u2014"
        const aType = d.agentType || "individual"
        const members = d.memberCount ? ` (${d.memberCount} agents)` : ""
        const start = d.startTime ? d.startTime.substring(0, 16).replace("T", " ") : "\u2014"

        tooltip.classed("hidden", false).html(`
          <div class="font-semibold mb-1 truncate">${d.name}${members}</div>
          <div class="space-y-0.5 text-base-content/60">
            <div><span class="text-base-content/40">ID:</span> <span class="font-mono">${d.id.substring(0, 12)}</span></div>
            <div><span class="text-base-content/40">Tier:</span> T${d.tier}</div>
            <div><span class="text-base-content/40">Status:</span> <span style="color:${STATUS_COLORS[d.status] || '#8b949e'}">${d.status}</span></div>
            <div><span class="text-base-content/40">Type:</span> ${cl.label} <span class="opacity-50">(${aType})</span></div>
            <div><span class="text-base-content/40">Namespace:</span> ${ns}</div>
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
          .attr("stroke-width", d => d.agentType !== "individual" ? 3 : 2)
          .attr("filter", null)
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

      // Convex hull group indicators (namespace > project)
      if (groupKeys.length > 0) {
        hullLayer.selectAll("*").remove()
        groupKeys.forEach((key, i) => {
          const group = groupMap[key]
          const members = group.nodes.filter(n => n.x !== undefined)
          if (members.length < 2) return
          const pad = group.isNamespace ? 18 : 14
          const pts = members.flatMap(n => [
            [n.x - pad, n.y - pad], [n.x + pad, n.y - pad],
            [n.x - pad, n.y + pad], [n.x + pad, n.y + pad]
          ])
          const hull = d3.polygonHull(pts)
          if (!hull) return
          const color = HULL_COLORS[i % HULL_COLORS.length]
          const fillOpacity = group.isNamespace ? "33" : "18"
          const strokeOpacity = group.isNamespace ? "88" : "55"
          hullLayer.append("path")
            .attr("d", "M" + hull.map(p => p.join(",")).join("L") + "Z")
            .attr("fill", color + fillOpacity)
            .attr("stroke", color + strokeOpacity)
            .attr("stroke-width", group.isNamespace ? 1.5 : 1)
            .attr("stroke-dasharray", group.isNamespace ? null : "5 3")

          // Namespace label on hull
          if (group.isNamespace) {
            const cx = d3.mean(members, n => n.x)
            const minY = d3.min(members, n => n.y) - pad - 6
            hullLayer.append("text")
              .attr("x", cx).attr("y", minY)
              .attr("text-anchor", "middle")
              .attr("font-size", 9).attr("font-weight", "600")
              .attr("fill", color).attr("opacity", 0.7)
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
