/**
 * AlignmentGraph LiveView JS Hook
 *
 * D3 force-directed graph for Agent Alignment Audit visualization.
 * Renders skills as large nodes, gap issues as smaller satellite nodes.
 * Color coding:
 *   - green  (#10b981) = aligned (has APM registration + formation_role)
 *   - amber  (#f59e0b) = partial (has registration but missing formation_role, or vice versa)
 *   - red    (#ef4444) = missing (no registration, no formation_role)
 *   - zinc   (#71717a) = gap node (issue annotation)
 *
 * Animation sequence:
 *   1. Skill nodes fade in staggered (50ms each)
 *   2. Gap satellite nodes orbit outward from skill
 *   3. Edges animate via stroke-dashoffset
 *   4. On hover: tooltip with details
 */

// D3 lazy loading
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

const STATUS_COLORS = {
  aligned:  "#10b981",  // emerald-500
  partial:  "#f59e0b",  // amber-500
  missing:  "#ef4444",  // red-500
  gap:      "#71717a",  // zinc-500
}

const NODE_RADIUS = {
  skill: 26,
  gap:   10,
}

export default {
  async mounted() {
    await ensureD3()
    this._data = null
    this._tooltip = null
    this._sim = null
    this._svg = null
    this._resizeObserver = null

    this._initSvg()
    this._initTooltip()

    this.handleEvent("alignment_data", (data) => {
      this._data = data
      this._render(data)
    })

    this._resizeObserver = new ResizeObserver(() => {
      if (this._data) this._render(this._data)
    })
    this._resizeObserver.observe(this.el)
  },

  destroyed() {
    if (this._sim) this._sim.stop()
    if (this._resizeObserver) this._resizeObserver.disconnect()
    if (this._tooltip) this._tooltip.remove()
  },

  _initSvg() {
    this.el.innerHTML = ""
    this._svg = d3.select(this.el)
      .append("svg")
      .attr("width", "100%")
      .attr("height", "100%")
      .style("background", "#09090b")  // zinc-950

    this._svg.append("defs").append("marker")
      .attr("id", "alignment-arrow")
      .attr("viewBox", "0 -5 10 10")
      .attr("refX", 22)
      .attr("refY", 0)
      .attr("markerWidth", 6)
      .attr("markerHeight", 6)
      .attr("orient", "auto")
      .append("path")
      .attr("d", "M0,-5L10,0L0,5")
      .attr("fill", "#52525b")

    this._g = this._svg.append("g").attr("class", "alignment-root")

    // Zoom + pan
    const zoom = d3.zoom()
      .scaleExtent([0.2, 4])
      .on("zoom", (event) => {
        this._g.attr("transform", event.transform)
      })
    this._svg.call(zoom)
  },

  _initTooltip() {
    if (this._tooltip) this._tooltip.remove()
    this._tooltip = d3.select(document.body)
      .append("div")
      .attr("class", "alignment-graph-tooltip")
      .style("position", "fixed")
      .style("background", "#18181b")
      .style("border", "1px solid #3f3f46")
      .style("border-radius", "8px")
      .style("padding", "10px 14px")
      .style("font-size", "12px")
      .style("color", "#e4e4e7")
      .style("pointer-events", "none")
      .style("opacity", "0")
      .style("max-width", "280px")
      .style("z-index", "9999")
      .style("line-height", "1.6")
  },

  _render(data) {
    if (!data || !data.nodes || data.nodes.length === 0) return

    const rect = this.el.getBoundingClientRect()
    const W = rect.width || 800
    const H = rect.height || 600

    if (this._sim) this._sim.stop()
    this._g.selectAll("*").remove()

    const nodes = data.nodes.map(d => ({...d}))
    const links = (data.links || []).map(d => ({...d}))

    // Separate skill vs gap nodes for layout hints
    const skillNodes = nodes.filter(n => n.type === "skill")
    const gapNodes = nodes.filter(n => n.type === "gap")

    // Place skill nodes in a circle initially
    const skillCount = skillNodes.length
    skillNodes.forEach((n, i) => {
      const angle = (i / skillCount) * 2 * Math.PI
      const r = Math.min(W, H) * 0.3
      n.x = W / 2 + r * Math.cos(angle)
      n.y = H / 2 + r * Math.sin(angle)
    })

    // Gap nodes start at their parent skill position
    gapNodes.forEach(n => {
      const parent = nodes.find(s => s.id === `skill-${n.skill}`)
      if (parent) { n.x = parent.x || W / 2; n.y = parent.y || H / 2 }
    })

    // Resolve link references
    const nodeById = new Map(nodes.map(n => [n.id, n]))
    const resolvedLinks = links
      .map(l => ({
        source: nodeById.get(l.source) || l.source,
        target: nodeById.get(l.target) || l.target,
        type: l.type
      }))
      .filter(l => l.source && l.target)

    // Force simulation
    this._sim = d3.forceSimulation(nodes)
      .force("link", d3.forceLink(resolvedLinks)
        .id(d => d.id)
        .distance(d => d.type === "gap" ? 60 : 140)
        .strength(d => d.type === "gap" ? 0.8 : 0.4)
      )
      .force("charge", d3.forceManyBody()
        .strength(d => d.type === "skill" ? -400 : -80)
      )
      .force("center", d3.forceCenter(W / 2, H / 2).strength(0.05))
      .force("collision", d3.forceCollide()
        .radius(d => (d.type === "skill" ? NODE_RADIUS.skill : NODE_RADIUS.gap) + 12)
      )
      .alphaDecay(0.02)

    // Draw links
    const link = this._g.append("g").attr("class", "links")
      .selectAll("line")
      .data(resolvedLinks)
      .join("line")
      .attr("stroke", "#3f3f46")
      .attr("stroke-width", 1.5)
      .attr("stroke-dasharray", "6,3")
      .attr("stroke-dashoffset", 100)
      .attr("opacity", 0)

    // Animate links in
    link.transition().duration(800).delay((_, i) => i * 30)
      .attr("stroke-dashoffset", 0)
      .attr("opacity", 0.6)

    // Draw nodes
    const node = this._g.append("g").attr("class", "nodes")
      .selectAll("g")
      .data(nodes)
      .join("g")
      .attr("class", d => `alignment-node alignment-node--${d.type}`)
      .attr("opacity", 0)
      .call(d3.drag()
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

    // Skill nodes: circle
    node.filter(d => d.type === "skill")
      .append("circle")
      .attr("r", NODE_RADIUS.skill)
      .attr("fill", d => statusFill(d.status))
      .attr("stroke", d => STATUS_COLORS[d.status] || STATUS_COLORS.missing)
      .attr("stroke-width", 2)
      .style("filter", d => d.status === "aligned" ? "drop-shadow(0 0 6px #10b98166)" : "none")

    // Skill node label
    node.filter(d => d.type === "skill")
      .append("text")
      .attr("text-anchor", "middle")
      .attr("dy", "0.35em")
      .attr("font-size", "9px")
      .attr("font-family", "ui-monospace, monospace")
      .attr("fill", "#e4e4e7")
      .text(d => truncate(d.label, 14))

    // Integrity score badge on skill nodes
    node.filter(d => d.type === "skill" && d.integrity_score !== undefined)
      .append("text")
      .attr("text-anchor", "middle")
      .attr("dy", NODE_RADIUS.skill + 14)
      .attr("font-size", "8px")
      .attr("fill", d => STATUS_COLORS[d.status] || "#71717a")
      .text(d => `${d.integrity_score}%`)

    // Gap nodes: smaller diamond / circle
    node.filter(d => d.type === "gap")
      .append("circle")
      .attr("r", NODE_RADIUS.gap)
      .attr("fill", "#27272a")
      .attr("stroke", "#71717a")
      .attr("stroke-width", 1.5)

    node.filter(d => d.type === "gap")
      .append("text")
      .attr("text-anchor", "middle")
      .attr("dy", "0.35em")
      .attr("font-size", "7px")
      .attr("fill", "#a1a1aa")
      .text(d => truncate(d.label, 10))

    // Staggered fade-in for nodes
    node.transition()
      .duration(400)
      .delay((d, i) => d.type === "skill" ? i * 50 : 300 + i * 20)
      .attr("opacity", 1)

    // Tooltip
    const tooltip = this._tooltip
    node.on("mouseover", (event, d) => {
      let html = `<div style="font-weight:600;margin-bottom:4px;color:${STATUS_COLORS[d.status] || "#e4e4e7"}">${d.label}</div>`
      html += `<div style="color:#a1a1aa">Type: ${d.type}</div>`
      if (d.type === "skill") {
        html += `<div>Status: <span style="color:${STATUS_COLORS[d.status]}">${d.status}</span></div>`
        html += `<div>Integrity: ${d.integrity_score ?? "?"}%</div>`
        html += `<div>Agent refs: ${d.agent_count ?? 0}</div>`
      }
      if (d.type === "gap" && d.recommendation) {
        html += `<div style="margin-top:6px;font-size:11px;color:#d4d4d8">${d.recommendation}</div>`
      }
      tooltip.html(html)
        .style("left", `${event.clientX + 12}px`)
        .style("top", `${event.clientY - 8}px`)
        .transition().duration(150).style("opacity", "1")
    })
    .on("mousemove", (event) => {
      tooltip.style("left", `${event.clientX + 12}px`).style("top", `${event.clientY - 8}px`)
    })
    .on("mouseout", () => {
      tooltip.transition().duration(200).style("opacity", "0")
    })

    // Simulation tick
    this._sim.on("tick", () => {
      link
        .attr("x1", d => d.source.x)
        .attr("y1", d => d.source.y)
        .attr("x2", d => d.target.x)
        .attr("y2", d => d.target.y)

      node.attr("transform", d => `translate(${d.x},${d.y})`)
    })
  }
}

function statusFill(status) {
  switch (status) {
    case "aligned": return "#052e16"   // emerald-950
    case "partial":  return "#451a03"  // amber-950
    case "missing":  return "#450a0a"  // red-950
    default:         return "#18181b"  // zinc-900
  }
}

function truncate(str, max) {
  if (!str) return ""
  return str.length > max ? str.slice(0, max - 1) + "…" : str
}
