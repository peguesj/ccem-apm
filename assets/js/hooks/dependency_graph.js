/**
 * DependencyGraph LiveView JS Hook
 *
 * Industrial SCADA-inspired pipeline visualization with:
 * - Rectangular card nodes with glassmorphic styling
 * - Dashed pipeline connections with glowing endpoint dots
 * - Dot grid background pattern
 * - Status-colored gradient overlays
 * - Tier lane layout with conveyor-belt aesthetics
 */
import * as d3 from "../../vendor/d3.min.js"

// -- Color palette (industrial/SCADA) --
const PALETTE = {
  bg:           "#151b28",
  bgCard:       "#1c2536",
  bgCardHover:  "#232f44",
  border:       "#2a3548",
  borderHover:  "#3d506a",
  text:         "#e2e8f0",
  textDim:      "#8899aa",
  textMuted:    "#556677",
  dotGrid:      "#253040",
  pipeline:     "#2a3548",
  pipelineDot:  "#7eef6d",
  accent:       "#7eef6d",
  accentDim:    "#7eef6d66",
}

const STATUS_COLORS = {
  active:     "#7eef6d",
  idle:       "#6b7b8d",
  error:      "#ff6b5a",
  discovered: "#5daaff",
  completed:  "#c4a0ff",
  running:    "#7eef6d",
  complete:   "#c4a0ff",
  standby:    "#ffaa44",
}

const STATUS_GLOW = {
  active:     "rgba(126,239,109,0.25)",
  idle:       "rgba(107,123,141,0.08)",
  error:      "rgba(255,107,90,0.25)",
  discovered: "rgba(93,170,255,0.20)",
  completed:  "rgba(196,160,255,0.15)",
  running:    "rgba(126,239,109,0.25)",
  complete:   "rgba(196,160,255,0.15)",
  standby:    "rgba(255,170,68,0.20)",
}

const UUID_RE = /^[0-9a-f]{7,8}$/i

function classify(agent) {
  const name = (agent.name || "").toLowerCase()
  const meta = agent.metadata || {}
  const type = (meta.type || "").toLowerCase()
  const at = (agent.agentType || "individual").toLowerCase()

  if (at === "squadron") return { label: "squadron", tag: "SQ", icon: "\u25A3" }
  if (at === "swarm")    return { label: "swarm",    tag: "SW", icon: "\u25C9" }
  if (type === "orchestrator" || at === "orchestrator") return { label: "orchestrator", tag: "ORC", icon: "\u2B22" }
  if (type === "session")                           return { label: "session",  tag: "SESS", icon: "\u25CE" }
  if (type === "tool-runner" || type === "tool_runner") return { label: "tool",  tag: "TOOL", icon: "\u2692" }
  if (name.includes("explore") || name.includes("search")) return { label: "explore", tag: "EXPL", icon: "\u25B7" }
  if (name.includes("fix") || name.includes("repair"))     return { label: "fix",     tag: "FIX", icon: "\u2692" }
  if (name.includes("test") || name.includes("spec"))      return { label: "test",    tag: "TEST", icon: "\u25C7" }
  if (name.includes("build") || name.includes("compile"))  return { label: "build",   tag: "BILD", icon: "\u25A0" }
  if (name.includes("monitor") || name.includes("watch"))  return { label: "watch",   tag: "WTCH", icon: "\u25C6" }
  if (name.includes("plan") || name.includes("analyze"))   return { label: "plan",    tag: "PLAN", icon: "\u25B3" }
  if (UUID_RE.test(name) || name === "unknown" || name === "") return { label: "agent", tag: "ANON", icon: "\u25CB" }

  const parts = name.split(":")
  return { label: name, tag: parts[parts.length - 1].substring(0, 4).toUpperCase(), icon: "\u25A1" }
}

function isAnon(agent) {
  const name = agent.name || agent.id || ""
  return UUID_RE.test(name) || name === "unknown" || name === ""
}

// Card dimensions
const CARD_W = 130
const CARD_H = 56
const CARD_R = 8  // border radius
const DOT_R  = 4  // connection dot radius

