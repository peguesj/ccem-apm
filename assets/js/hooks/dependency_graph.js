/**
 * DependencyGraph LiveView JS Hook
 *
 * Collapsible hierarchical tree visualization with:
 * - d3.hierarchy() + d3.tree() layout
 * - d3.linkVertical() curved Bezier connectors
 * - Click-to-expand/collapse group nodes
 * - SVG arrowhead markers for dependency direction
 * - SCADA industrial aesthetic preserved
 * - Keyboard navigation (Enter/Space, Arrow keys)
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
  dotGrid:      "#364258",
  accent:       "#7eef6d",
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
  warning:    "#ffaa44",
}

// Card dimensions
const NODE_W = 140
const NODE_H = 44
const NODE_R = 8
const TRANSITION_MS = 750

function statusColor(status) {
  return STATUS_COLORS[status] || PALETTE.textDim
}

function aggregateStatus(children) {
  if (!children || children.length === 0) return "idle"
  const statuses = children.map(c => c.data?.status || c.status || "idle")
  if (statuses.includes("error")) return "error"
  if (statuses.includes("warning")) return "warning"
  if (statuses.includes("active") || statuses.includes("running")) return "running"
  if (statuses.every(s => s === "completed" || s === "complete")) return "completed"
  return "idle"
}

function nodeIcon(type) {
  switch (type) {
    case "project": return "\u25A3"
    case "formation": return "\u25C9"
    case "squadron": return "\u25A0"
    case "swarm": return "\u25C6"
    case "cluster": return "\u25B3"
    case "agent": return "\u25CB"
    default: return "\u25A1"
  }
}

// Build a hierarchy from flat agent data (backward compat with agents_updated)
function buildHierarchyFromFlat(agents, scope) {
  if (!agents || agents.length === 0) {
    return { name: "root", type: "root", children: [], status: "idle" }
  }

  if (scope === "all_projects") {
    const byProject = d3.group(agents, d => d.project_name || d.projectName || "unknown")
    const projectNodes = Array.from(byProject, ([projectName, projectAgents]) => {
      const byFormation = d3.group(projectAgents, d => d.formation_id || d.formationId || "unaffiliated")
      const formationNodes = Array.from(byFormation, ([fmtId, fmtAgents]) => ({
        id: `fmt-${projectName}-${fmtId}`,
        name: fmtId === "unaffiliated" ? "Unaffiliated" : fmtId,
        type: "formation",
        status: aggregateStatus(fmtAgents),
        agent_count: fmtAgents.length,
        children: fmtAgents.map(a => ({
          id: a.id,
          name: a.name || a.id,
          type: "agent",
          status: a.status || "idle",
          data: a
        }))
      }))
      return {
        id: `proj-${projectName}`,
        name: projectName,
        type: "project",
        status: aggregateStatus(formationNodes),
        agent_count: projectAgents.length,
        children: formationNodes
      }
    })
    return { id: "root", name: "All Projects", type: "root", children: projectNodes, status: "idle" }
  }

  // Single project scope — with squadron/swarm hierarchy
  const byFormation = d3.group(agents, d => d.formation_id || d.formationId || "unaffiliated")
  const formationNodes = Array.from(byFormation, ([fmtId, fmtAgents]) => {
    // Group by squadron if metadata present
    const bySquadron = d3.group(fmtAgents, d => d.squadron || "default")
    const hasSquadrons = bySquadron.size > 1 || !bySquadron.has("default")

    const children = hasSquadrons
      ? Array.from(bySquadron, ([sqName, sqAgents]) => {
          // Group by swarm within squadron
          const bySwarm = d3.group(sqAgents, d => d.swarm || "default")
          const hasSwarms = bySwarm.size > 1 || !bySwarm.has("default")

          const sqChildren = hasSwarms
            ? Array.from(bySwarm, ([swName, swAgents]) => ({
                id: `swarm-${fmtId}-${sqName}-${swName}`,
                name: swName,
                type: "swarm",
                status: aggregateStatus(swAgents),
                agent_count: swAgents.length,
                children: swAgents.map(a => ({
                  id: a.id, name: a.name || a.id, type: "agent",
                  status: a.status || "idle", data: a
                }))
              }))
            : sqAgents.map(a => ({
                id: a.id, name: a.name || a.id, type: "agent",
                status: a.status || "idle", data: a
              }))

          return {
            id: `sq-${fmtId}-${sqName}`,
            name: sqName,
            type: "squadron",
            status: aggregateStatus(sqAgents),
            agent_count: sqAgents.length,
            children: sqChildren
          }
        })
      : fmtAgents.map(a => ({
          id: a.id, name: a.name || a.id, type: "agent",
          status: a.status || "idle", data: a
        }))

    return {
      id: `fmt-${fmtId}`,
      name: fmtId === "unaffiliated" ? "Unaffiliated" : fmtId,
      type: "formation",
      status: aggregateStatus(fmtAgents),
      agent_count: fmtAgents.length,
      children
    }
  })
  return { id: "root", name: "Project", type: "root", children: formationNodes, status: "idle" }
}

const DependencyGraph = {
  mounted() {
    this._container = d3.select(this.el)
    this._expandedNodes = new Set(["root"])
    this._focusedId = null
    this._scope = this.el.dataset.scope || "single_project"

    this._svg = this._container.append("svg")
      .attr("width", "100%")
      .attr("height", "100%")
      .attr("role", "img")
      .attr("aria-label", "Agent dependency graph")

    // Dot grid background
    const defs = this._svg.append("defs")
    defs.append("pattern")
      .attr("id", "dotgrid")
      .attr("width", 20).attr("height", 20)
      .attr("patternUnits", "userSpaceOnUse")
      .append("circle")
      .attr("cx", 10).attr("cy", 10).attr("r", 1)
      .attr("fill", PALETTE.dotGrid)

    // Arrowhead markers
    const markerColors = {
      default: PALETTE.border,
      active: PALETTE.accent,
      error: STATUS_COLORS.error,
      warning: STATUS_COLORS.standby,
    }
    Object.entries(markerColors).forEach(([name, color]) => {
      defs.append("marker")
        .attr("id", `arrow-${name}`)
        .attr("viewBox", "0 0 10 10")
        .attr("refX", 8).attr("refY", 5)
        .attr("markerWidth", 8).attr("markerHeight", 8)
        .attr("orient", "auto-start-reverse")
        .append("path")
        .attr("d", "M 0 0 L 10 5 L 0 10 z")
        .attr("fill", color)
    })

    this._bgRect = this._svg.append("rect")
      .attr("width", "100%").attr("height", "100%")
      .attr("fill", `url(#dotgrid)`)

    this._g = this._svg.append("g").attr("class", "graph-content")

    // Zoom behavior
    this._zoom = d3.zoom()
      .scaleExtent([0.3, 3])
      .on("zoom", (event) => this._g.attr("transform", event.transform))
    this._svg.call(this._zoom)

    this._tooltip = this._container.append("div")
      .attr("class", "dep-tooltip")
      .style("position", "absolute")
      .style("display", "none")
      .style("background", PALETTE.bgCard)
      .style("border", `1px solid ${PALETTE.border}`)
      .style("border-radius", "6px")
      .style("padding", "8px 12px")
      .style("color", PALETTE.text)
      .style("font-size", "12px")
      .style("pointer-events", "none")
      .style("z-index", "100")
      .style("backdrop-filter", "blur(8px)")

    this._hierarchyData = null
    this._agents = []

    // Handle hierarchy_data from GraphBuilder (preferred)
    this.handleEvent("hierarchy_data", (data) => {
      this._hierarchyData = data.tree || data
      this._restoreExpandState(this._hierarchyData)
      this._render()
    })

    // Handle agents_updated (backward compat, build hierarchy client-side)
    this.handleEvent("agents_updated", (data) => {
      this._agents = data.agents || []
      this._hierarchyData = buildHierarchyFromFlat(this._agents, this._scope)
      this._restoreExpandState(this._hierarchyData)
      this._render()
    })

    this.handleEvent("graph_toggle_anon", () => {
      this._showAnon = !this._showAnon
      if (this._agents.length > 0) {
        this._hierarchyData = buildHierarchyFromFlat(this._agents, this._scope)
        this._restoreExpandState(this._hierarchyData)
        this._render()
      }
    })

    // Keyboard navigation
    this.el.setAttribute("tabindex", "0")
    this._keyHandler = (e) => this._handleKey(e)
    this.el.addEventListener("keydown", this._keyHandler)
  },

  destroyed() {
    this._tooltip?.remove()
    if (this._keyHandler) {
      this.el.removeEventListener("keydown", this._keyHandler)
    }
  },

  // Recursively collapse children beyond depth 1
  _initCollapseState(node, depth = 0) {
    if (node.children) {
      node.children.forEach(child => {
        if (child.children && child.children.length > 0 && depth >= 1) {
          if (!this._expandedNodes.has(child.id)) {
            child._children = child.children
            child.children = null
          }
        }
        this._initCollapseState(child, depth + 1)
      })
    }
  },

  _restoreExpandState(data) {
    const walk = (node) => {
      if (!node) return
      const id = node.id || node.name
      if (node._children && this._expandedNodes.has(id)) {
        node.children = node._children
        node._children = null
      } else if (node.children && !this._expandedNodes.has(id) && node.type !== "root") {
        node._children = node.children
        node.children = null
      }
      if (node.children) node.children.forEach(walk)
      if (node._children) node._children.forEach(walk)
    }
    // Always expand root
    this._expandedNodes.add(data.id || "root")
    this._initCollapseState(data)
    walk(data)
  },

  _toggleNode(d) {
    const id = d.data.id || d.data.name
    if (d.data._children) {
      d.data.children = d.data._children
      d.data._children = null
      this._expandedNodes.add(id)
    } else if (d.data.children) {
      d.data._children = d.data.children
      d.data.children = null
      this._expandedNodes.delete(id)
    }
    this._render()

    // Notify LiveView of toggle
    this.pushEvent("toggle_node", { node_id: id })
  },

  _render() {
    if (!this._hierarchyData) return

    const rect = this.el.getBoundingClientRect()
    const width = rect.width || 800
    const height = rect.height || 500

    const root = d3.hierarchy(this._hierarchyData, d => d.children)

    // Tree layout
    const treeLayout = d3.tree()
      .nodeSize([NODE_W + 30, NODE_H + 60])
      .separation((a, b) => a.parent === b.parent ? 1.2 : 1.8)

    treeLayout(root)

    // Store previous positions for transition
    root.each(d => {
      d.x0 = d.x0 ?? d.x
      d.y0 = d.y0 ?? d.y
    })

    // Center the tree
    const nodes = root.descendants()
    const links = root.links()

    // Compute bounds
    let minX = Infinity, maxX = -Infinity, minY = Infinity, maxY = -Infinity
    nodes.forEach(d => {
      minX = Math.min(minX, d.x)
      maxX = Math.max(maxX, d.x)
      minY = Math.min(minY, d.y)
      maxY = Math.max(maxY, d.y)
    })

    const treeWidth = maxX - minX + NODE_W * 2
    const treeHeight = maxY - minY + NODE_H * 2
    const offsetX = width / 2 - (minX + maxX) / 2
    const offsetY = 40

    // ---- LINKS (curved connectors) ----
    const linkGen = d3.linkVertical()
      .x(d => d.x + offsetX)
      .y(d => d.y + offsetY)

    const link = this._g.selectAll(".tree-link")
      .data(links, d => `${d.source.data.id}-${d.target.data.id}`)

    // Enter
    const linkEnter = link.enter()
      .append("path")
      .attr("class", "tree-link")
      .attr("fill", "none")
      .attr("stroke", d => {
        const status = d.target.data.status || "idle"
        return status === "error" ? STATUS_COLORS.error
             : status === "running" || status === "active" ? PALETTE.accent
             : PALETTE.border
      })
      .attr("stroke-width", 1.5)
      .attr("stroke-opacity", 0.6)
      .attr("marker-end", d => {
        const status = d.target.data.status || "idle"
        return status === "error" ? "url(#arrow-error)"
             : status === "running" || status === "active" ? "url(#arrow-active)"
             : "url(#arrow-default)"
      })
      .attr("d", d => {
        const o = { x: d.source.x0 + offsetX, y: d.source.y0 + offsetY }
        return linkGen({ source: o, target: o })
      })

    // Update + Enter transition
    linkEnter.merge(link)
      .transition()
      .duration(TRANSITION_MS)
      .ease(d3.easeCubicInOut)
      .attr("d", d => linkGen(d))

    // Exit
    link.exit()
      .transition()
      .duration(TRANSITION_MS)
      .attr("d", d => {
        const o = { x: d.source.x + offsetX, y: d.source.y + offsetY }
        return linkGen({ source: o, target: o })
      })
      .remove()

    // ---- NODES ----
    const node = this._g.selectAll(".tree-node")
      .data(nodes, d => d.data.id || d.data.name)

    // Enter
    const nodeEnter = node.enter()
      .append("g")
      .attr("class", "tree-node")
      .attr("transform", d => {
        const px = d.parent ? d.parent.x0 + offsetX : d.x + offsetX
        const py = d.parent ? d.parent.y0 + offsetY : d.y + offsetY
        return `translate(${px},${py})`
      })
      .attr("cursor", d => (d.data.children || d.data._children) ? "pointer" : "default")
      .attr("tabindex", 0)
      .on("click", (event, d) => {
        event.stopPropagation()
        if (d.data.children || d.data._children) {
          this._toggleNode(d)
        } else if (d.data.type === "agent") {
          this.pushEvent("select_agent", { agent_id: d.data.id })
        }
      })
      .on("mouseenter", (event, d) => this._showTooltip(event, d))
      .on("mouseleave", () => this._hideTooltip())
      .on("keydown", (event, d) => {
        if (event.key === "Enter" || event.key === " ") {
          event.preventDefault()
          if (d.data.children || d.data._children) {
            this._toggleNode(d)
          }
        }
      })

    // Card background
    nodeEnter.append("rect")
      .attr("x", -NODE_W / 2)
      .attr("y", -NODE_H / 2)
      .attr("width", NODE_W)
      .attr("height", NODE_H)
      .attr("rx", NODE_R)
      .attr("fill", PALETTE.bgCard)
      .attr("stroke", d => statusColor(d.data.status || "idle"))
      .attr("stroke-width", 1.5)
      .attr("opacity", 0)

    // Icon
    nodeEnter.append("text")
      .attr("class", "node-icon")
      .attr("x", -NODE_W / 2 + 12)
      .attr("y", 1)
      .attr("text-anchor", "middle")
      .attr("dominant-baseline", "central")
      .attr("fill", d => statusColor(d.data.status || "idle"))
      .attr("font-size", "14px")
      .text(d => nodeIcon(d.data.type))

    // Label
    nodeEnter.append("text")
      .attr("class", "node-label")
      .attr("x", -NODE_W / 2 + 24)
      .attr("y", -4)
      .attr("fill", PALETTE.text)
      .attr("font-size", "11px")
      .attr("font-family", "monospace")
      .text(d => {
        const name = d.data.name || "?"
        return name.length > 16 ? name.substring(0, 14) + ".." : name
      })

    // Sub-label (agent count or status)
    nodeEnter.append("text")
      .attr("class", "node-sub")
      .attr("x", -NODE_W / 2 + 24)
      .attr("y", 10)
      .attr("fill", PALETTE.textDim)
      .attr("font-size", "9px")
      .attr("font-family", "monospace")
      .text(d => {
        if (d.data.agent_count) return `${d.data.agent_count} agents`
        if (d.data.type === "agent") return d.data.status || "idle"
        return ""
      })

    // Collapse indicator (+ / -)
    nodeEnter.append("text")
      .attr("class", "collapse-indicator")
      .attr("x", NODE_W / 2 - 14)
      .attr("y", 1)
      .attr("text-anchor", "middle")
      .attr("dominant-baseline", "central")
      .attr("fill", PALETTE.accent)
      .attr("font-size", "14px")
      .attr("font-weight", "bold")
      .text(d => {
        if (d.data._children) return "+"
        if (d.data.children && d.data.children.length > 0 && d.data.type !== "agent") return "\u2212"
        return ""
      })

    // Member count badge (for collapsed nodes)
    nodeEnter.filter(d => d.data._children)
      .append("circle")
      .attr("class", "count-badge")
      .attr("cx", NODE_W / 2 - 4)
      .attr("cy", -NODE_H / 2 - 4)
      .attr("r", 10)
      .attr("fill", PALETTE.accent)
      .attr("stroke", PALETTE.bgCard)
      .attr("stroke-width", 2)

    nodeEnter.filter(d => d.data._children)
      .append("text")
      .attr("class", "count-label")
      .attr("x", NODE_W / 2 - 4)
      .attr("y", -NODE_H / 2 - 4)
      .attr("text-anchor", "middle")
      .attr("dominant-baseline", "central")
      .attr("fill", PALETTE.bg)
      .attr("font-size", "9px")
      .attr("font-weight", "bold")
      .text(d => {
        const count = d.data._children ? d.data._children.length : 0
        return count > 99 ? "99+" : count
      })

    // Update + Enter merged
    const nodeUpdate = nodeEnter.merge(node)

    nodeUpdate.transition()
      .duration(TRANSITION_MS)
      .ease(d3.easeCubicInOut)
      .attr("transform", d => `translate(${d.x + offsetX},${d.y + offsetY})`)

    nodeUpdate.select("rect")
      .transition()
      .duration(TRANSITION_MS)
      .attr("opacity", 1)
      .attr("stroke", d => statusColor(d.data.status || "idle"))

    nodeUpdate.select(".collapse-indicator")
      .text(d => {
        if (d.data._children) return "+"
        if (d.data.children && d.data.children.length > 0 && d.data.type !== "agent") return "\u2212"
        return ""
      })

    // Exit
    const nodeExit = node.exit()
      .transition()
      .duration(TRANSITION_MS)
      .attr("transform", d => {
        const px = d.parent ? d.parent.x + offsetX : d.x + offsetX
        const py = d.parent ? d.parent.y + offsetY : d.y + offsetY
        return `translate(${px},${py})`
      })
      .remove()

    nodeExit.select("rect").attr("opacity", 0)

    // Store positions for next transition
    nodes.forEach(d => {
      d.x0 = d.x
      d.y0 = d.y
    })
  },

  _showTooltip(event, d) {
    const data = d.data
    let html = `<strong>${data.name}</strong><br>`
    html += `<span style="color:${statusColor(data.status)}">${data.status || "idle"}</span>`
    if (data.type) html += ` | ${data.type}`
    if (data.agent_count) html += `<br>${data.agent_count} agents`
    if (data._children) html += `<br><em>Click to expand (${data._children.length} children)</em>`
    if (data.data?.namespace) html += `<br>NS: ${data.data.namespace}`

    this._tooltip
      .style("display", "block")
      .html(html)
      .style("left", `${event.offsetX + 15}px`)
      .style("top", `${event.offsetY - 10}px`)
  },

  _hideTooltip() {
    this._tooltip.style("display", "none")
  },

  _handleKey(e) {
    const focused = this._g.select(".tree-node:focus")
    if (!focused.empty()) {
      const d = focused.datum()
      if (e.key === "Enter" || e.key === " ") {
        e.preventDefault()
        if (d.data.children || d.data._children) {
          this._toggleNode(d)
        }
      }
    }
  }
}

export default DependencyGraph
