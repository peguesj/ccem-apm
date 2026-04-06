/**
 * ArchitectureGraph LiveView JS Hook
 *
 * Railway-inspired glassmorphic graph for Diligent architecture visualization.
 * Fleet → Formation → Squadron → Swarm → Agent hierarchy with:
 *   - Level-based node colors and shapes
 *   - Glassmorphic nodes with backdrop blur
 *   - Animated state transitions (pulse for active, glow for fleet/formation)
 *   - Collapsible subtrees
 *   - Zoom/pan via d3.zoom()
 *   - Click to drill into node details
 *
 * Events:
 *   - "architecture:data" — { tree, config } from LiveView
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

// Railway palette
const PALETTE = {
  bg: "#0f172a",
  grid: "#1a2332",
  border: "#1e293b",
  text: "#e2e8f0",
  textDim: "#94a3b8",
  textMuted: "#475569",
  connector: "#334155",
  connectorActive: "#3b82f6",
}

// Level configs (from Diligent architecture)
const LEVEL_DEFAULTS = {
  fleet:     { color: "#e879f9", shape: "hexagon",      size: 28, glow: true },
  formation: { color: "#3b82f6", shape: "rounded_rect", size: 22, glow: true },
  squadron:  { color: "#06b6d4", shape: "rounded_rect", size: 18, glow: false },
  swarm:     { color: "#22c55e", shape: "circle",       size: 14, glow: false },
  agent:     { color: "#f97316", shape: "circle",       size: 10, glow: false },
}

const STATUS_COLORS = {
  active:    "#22c55e",
  working:   "#22c55e",
  idle:      "#6b7280",
  error:     "#ef4444",
  completed: "#3b82f6",
}

function getLevelConfig(level, serverConfig) {
  if (serverConfig && serverConfig.levels) {
    const found = serverConfig.levels.find(l => l.name === level)
    if (found) return found
  }
  return LEVEL_DEFAULTS[level] || LEVEL_DEFAULTS.agent
}

const ArchitectureGraph = {
  async mounted() {
    await ensureD3()
    this._container = d3.select(this.el)
    this._treeData = null
    this._config = null
    this._collapsed = new Set()
    this._tooltip = null
    this._svg = null

    this.handleEvent("architecture:data", (data) => {
      this._treeData = data.tree
      this._config = data.config
      this._render()
    })
  },

  destroyed() {
    if (this._tooltip) this._tooltip.remove()
    if (this._svg) this._svg.remove()
  },

  _render() {
    const data = this._treeData
    if (!data) return this._renderEmpty()

    const rect = this.el.getBoundingClientRect()
    const W = Math.max(rect.width || 900, 500)
    const H = Math.max(rect.height || 600, 400)

    // Clear
    this._container.selectAll("*").remove()

    // SVG
    const svg = this._container.append("svg")
      .attr("width", "100%")
      .attr("height", "100%")
      .attr("viewBox", `0 0 ${W} ${H}`)
      .style("background", PALETTE.bg)
    this._svg = svg

    // Radial dot grid (Railway aesthetic)
    const defs = svg.append("defs")
    const pattern = defs.append("pattern")
      .attr("id", "dot-grid")
      .attr("width", 20).attr("height", 20)
      .attr("patternUnits", "userSpaceOnUse")
    pattern.append("circle")
      .attr("cx", 10).attr("cy", 10).attr("r", 0.5)
      .attr("fill", PALETTE.grid)

    svg.append("rect")
      .attr("width", W).attr("height", H)
      .attr("fill", "url(#dot-grid)")

    // Glassmorphic glow filter
    const filter = defs.append("filter").attr("id", "glow")
    filter.append("feGaussianBlur").attr("stdDeviation", "4").attr("result", "blur")
    filter.append("feMerge")
      .selectAll("feMergeNode")
      .data(["blur", "SourceGraphic"])
      .join("feMergeNode")
      .attr("in", d => d)

    // Tooltip
    this._tooltip = this._container.append("div")
      .style("position", "absolute")
      .style("pointer-events", "none")
      .style("opacity", 0)
      .style("background", "rgba(15,23,42,0.92)")
      .style("backdrop-filter", "blur(12px)")
      .style("border", `1px solid ${PALETTE.border}`)
      .style("border-radius", "10px")
      .style("padding", "10px 14px")
      .style("font-size", "11px")
      .style("color", PALETTE.text)
      .style("font-family", "ui-monospace, monospace")
      .style("z-index", "1000")
      .style("max-width", "280px")
      .style("box-shadow", "0 8px 32px rgba(0,0,0,0.4)")

    // Zoom
    const g = svg.append("g")
    svg.call(d3.zoom()
      .scaleExtent([0.2, 5])
      .on("zoom", (event) => g.attr("transform", event.transform))
    )

    // Build d3 hierarchy
    const root = d3.hierarchy(data, d => {
      if (this._collapsed.has(d.id)) return null
      return d.children
    })

    // Tree layout
    const treeLayout = d3.tree()
      .size([W - 120, H - 120])
      .separation((a, b) => a.parent === b.parent ? 1.2 : 2)

    treeLayout(root)

    // Center offset
    const offsetX = 60
    const offsetY = 60

    // Cubic bezier connectors
    g.selectAll("path.link")
      .data(root.links())
      .join("path")
      .attr("class", "link")
      .attr("d", d => {
        const sx = d.source.x + offsetX
        const sy = d.source.y + offsetY
        const tx = d.target.x + offsetX
        const ty = d.target.y + offsetY
        const my = (sy + ty) / 2
        return `M${sx},${sy} C${sx},${my} ${tx},${my} ${tx},${ty}`
      })
      .attr("fill", "none")
      .attr("stroke", d => {
        const status = d.target.data.status
        return status === "active" ? PALETTE.connectorActive : PALETTE.connector
      })
      .attr("stroke-width", 1.5)
      .attr("stroke-opacity", 0.6)

    // Nodes
    const self = this
    const nodes = g.selectAll("g.node")
      .data(root.descendants())
      .join("g")
      .attr("class", "node")
      .attr("transform", d => `translate(${d.x + offsetX},${d.y + offsetY})`)
      .attr("cursor", "pointer")
      .on("click", (_event, d) => {
        if (d.data.children && d.data.children.length > 0) {
          if (self._collapsed.has(d.data.id)) {
            self._collapsed.delete(d.data.id)
          } else {
            self._collapsed.add(d.data.id)
          }
          self._render()
        }
      })

    // Draw node shapes
    nodes.each(function(d) {
      const el = d3.select(this)
      const level = (d.data.level || "agent").toLowerCase()
      const config = getLevelConfig(level, self._config)
      const color = config.color || "#6b7280"
      const size = config.size || 10

      // Glassmorphic background
      if (config.shape === "rounded_rect") {
        el.append("rect")
          .attr("x", -size * 1.5)
          .attr("y", -size * 0.8)
          .attr("width", size * 3)
          .attr("height", size * 1.6)
          .attr("rx", 6)
          .attr("fill", color)
          .attr("fill-opacity", 0.12)
          .attr("stroke", color)
          .attr("stroke-width", 1.5)
          .attr("stroke-opacity", 0.6)
          .attr("filter", config.glow ? "url(#glow)" : null)
      } else if (config.shape === "hexagon") {
        const r = size
        const hex = d3.range(6).map(i => {
          const angle = (Math.PI / 3) * i - Math.PI / 6
          return [r * Math.cos(angle), r * Math.sin(angle)]
        })
        el.append("polygon")
          .attr("points", hex.map(p => p.join(",")).join(" "))
          .attr("fill", color)
          .attr("fill-opacity", 0.15)
          .attr("stroke", color)
          .attr("stroke-width", 2)
          .attr("filter", config.glow ? "url(#glow)" : null)
      } else {
        el.append("circle")
          .attr("r", size)
          .attr("fill", color)
          .attr("fill-opacity", 0.15)
          .attr("stroke", color)
          .attr("stroke-width", 1.5)
      }

      // Status indicator
      const statusColor = STATUS_COLORS[d.data.status] || STATUS_COLORS.idle
      el.append("circle")
        .attr("cx", size * 0.8)
        .attr("cy", -size * 0.6)
        .attr("r", 3)
        .attr("fill", statusColor)

      // Active pulse animation
      if (d.data.status === "active" || d.data.status === "working") {
        el.append("circle")
          .attr("cx", size * 0.8)
          .attr("cy", -size * 0.6)
          .attr("r", 3)
          .attr("fill", "none")
          .attr("stroke", statusColor)
          .attr("stroke-width", 1)
          .attr("opacity", 0.6)
          .append("animate")
          .attr("attributeName", "r")
          .attr("from", 3).attr("to", 8)
          .attr("dur", "1.5s")
          .attr("repeatCount", "indefinite")
          .attr("fill", "freeze")

        el.select("animate + animate").remove()
        el.select("circle:last-of-type")
          .append("animate")
          .attr("attributeName", "opacity")
          .attr("from", 0.6).attr("to", 0)
          .attr("dur", "1.5s")
          .attr("repeatCount", "indefinite")
      }

      // Collapse indicator
      if (d.data.children && d.data.children.length > 0) {
        const collapsed = self._collapsed.has(d.data.id)
        el.append("text")
          .attr("x", -size * 1.5 - 8)
          .attr("y", 4)
          .attr("fill", PALETTE.textMuted)
          .attr("font-size", "10px")
          .text(collapsed ? "▶" : "▼")
      }

      // Label
      el.append("text")
        .attr("y", size + 16)
        .attr("text-anchor", "middle")
        .attr("fill", PALETTE.textDim)
        .attr("font-size", "10px")
        .attr("font-family", "ui-monospace, monospace")
        .text(truncate(d.data.name || d.data.id, 18))

      // Agent count badge
      if (d.data.agent_count > 0 && d.data.level !== "agent") {
        el.append("text")
          .attr("y", size + 28)
          .attr("text-anchor", "middle")
          .attr("fill", PALETTE.textMuted)
          .attr("font-size", "9px")
          .text(`${d.data.agent_count} agents`)
      }
    })

    // Tooltip interactions
    nodes
      .on("mouseenter", (event, d) => {
        const meta = d.data.metadata || {}
        const lines = [
          `<b style="color:${getLevelConfig(d.data.level, self._config).color}">${d.data.level}</b>`,
          `Name: ${d.data.name || d.data.id}`,
          `Status: ${d.data.status}`,
          `Agents: ${d.data.agent_count}`,
          meta.waves ? `Waves: ${meta.waves.join(", ")}` : null,
          meta.types ? `Types: ${meta.types.join(", ")}` : null,
          meta.agent_type ? `Type: ${meta.agent_type}` : null,
          meta.role ? `Role: ${meta.role}` : null,
        ].filter(Boolean).join("<br>")

        self._tooltip
          .html(lines)
          .style("opacity", 1)
          .style("left", `${event.offsetX + 16}px`)
          .style("top", `${event.offsetY - 8}px`)
      })
      .on("mouseleave", () => {
        self._tooltip.style("opacity", 0)
      })

    // Legend
    this._renderLegend(svg, W)
  },

  _renderLegend(svg, W) {
    const legend = svg.append("g")
      .attr("transform", `translate(${W - 150}, 20)`)

    // Glassmorphic legend background
    const levels = Object.entries(LEVEL_DEFAULTS)
    legend.append("rect")
      .attr("x", -12).attr("y", -8)
      .attr("width", 140).attr("height", levels.length * 20 + 16)
      .attr("rx", 8)
      .attr("fill", "rgba(15,23,42,0.8)")
      .attr("stroke", PALETTE.border)

    levels.forEach(([name, config], i) => {
      const g = legend.append("g").attr("transform", `translate(0, ${i * 20})`)
      g.append("circle")
        .attr("r", 4)
        .attr("fill", config.color)
        .attr("fill-opacity", 0.4)
        .attr("stroke", config.color)
      g.append("text")
        .attr("x", 12).attr("y", 4)
        .attr("fill", PALETTE.textDim)
        .attr("font-size", "10px")
        .attr("font-family", "ui-monospace, monospace")
        .text(name.charAt(0).toUpperCase() + name.slice(1))
    })
  },

  _renderEmpty() {
    const rect = this.el.getBoundingClientRect()
    const W = rect.width || 800
    const H = rect.height || 400

    this._container.selectAll("*").remove()
    const svg = this._container.append("svg")
      .attr("width", "100%").attr("height", "100%")
      .attr("viewBox", `0 0 ${W} ${H}`)
      .style("background", PALETTE.bg)

    svg.append("text")
      .attr("x", W / 2).attr("y", H / 2 - 10)
      .attr("text-anchor", "middle")
      .attr("fill", PALETTE.textMuted)
      .attr("font-size", "14px")
      .attr("font-family", "ui-monospace, monospace")
      .text("No architecture data")

    svg.append("text")
      .attr("x", W / 2).attr("y", H / 2 + 14)
      .attr("text-anchor", "middle")
      .attr("fill", "#334155")
      .attr("font-size", "11px")
      .attr("font-family", "ui-monospace, monospace")
      .text("Register agents to build the hierarchy")
  },
}

function truncate(str, maxLen) {
  if (!str) return ""
  return str.length > maxLen ? str.slice(0, maxLen - 1) + "…" : str
}

export default ArchitectureGraph
