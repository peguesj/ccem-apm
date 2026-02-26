/**
 * SessionTimeline LiveView JS Hook
 *
 * D3 gantt-style horizontal bar chart showing agent activity over time.
 * WCAG compliant with keyboard navigation, tooltips, and ARIA attributes.
 */
import * as d3 from "../../vendor/d3.min.js"

const STATUS_COLORS = {
  active:    "#3fb950",
  completed: "#58a6ff",
  error:     "#f85149",
  idle:      "#8b949e",
  running:   "#3fb950",
  discovered:"#58a6ff",
}

const SessionTimeline = {
  mounted() {
    this.svg = null
    this.entries = []
    this.timeRange = "1h"
    this.cutoff = null
    this.now = null

    this.handleEvent("timeline_data", (data) => {
      this.entries = data.entries || []
      this.timeRange = data.time_range || "1h"
      this.cutoff = data.cutoff
      this.now = data.now
      this.draw()
    })

    this.resizeObserver = new ResizeObserver(() => this.draw())
    this.resizeObserver.observe(this.el)
  },

  destroyed() {
    if (this.resizeObserver) this.resizeObserver.disconnect()
  },

  draw() {
    const container = this.el
    const width = container.clientWidth || 600
    const height = container.clientHeight || 400

    // Clear previous
    d3.select(container).selectAll("svg").remove()
    d3.select(container).selectAll(".timeline-tooltip").remove()

    const margin = { top: 30, right: 20, bottom: 40, left: 140 }
    const innerW = width - margin.left - margin.right
    const innerH = height - margin.top - margin.bottom

    const svg = d3.select(container).append("svg")
      .attr("width", width)
      .attr("height", height)
      .attr("role", "img")
      .attr("aria-labelledby", "timeline-title timeline-desc")

    // Accessible title and description
    const entryCount = this.entries.length
    const activeCount = this.entries.filter(e => e.status === "active" || e.status === "running").length
    const summaryText = entryCount > 0
      ? `${entryCount} agents shown, ${activeCount} currently active, time range ${this.timeRange}`
      : "No agent activity in the selected time range"

    svg.append("title").attr("id", "timeline-title").text("Agent Session Timeline")
    svg.append("desc").attr("id", "timeline-desc").text(summaryText)

    if (this.entries.length === 0) {
      svg.append("text")
        .attr("x", width / 2).attr("y", height / 2)
        .attr("text-anchor", "middle")
        .attr("fill", "#8b949e").attr("opacity", 0.4).attr("font-size", 13)
        .text("No agent activity in this time range")
      return
    }

    // Tooltip
    const tooltip = d3.select(container).append("div")
      .attr("class", "timeline-tooltip absolute hidden bg-base-100 border border-base-300 rounded-lg shadow-xl p-3 text-xs z-50 pointer-events-none max-w-[260px]")
      .style("position", "absolute")

    // Time scale
    const now = this.now ? new Date(this.now) : new Date()
    const cutoff = this.cutoff ? new Date(this.cutoff) : new Date(now.getTime() - 3600000)

    const xScale = d3.scaleTime()
      .domain([cutoff, now])
      .range([0, innerW])

    // Agent names for Y axis
    const agentNames = this.entries.map(e => e.name)
    const barHeight = Math.min(28, Math.max(14, innerH / agentNames.length - 4))

    const yScale = d3.scaleBand()
      .domain(agentNames)
      .range([0, innerH])
      .padding(0.2)

    const g = svg.append("g")
      .attr("transform", `translate(${margin.left},${margin.top})`)

    // X axis
    g.append("g")
      .attr("transform", `translate(0,${innerH})`)
      .call(d3.axisBottom(xScale).ticks(6).tickFormat(d3.timeFormat("%H:%M")))
      .selectAll("text")
      .attr("fill", "#8b949e").attr("font-size", 10)

    g.selectAll(".domain, .tick line").attr("stroke", "#30363d")

    // Y axis
    g.append("g")
      .call(d3.axisLeft(yScale))
      .selectAll("text")
      .attr("fill", "#c9d1d9").attr("font-size", 10)
      .each(function() {
        const text = d3.select(this).text()
        if (text.length > 18) {
          d3.select(this).text(text.substring(0, 16) + "..")
        }
      })

    g.selectAll(".domain, .tick line").attr("stroke", "#30363d")

    // Grid lines
    g.append("g")
      .attr("class", "grid")
      .selectAll("line")
      .data(xScale.ticks(6))
      .enter().append("line")
      .attr("x1", d => xScale(d)).attr("x2", d => xScale(d))
      .attr("y1", 0).attr("y2", innerH)
      .attr("stroke", "#30363d").attr("stroke-width", 0.5).attr("stroke-dasharray", "3 3")

    // Bars
    const bars = g.selectAll(".bar")
      .data(this.entries)
      .enter().append("rect")
      .attr("class", "bar")
      .attr("tabindex", "0")
      .attr("role", "graphics-symbol")
      .attr("aria-label", d => {
        const dur = computeDuration(d.start_time, d.end_time)
        return `${d.name}, status ${d.status}, duration ${dur}`
      })
      .attr("x", d => {
        const start = new Date(d.start_time)
        return Math.max(0, xScale(start))
      })
      .attr("y", d => yScale(d.name))
      .attr("width", d => {
        const start = new Date(d.start_time)
        const end = new Date(d.end_time)
        const x1 = Math.max(0, xScale(start))
        const x2 = Math.min(innerW, xScale(end))
        return Math.max(4, x2 - x1)
      })
      .attr("height", yScale.bandwidth())
      .attr("fill", d => STATUS_COLORS[d.status] || STATUS_COLORS.idle)
      .attr("opacity", 0.8)
      .attr("rx", 3)
      .attr("ry", 3)

    // Hover and keyboard interactions
    const pushEvent = this.pushEvent.bind(this)

    bars
      .on("mouseover", function(event, d) {
        const dur = computeDuration(d.start_time, d.end_time)
        tooltip.classed("hidden", false).html(`
          <div class="font-semibold mb-1">${d.name}</div>
          <div class="space-y-0.5 text-base-content/60">
            <div><span class="text-base-content/40">Status:</span> <span style="color:${STATUS_COLORS[d.status] || '#8b949e'}">${d.status}</span></div>
            <div><span class="text-base-content/40">Duration:</span> ${dur}</div>
            <div><span class="text-base-content/40">Tool calls:</span> ${d.tool_calls || 0}</div>
          </div>
        `)
        const rect = container.getBoundingClientRect()
        tooltip
          .style("left", (event.clientX - rect.left + 14) + "px")
          .style("top", (event.clientY - rect.top - 12) + "px")
        d3.select(this).attr("opacity", 1).attr("stroke", "#fff").attr("stroke-width", 1)
      })
      .on("mousemove", function(event) {
        const rect = container.getBoundingClientRect()
        tooltip
          .style("left", (event.clientX - rect.left + 14) + "px")
          .style("top", (event.clientY - rect.top - 12) + "px")
      })
      .on("mouseout", function() {
        tooltip.classed("hidden", true)
        d3.select(this).attr("opacity", 0.8).attr("stroke", null)
      })

    // Keyboard navigation
    bars.on("keydown", function(event, d) {
      if (event.key === "Enter" || event.key === " ") {
        event.preventDefault()
        // Could push select event
      }
      const allBars = bars.nodes()
      const idx = allBars.indexOf(this)
      let target = -1
      if (event.key === "ArrowDown" || event.key === "ArrowRight") {
        event.preventDefault()
        target = (idx + 1) % allBars.length
      } else if (event.key === "ArrowUp" || event.key === "ArrowLeft") {
        event.preventDefault()
        target = (idx - 1 + allBars.length) % allBars.length
      }
      if (target >= 0) allBars[target].focus()
    })

    // Legend
    const legendData = [
      { label: "Active", color: STATUS_COLORS.active },
      { label: "Completed", color: STATUS_COLORS.completed },
      { label: "Error", color: STATUS_COLORS.error },
      { label: "Idle", color: STATUS_COLORS.idle },
    ]

    const legend = svg.append("g")
      .attr("transform", `translate(${margin.left}, 8)`)

    legendData.forEach((item, i) => {
      const lg = legend.append("g").attr("transform", `translate(${i * 90}, 0)`)
      lg.append("rect").attr("width", 10).attr("height", 10).attr("rx", 2).attr("fill", item.color).attr("opacity", 0.8)
      lg.append("text").attr("x", 14).attr("y", 9).attr("fill", "#8b949e").attr("font-size", 10).text(item.label)
    })
  }
}

function computeDuration(startStr, endStr) {
  const start = new Date(startStr)
  const end = new Date(endStr)
  const diffMs = end - start
  if (diffMs < 0) return "0s"
  const secs = Math.floor(diffMs / 1000)
  if (secs < 60) return `${secs}s`
  if (secs < 3600) return `${Math.floor(secs / 60)}m ${secs % 60}s`
  const hrs = Math.floor(secs / 3600)
  const mins = Math.floor((secs % 3600) / 60)
  return `${hrs}h ${mins}m`
}

export default SessionTimeline
