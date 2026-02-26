import * as d3 from "../../vendor/d3.min.js"

// Phase colors matching the React/xyflow original
const PHASE_COLORS = {
  setup:    { bg: "#f0f7ff", border: "#4a90d9", text: "#2b6cb0" },
  loop:     { bg: "#f5f5f5", border: "#666666", text: "#333333" },
  decision: { bg: "#fff8e6", border: "#c9a227", text: "#8b6914" },
  done:     { bg: "#f0fff4", border: "#38a169", text: "#276749" }
}

// Node dimensions
const NODE_WIDTH = 220
const NODE_HEIGHT = 64

// Layout positions (top-to-bottom flowchart)
const POSITIONS = {
  "1":  { x: 120, y: 40 },
  "2":  { x: 120, y: 140 },
  "3":  { x: 120, y: 240 },
  "4":  { x: 120, y: 380 },
  "5":  { x: 420, y: 320 },
  "6":  { x: 680, y: 420 },
  "7":  { x: 420, y: 500 },
  "8":  { x: 180, y: 580 },
  "9":  { x: 120, y: 700 },
  "10": { x: 350, y: 840 }
}

const RalphFlowchart = {
  mounted() {
    this.svg = null
    this.steps = []
    this.edges = []

    this.handleEvent("flowchart_data", (data) => {
      this.steps = data.steps || []
      this.edges = data.edges || []
      this.render()
    })

    // Re-render on resize
    this.resizeObserver = new ResizeObserver(() => this.render())
    this.resizeObserver.observe(this.el)
  },

  destroyed() {
    if (this.resizeObserver) {
      this.resizeObserver.disconnect()
    }
  },

  render() {
    const container = this.el
    const width = container.clientWidth || 900
    const height = container.clientHeight || 700

    // Clear previous
    d3.select(container).selectAll("svg").remove()

    if (this.steps.length === 0) {
      d3.select(container)
        .append("div")
        .attr("class", "flex items-center justify-center h-full text-base-content/30 text-sm")
        .text("No flowchart data")
      return
    }

    const svg = d3.select(container)
      .append("svg")
      .attr("width", width)
      .attr("height", height)
      .attr("viewBox", `0 0 900 920`)
      .attr("preserveAspectRatio", "xMidYMid meet")

    // Defs: arrow markers and glow filter
    const defs = svg.append("defs")

    defs.append("marker")
      .attr("id", "arrowhead")
      .attr("viewBox", "0 0 10 10")
      .attr("refX", 9)
      .attr("refY", 5)
      .attr("markerWidth", 8)
      .attr("markerHeight", 8)
      .attr("orient", "auto-start-reverse")
      .append("path")
      .attr("d", "M 0 0 L 10 5 L 0 10 z")
      .attr("fill", "#444")

    // Glow filter for active step
    const glow = defs.append("filter")
      .attr("id", "glow")
      .attr("x", "-50%")
      .attr("y", "-50%")
      .attr("width", "200%")
      .attr("height", "200%")

    glow.append("feGaussianBlur")
      .attr("stdDeviation", "4")
      .attr("result", "blur")

    glow.append("feMerge")
      .selectAll("feMergeNode")
      .data(["blur", "SourceGraphic"])
      .join("feMergeNode")
      .attr("in", d => d)

    // Animated dash pattern for edges
    defs.append("style")
      .text(`
        @keyframes dash {
          to { stroke-dashoffset: -20; }
        }
        .animated-edge {
          stroke-dasharray: 8 4;
          animation: dash 1s linear infinite;
        }
      `)

    // Build lookup for step positions
    const stepMap = {}
    this.steps.forEach(s => { stepMap[s.id] = s })

    // --- Draw edges ---
    const edgeGroup = svg.append("g").attr("class", "edges")

    this.edges.forEach(edge => {
      const src = stepMap[edge.source]
      const tgt = stepMap[edge.target]
      if (!src || !tgt || !src.visible || !tgt.visible) return

      const srcPos = POSITIONS[edge.source]
      const tgtPos = POSITIONS[edge.target]
      if (!srcPos || !tgtPos) return

      // Calculate edge endpoints from node centers
      const sx = srcPos.x + NODE_WIDTH / 2
      const sy = srcPos.y + NODE_HEIGHT / 2
      const tx = tgtPos.x + NODE_WIDTH / 2
      const ty = tgtPos.y + NODE_HEIGHT / 2

      // Compute connection points on node boundaries
      const points = computeEdgePoints(srcPos, tgtPos)

      // Draw curved path
      const pathData = computePath(points.sx, points.sy, points.tx, points.ty)

      edgeGroup.append("path")
        .attr("d", pathData)
        .attr("fill", "none")
        .attr("stroke", "#555")
        .attr("stroke-width", 2)
        .attr("class", "animated-edge")
        .attr("marker-end", "url(#arrowhead)")
        .style("opacity", 0)
        .transition()
        .duration(400)
        .style("opacity", 1)

      // Edge label (Yes/No)
      if (edge.label) {
        const mx = (points.sx + points.tx) / 2
        const my = (points.sy + points.ty) / 2

        edgeGroup.append("rect")
          .attr("x", mx - 16)
          .attr("y", my - 10)
          .attr("width", 32)
          .attr("height", 20)
          .attr("rx", 4)
          .attr("fill", "#1d232a")
          .attr("stroke", "#555")
          .attr("stroke-width", 1)

        edgeGroup.append("text")
          .attr("x", mx)
          .attr("y", my + 4)
          .attr("text-anchor", "middle")
          .attr("font-size", "12px")
          .attr("font-weight", "600")
          .attr("fill", "#ddd")
          .text(edge.label)
      }
    })

    // --- Draw nodes ---
    const nodeGroup = svg.append("g").attr("class", "nodes")

    this.steps.forEach(step => {
      if (!step.visible) return

      const pos = POSITIONS[step.id]
      if (!pos) return

      const colors = PHASE_COLORS[step.phase] || PHASE_COLORS.loop
      const isActive = this.steps.filter(s => s.visible).pop()?.id === step.id

      const g = nodeGroup.append("g")
        .attr("transform", `translate(${pos.x}, ${pos.y})`)
        .attr("cursor", "pointer")
        .style("opacity", 0)
        .on("click", () => {
          this.pushEvent("select_step", { "step-id": step.id })
        })

      // Node background rect
      const rect = g.append("rect")
        .attr("width", NODE_WIDTH)
        .attr("height", NODE_HEIGHT)
        .attr("rx", 8)
        .attr("fill", colors.bg)
        .attr("stroke", colors.border)
        .attr("stroke-width", isActive ? 3 : 2)

      if (isActive) {
        rect.attr("filter", "url(#glow)")
      }

      // Phase indicator dot
      g.append("circle")
        .attr("cx", 16)
        .attr("cy", NODE_HEIGHT / 2)
        .attr("r", 5)
        .attr("fill", colors.border)

      // Title text
      g.append("text")
        .attr("x", 30)
        .attr("y", NODE_HEIGHT / 2 - 6)
        .attr("font-size", "13px")
        .attr("font-weight", "bold")
        .attr("fill", colors.text)
        .text(step.label)

      // Description text
      g.append("text")
        .attr("x", 30)
        .attr("y", NODE_HEIGHT / 2 + 12)
        .attr("font-size", "11px")
        .attr("fill", colors.text)
        .attr("opacity", 0.6)
        .text(step.description)

      // Step number badge
      g.append("circle")
        .attr("cx", NODE_WIDTH - 16)
        .attr("cy", 16)
        .attr("r", 10)
        .attr("fill", colors.border)
        .attr("opacity", 0.3)

      g.append("text")
        .attr("x", NODE_WIDTH - 16)
        .attr("y", 20)
        .attr("text-anchor", "middle")
        .attr("font-size", "10px")
        .attr("font-weight", "bold")
        .attr("fill", colors.text)
        .text(step.id)

      // Fade in
      g.transition()
        .duration(500)
        .style("opacity", 1)
    })

    // --- Tooltip ---
    const tooltip = d3.select(container)
      .selectAll(".flowchart-tooltip")
      .data([null])
      .join("div")
      .attr("class", "flowchart-tooltip")
      .style("position", "absolute")
      .style("display", "none")
      .style("background", "#1d232a")
      .style("border", "1px solid #555")
      .style("border-radius", "6px")
      .style("padding", "8px 12px")
      .style("font-size", "12px")
      .style("color", "#ddd")
      .style("pointer-events", "none")
      .style("z-index", "50")
      .style("max-width", "250px")

    nodeGroup.selectAll("g")
      .on("mouseenter", function(event) {
        const idx = d3.select(this).datum
        const step = getStepFromNode(this)
        if (!step) return

        tooltip
          .style("display", "block")
          .html(`
            <div style="font-weight:bold;margin-bottom:4px;">${step.label}</div>
            <div style="opacity:0.7">${step.description}</div>
            <div style="margin-top:4px;opacity:0.5;font-size:10px">Phase: ${step.phase} | Step ${step.id}</div>
          `)

        const rect = container.getBoundingClientRect()
        tooltip
          .style("left", (event.clientX - rect.left + 10) + "px")
          .style("top", (event.clientY - rect.top - 10) + "px")
      })
      .on("mousemove", function(event) {
        const rect = container.getBoundingClientRect()
        tooltip
          .style("left", (event.clientX - rect.left + 10) + "px")
          .style("top", (event.clientY - rect.top - 10) + "px")
      })
      .on("mouseleave", function() {
        tooltip.style("display", "none")
      })

    // Store step data on nodes for tooltip lookup
    const visibleSteps = this.steps.filter(s => s.visible)
    nodeGroup.selectAll("g").each(function(d, i) {
      d3.select(this).datum(visibleSteps[i])
    })

    function getStepFromNode(node) {
      return d3.select(node).datum()
    }
  }
}

