/**
 * SparklineDot — minimal SVG polyline sparkline with an animated trailing dot.
 *
 * Attributes:
 *   data-points   JSON array of numbers, max 60 values (required)
 *                 e.g. data-points="[12,34,28,45,60]"
 *
 * Renders an SVG <polyline> scaled to fill the element's bounding box.
 * The final data point gets a <circle> with a CSS pulse animation.
 * Calls updated() when LiveView patches data-points.
 */
const MAX_POINTS = 60
const PULSE_KEYFRAMES = `
@keyframes sparkline-pulse {
  0%, 100% { opacity: 1; r: 3; }
  50%       { opacity: 0.4; r: 5; }
}
`

const SparklineDot = {
  mounted() {
    this._ensureStyle()
    this._render()
  },

  updated() {
    this._render()
  },

  destroyed() {
    // SVG is inside el — removed automatically
  },

  _parsePoints() {
    try {
      const raw = JSON.parse(this.el.dataset.points || "[]")
      if (!Array.isArray(raw)) return []
      return raw.slice(-MAX_POINTS).map(Number).filter(isFinite)
    } catch (_) {
      return []
    }
  },

  _render() {
    const points = this._parsePoints()

    // Clear previous SVG
    const existing = this.el.querySelector("svg.sparkline-svg")
    if (existing) existing.remove()

    if (points.length < 2) return

    const W = this.el.offsetWidth  || 120
    const H = this.el.offsetHeight || 32

    const min = Math.min(...points)
    const max = Math.max(...points)
    const range = max - min || 1

    const PAD_V = 4  // vertical padding so the dot doesn't clip
    const effectiveH = H - PAD_V * 2

    const coords = points.map((v, i) => {
      const x = (i / (points.length - 1)) * W
      const y = PAD_V + effectiveH - ((v - min) / range) * effectiveH
      return `${x.toFixed(2)},${y.toFixed(2)}`
    })

    const lastX = parseFloat(coords[coords.length - 1])
    const lastY = parseFloat(coords[coords.length - 1].split(",")[1])

    const ns  = "http://www.w3.org/2000/svg"
    const svg = document.createElementNS(ns, "svg")
    svg.setAttribute("width",   W)
    svg.setAttribute("height",  H)
    svg.setAttribute("viewBox", `0 0 ${W} ${H}`)
    svg.setAttribute("class",   "sparkline-svg")
    svg.style.cssText = "display:block;overflow:visible;"

    // Line
    const line = document.createElementNS(ns, "polyline")
    line.setAttribute("points", coords.join(" "))
    line.setAttribute("fill",   "none")
    line.setAttribute("stroke", "var(--apm-accent, #6366f1)")
    line.setAttribute("stroke-width", "1.5")
    line.setAttribute("stroke-linejoin", "round")
    line.setAttribute("stroke-linecap",  "round")
    svg.appendChild(line)

    // Trailing pulse dot — use the last parsed coordinate pair
    const [dotX, dotY] = coords[coords.length - 1].split(",").map(parseFloat)

    const dot = document.createElementNS(ns, "circle")
    dot.setAttribute("cx", dotX)
    dot.setAttribute("cy", dotY)
    dot.setAttribute("r",  "3")
    dot.setAttribute("fill", "var(--apm-accent, #6366f1)")
    dot.style.animation = "sparkline-pulse 1.4s ease-in-out infinite"
    svg.appendChild(dot)

    this.el.appendChild(svg)
  },

  _ensureStyle() {
    if (document.getElementById("sparkline-dot-style")) return
    const style = document.createElement("style")
    style.id = "sparkline-dot-style"
    style.textContent = PULSE_KEYFRAMES
    document.head.appendChild(style)
  }
}

export default SparklineDot