const DependencyGraph = {
  mounted() {
    this.svg = d3.select(this.el).append("svg")
      .attr("width", "100%")
      .attr("height", "100%")
      .attr("role", "img")
      .attr("aria-labelledby", "dep-graph-title dep-graph-desc")

    this.tooltip = d3.select(this.el).append("div")
      .attr("class", "dep-tooltip")
      .style("position", "absolute")
      .style("display", "none")

    this.simulation = null
    this.agents = []
    this.edges = []
    this.showAnon = false

    this.handleEvent("agents_updated", (data) => {
      this.agents = data.agents || []
      this.edges = data.edges || []
      this.draw()
    })

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

    // Accessible metadata
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

    // -- Background --
    this.svg.append("rect")
      .attr("width", width).attr("height", height)
      .attr("fill", PALETTE.bg).attr("rx", 8)

    // Dot grid pattern
    const defs = this.svg.append("defs")

    const dotPattern = defs.append("pattern")
      .attr("id", "dot-grid")
      .attr("width", 24).attr("height", 24)
      .attr("patternUnits", "userSpaceOnUse")
    dotPattern.append("circle")
      .attr("cx", 12).attr("cy", 12).attr("r", 1.2)
      .attr("fill", PALETTE.dotGrid)

    this.svg.append("rect")
      .attr("width", width).attr("height", height)
      .attr("fill", "url(#dot-grid)").attr("rx", 8)

    // -- Glow filters --
    const glowFilter = defs.append("filter").attr("id", "glow-active")
      .attr("x", "-50%").attr("y", "-50%").attr("width", "200%").attr("height", "200%")
    glowFilter.append("feGaussianBlur").attr("stdDeviation", "4").attr("result", "blur")
    const feMerge = glowFilter.append("feMerge")
    feMerge.append("feMergeNode").attr("in", "blur")
    feMerge.append("feMergeNode").attr("in", "SourceGraphic")

    const cardGlow = defs.append("filter").attr("id", "card-glow")
      .attr("x", "-20%").attr("y", "-20%").attr("width", "140%").attr("height", "140%")
    cardGlow.append("feGaussianBlur").attr("stdDeviation", "6").attr("result", "blur")
    const cg = cardGlow.append("feMerge")
    cg.append("feMergeNode").attr("in", "blur")
    cg.append("feMergeNode").attr("in", "SourceGraphic")

    // Pipeline dot glow
    const dotGlow = defs.append("filter").attr("id", "dot-glow")
      .attr("x", "-100%").attr("y", "-100%").attr("width", "300%").attr("height", "300%")
    dotGlow.append("feGaussianBlur").attr("stdDeviation", "3").attr("result", "blur")
    const dg = dotGlow.append("feMerge")
    dg.append("feMergeNode").attr("in", "blur")
    dg.append("feMergeNode").attr("in", "SourceGraphic")

    if (this.agents.length === 0) {
      this.svg.append("text")
        .attr("x", width / 2).attr("y", height / 2)
        .attr("text-anchor", "middle")
        .attr("fill", PALETTE.textMuted).attr("font-size", 13)
        .text("No agents registered")
      return
    }

    // -- Build nodes --
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
    const nodes = this.showAnon ? allAgents : allAgents.filter(n => !isAnon(n))

    if (nodes.length === 0) {
      this.svg.append("text")
        .attr("x", width / 2).attr("y", height / 2)
        .attr("text-anchor", "middle")
        .attr("fill", PALETTE.textMuted).attr("font-size", 13)
        .text(`${anonCount} unnamed agents hidden`)
      return
    }

    const n = nodes.length

    // Degree map
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

    // Tier layout
    const tierSet = [...new Set(nodes.map(n => n.tier))].sort()
    const tierCount = tierSet.length
    const tierYMap = {}
    const margin = 0.14
    tierSet.forEach((t, i) => {
      tierYMap[t] = tierCount === 1 ? 0.5 : margin + (1 - 2 * margin) * (i / (tierCount - 1))
    })
    const getTierY = (tier) => (tierYMap[tier] ?? 0.5) * height

    const chargeStrength = Math.min(-200, -80 * Math.sqrt(n))
    const linkDistance = Math.max(80, Math.min(180, width / (n * 0.25)))
    const tierStrength = n > 30 ? 0.10 : n > 15 ? 0.15 : 0.20

    // -- Zoom container --
    const zoomG = this.svg.append("g")
    const zoom = d3.zoom()
      .scaleExtent([0.3, 4])
      .on("zoom", (event) => { zoomG.attr("transform", event.transform) })
    this.svg.call(zoom)

    // -- Tier lane dividers --
    if (tierCount > 1) {
      const laneG = zoomG.append("g")
      for (let i = 0; i < tierSet.length - 1; i++) {
        const y = (getTierY(tierSet[i]) + getTierY(tierSet[i + 1])) / 2
        laneG.append("line")
          .attr("x1", 20).attr("x2", width - 20).attr("y1", y).attr("y2", y)
          .attr("stroke", PALETTE.border).attr("stroke-width", 1)
          .attr("stroke-dasharray", "6 10").attr("opacity", 0.3)
      }
      tierSet.forEach(t => {
        laneG.append("text")
          .attr("x", 8).attr("y", getTierY(t) - 10)
          .attr("font-size", 10).attr("fill", PALETTE.textMuted).attr("opacity", 0.5)
          .attr("font-family", "monospace")
          .text("Tier " + t)
      })
    }

    // -- Simulation --
    this.simulation = d3.forceSimulation(nodes)
      .force("link", d3.forceLink(allLinks).id(d => d.id).distance(linkDistance).strength(0.25))
      .force("charge", d3.forceManyBody().strength(chargeStrength))
      .force("collision", d3.forceCollide().radius(d => CARD_W * 0.45))
      .force("x", d3.forceX(width / 2).strength(0.03))
      .force("tierY", d3.forceY(d => getTierY(d.tier)).strength(tierStrength))

    // -- Links (pipeline connections) --
    const linkG = zoomG.append("g")

    const link = linkG.selectAll("g").data(allLinks).enter().append("g")

    // Dashed pipeline line
    link.append("line")
      .attr("class", "pipeline-line")
      .attr("stroke", PALETTE.pipeline)
      .attr("stroke-width", 2)
      .attr("stroke-dasharray", "8 6")
      .attr("opacity", 0.6)

    // Source dot (green glowing square)
    link.append("rect")
      .attr("class", "pipeline-dot-src")
      .attr("width", DOT_R * 2).attr("height", DOT_R * 2)
      .attr("rx", 1.5)
      .attr("fill", PALETTE.pipelineDot)
      .attr("filter", "url(#dot-glow)")

    // Target dot
    link.append("rect")
      .attr("class", "pipeline-dot-tgt")
      .attr("width", DOT_R * 2).attr("height", DOT_R * 2)
      .attr("rx", 1.5)
      .attr("fill", PALETTE.pipelineDot)
      .attr("filter", "url(#dot-glow)")

    // Metallic connector at midpoint
    link.append("rect")
      .attr("class", "pipeline-connector")
      .attr("width", 16).attr("height", 6)
      .attr("rx", 2)
      .attr("fill", "#3d4f63")
      .attr("stroke", "#556b80")
      .attr("stroke-width", 0.5)

    // -- Nodes (card style) --
    const node = zoomG.append("g")
      .selectAll("g").data(nodes).enter().append("g")
      .attr("class", "graph-node")
      .attr("tabindex", "0")
      .attr("role", "button")
      .attr("aria-label", d => `Agent ${d.name || d.id}, status ${d.status}`)
      .style("cursor", "grab")
      .call(this.drag(this.simulation))

    // Card background with glassmorphism
    node.append("rect")
      .attr("x", -CARD_W / 2).attr("y", -CARD_H / 2)
      .attr("width", CARD_W).attr("height", CARD_H)
      .attr("rx", CARD_R)
      .attr("fill", d => {
        const glow = STATUS_GLOW[d.status] || STATUS_GLOW.idle
        return PALETTE.bgCard
      })
      .attr("stroke", d => {
        const c = STATUS_COLORS[d.status] || STATUS_COLORS.idle
        return c + "55"
      })
      .attr("stroke-width", 1.5)
      .attr("class", "card-bg")

    // Status gradient overlay (top edge glow)
    node.append("rect")
      .attr("x", -CARD_W / 2).attr("y", -CARD_H / 2)
      .attr("width", CARD_W).attr("height", 3)
      .attr("rx", CARD_R)
      .attr("fill", d => STATUS_COLORS[d.status] || STATUS_COLORS.idle)
      .attr("opacity", 0.8)

    // Subtle inner gradient (status-colored glow from top)
    node.each(function(d) {
      const gradId = `grad-${d.id.replace(/[^a-zA-Z0-9]/g, "")}`
      const sc = STATUS_COLORS[d.status] || STATUS_COLORS.idle
      const grad = defs.append("linearGradient")
        .attr("id", gradId)
        .attr("x1", "0%").attr("y1", "0%").attr("x2", "0%").attr("y2", "100%")
      grad.append("stop").attr("offset", "0%").attr("stop-color", sc).attr("stop-opacity", 0.12)
      grad.append("stop").attr("offset", "100%").attr("stop-color", sc).attr("stop-opacity", 0)

      d3.select(this).append("rect")
        .attr("x", -CARD_W / 2).attr("y", -CARD_H / 2)
        .attr("width", CARD_W).attr("height", CARD_H)
        .attr("rx", CARD_R)
        .attr("fill", `url(#${gradId})`)
        .attr("pointer-events", "none")
    })

    // Status icon (top-left corner badge)
    node.append("rect")
      .attr("x", -CARD_W / 2 + 6).attr("y", -CARD_H / 2 + 8)
      .attr("width", 20).attr("height", 20)
      .attr("rx", 4)
      .attr("fill", d => STATUS_COLORS[d.status] || STATUS_COLORS.idle)
      .attr("opacity", 0.9)

    node.append("text")
      .attr("x", -CARD_W / 2 + 16).attr("y", -CARD_H / 2 + 22)
      .attr("text-anchor", "middle")
      .attr("font-size", 10).attr("fill", "#fff").attr("font-weight", "bold")
      .text(d => classify(d).tag.substring(0, 2))

    // Agent name (main label)
    node.append("text")
      .attr("x", -CARD_W / 2 + 32).attr("y", -CARD_H / 2 + 22)
      .attr("font-size", 11).attr("font-weight", "600")
      .attr("fill", PALETTE.text)
      .text(d => {
        const parts = (d.name || d.id).split(":")
        const seg = parts[parts.length - 1]
        return seg.length > 12 ? seg.substring(0, 10) + ".." : seg
      })

    // Tier/line label (bottom, accent colored)
    node.append("rect")
      .attr("x", -CARD_W / 2 + 6).attr("y", CARD_H / 2 - 22)
      .attr("width", 64).attr("height", 16)
      .attr("rx", 4)
      .attr("fill", PALETTE.bg)
      .attr("stroke", PALETTE.border)
      .attr("stroke-width", 0.5)

    node.append("text")
      .attr("x", -CARD_W / 2 + 38).attr("y", CARD_H / 2 - 10)
      .attr("text-anchor", "middle")
      .attr("font-size", 9).attr("font-family", "monospace")
      .attr("fill", d => STATUS_COLORS[d.status] || PALETTE.accent)
      .text(d => {
        const cl = classify(d)
        return `${cl.label.substring(0, 4)}/ ${String(d.tier).padStart(2, "0")}`
      })

    // Active pulse ring
    node.filter(d => d.status === "active" || d.status === "running")
      .append("rect")
      .attr("x", -CARD_W / 2 - 3).attr("y", -CARD_H / 2 - 3)
      .attr("width", CARD_W + 6).attr("height", CARD_H + 6)
      .attr("rx", CARD_R + 2)
      .attr("fill", "none")
      .attr("stroke", STATUS_COLORS.active)
      .attr("stroke-width", 1)
      .attr("stroke-dasharray", "6 4")
      .attr("opacity", 0.4)
      .attr("class", "pulse-ring")

    // Member count badge (top-right)
    node.filter(d => d.memberCount && d.memberCount > 1)
      .append("circle")
      .attr("cx", CARD_W / 2 - 8).attr("cy", -CARD_H / 2 + 8)
      .attr("r", 8)
      .attr("fill", "#5daaff").attr("stroke", PALETTE.bg).attr("stroke-width", 1.5)

    node.filter(d => d.memberCount && d.memberCount > 1)
      .append("text")
      .attr("x", CARD_W / 2 - 8).attr("y", -CARD_H / 2 + 8)
      .attr("text-anchor", "middle").attr("dy", "0.35em")
      .attr("font-size", 7).attr("font-weight", "bold").attr("fill", "#fff")
      .text(d => d.memberCount)

    // -- Tooltip --
    const tooltip = this.tooltip
    const pushEvent = this.pushEvent.bind(this)

    node
      .on("mouseover", function(event, d) {
        const cl = classify(d)
        const depsStr = d.deps.length > 0
          ? d.deps.slice(0, 3).join(", ") + (d.deps.length > 3 ? ` +${d.deps.length - 3}` : "")
          : "none"
        const sc = STATUS_COLORS[d.status] || STATUS_COLORS.idle
        tooltip.style("display", "block").html(`
          <div style="border-left: 3px solid ${sc}; padding-left: 8px; margin-bottom: 6px;">
            <div style="font-weight: 600; font-size: 12px; color: ${PALETTE.text};">${d.name}${d.memberCount ? ` (${d.memberCount})` : ""}</div>
            <div style="font-size: 10px; color: ${PALETTE.textDim};">${cl.label} / ${d.agentType}</div>
          </div>
          <div style="font-size: 10px; color: ${PALETTE.textDim}; line-height: 1.6;">
            <div><span style="color:${PALETTE.textMuted}">ID:</span> <span style="font-family:monospace">${d.id.substring(0, 12)}</span></div>
            <div><span style="color:${PALETTE.textMuted}">Tier:</span> T${d.tier}</div>
            <div><span style="color:${PALETTE.textMuted}">Status:</span> <span style="color:${sc}">${d.status}</span></div>
            ${d.namespace ? `<div><span style="color:${PALETTE.textMuted}">NS:</span> ${d.namespace}</div>` : ""}
            ${d.project ? `<div><span style="color:${PALETTE.textMuted}">Project:</span> ${d.project}</div>` : ""}
            <div><span style="color:${PALETTE.textMuted}">Deps:</span> ${depsStr}</div>
          </div>
        `)
        const rect = container.getBoundingClientRect()
        tooltip
          .style("left", (event.clientX - rect.left + 14) + "px")
          .style("top",  (event.clientY - rect.top  - 12) + "px")

        d3.select(this).select(".card-bg")
          .attr("stroke-width", 2)
          .attr("stroke", (STATUS_COLORS[d.status] || STATUS_COLORS.idle) + "99")
          .attr("filter", "url(#card-glow)")
      })
      .on("mousemove", function(event) {
        const rect = container.getBoundingClientRect()
        tooltip
          .style("left", (event.clientX - rect.left + 14) + "px")
          .style("top",  (event.clientY - rect.top  - 12) + "px")
      })
      .on("mouseout", function(event, d) {
        tooltip.style("display", "none")
        d3.select(this).select(".card-bg")
          .attr("stroke-width", 1.5)
          .attr("stroke", (STATUS_COLORS[d.status] || STATUS_COLORS.idle) + "55")
          .attr("filter", null)
      })
      .on("click", function(event, d) {
        pushEvent("select_agent", { agent_id: d.id })
      })

    // Keyboard navigation
    node.on("keydown", function(event, d) {
      if (event.key === "Enter" || event.key === " ") {
        event.preventDefault()
        pushEvent("select_agent", { agent_id: d.id })
      }
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
      if (targetIndex >= 0) allNodes[targetIndex].focus()
    })

    this.svg.selectAll("defs").attr("aria-hidden", "true").attr("focusable", "false")

    // ANON count
    if (anonCount > 0 && !this.showAnon) {
      this.svg.append("text")
        .attr("x", width - 12).attr("y", height - 12)
        .attr("text-anchor", "end")
        .attr("font-size", 10).attr("fill", PALETTE.textMuted).attr("opacity", 0.6)
        .attr("cursor", "pointer").attr("font-family", "monospace")
        .text(`+${anonCount} unnamed hidden`)
        .on("click", () => {
          this.showAnon = true
          this.draw()
          pushEvent("graph_anon_toggled", { show: true })
        })
    }

    // -- Tick --
    this.simulation.on("tick", () => {
      const pad = CARD_W / 2 + 10
      const padY = CARD_H / 2 + 10
      nodes.forEach(d => {
        d.x = Math.max(pad, Math.min(width - pad, d.x))
        d.y = Math.max(padY, Math.min(height - padY, d.y))
      })

      // Update pipeline lines
      link.select(".pipeline-line")
        .attr("x1", d => d.source.x + CARD_W / 2)
        .attr("y1", d => d.source.y)
        .attr("x2", d => d.target.x - CARD_W / 2)
        .attr("y2", d => d.target.y)

      // Connection dots at card edges
      link.select(".pipeline-dot-src")
        .attr("x", d => d.source.x + CARD_W / 2 - DOT_R)
        .attr("y", d => d.source.y - DOT_R)

      link.select(".pipeline-dot-tgt")
        .attr("x", d => d.target.x - CARD_W / 2 - DOT_R)
        .attr("y", d => d.target.y - DOT_R)

      // Metallic connector at midpoint
      link.select(".pipeline-connector")
        .attr("x", d => (d.source.x + d.target.x) / 2 - 8)
        .attr("y", d => (d.source.y + d.target.y) / 2 - 3)

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