// Compute edge connection points on node boundaries
function computeEdgePoints(srcPos, tgtPos) {
  const srcCx = srcPos.x + NODE_WIDTH / 2
  const srcCy = srcPos.y + NODE_HEIGHT / 2
  const tgtCx = tgtPos.x + NODE_WIDTH / 2
  const tgtCy = tgtPos.y + NODE_HEIGHT / 2

  let sx, sy, tx, ty

  // Source point: exit from closest edge
  const dx = tgtCx - srcCx
  const dy = tgtCy - srcCy

  if (Math.abs(dx) > Math.abs(dy)) {
    // Horizontal dominant
    if (dx > 0) {
      sx = srcPos.x + NODE_WIDTH
      sy = srcCy
      tx = tgtPos.x
      ty = tgtCy
    } else {
      sx = srcPos.x
      sy = srcCy
      tx = tgtPos.x + NODE_WIDTH
      ty = tgtCy
    }
  } else {
    // Vertical dominant
    if (dy > 0) {
      sx = srcCx
      sy = srcPos.y + NODE_HEIGHT
      tx = tgtCx
      ty = tgtPos.y
    } else {
      sx = srcCx
      sy = srcPos.y
      tx = tgtCx
      ty = tgtPos.y + NODE_HEIGHT
    }
  }

  return { sx, sy, tx, ty }
}

// Compute a smooth cubic bezier path between two points
function computePath(sx, sy, tx, ty) {
  const dx = tx - sx
  const dy = ty - sy

  // Use bezier control points for smooth curves
  let cx1, cy1, cx2, cy2

  if (Math.abs(dx) > Math.abs(dy)) {
    // Horizontal-dominant: curve horizontally
    cx1 = sx + dx * 0.5
    cy1 = sy
    cx2 = tx - dx * 0.5
    cy2 = ty
  } else {
    // Vertical-dominant: curve vertically
    cx1 = sx
    cy1 = sy + dy * 0.5
    cx2 = tx
    cy2 = ty - dy * 0.5
  }

  return `M ${sx} ${sy} C ${cx1} ${cy1}, ${cx2} ${cy2}, ${tx} ${ty}`
}

export default RalphFlowchart
