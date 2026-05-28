/**
 * ProvenanceLineageGraph LiveView JS Hook
 *
 * D3.js directed force graph for W3C PROV wasDerivedFrom lineage visualization.
 * Reads `data-nodes` and `data-edges` attributes (JSON arrays) from the element,
 * renders a force-simulation DAG with labeled nodes and directed edges.
 *
 * Node JSON shape: { id: string, label?: string, agent_id?: string }
 * Edge JSON shape: { source: string, target: string, label?: string }
 *
 * D3 is lazy-loaded from CDN (same pattern as FormationGraph).
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

function parseData(el) {
  let nodes = [], edges = []
  try { nodes = JSON.parse(el.dataset.nodes || "[]") } catch (e) { nodes = [] }
  try { edges = JSON.parse(el.dataset.edges || "[]") } catch (e) { edges = [] }
  return { nodes, edges }
}

function drawGraph(el, d3) {
  const { nodes, edges } = parseData(el)
  if (!nodes.length) return

  // Clear previous render
  d3.select(el).selectAll("*").remove()

  const width = el.clientWidth || 600
  const height = el.clientHeight || 420

  const svg = d3.select(el)
    .append("svg")
    .attr("width", "100%")
    .attr("height", "100%")
    .attr("viewBox", `0 0 ${width} ${height}`)
    .style("overflow", "hidden")

  // Arrow marker for directed edges
  svg.append("defs").append("marker")
    .attr("id", "prov-arrow")
    .attr("viewBox", "0 -5 10 10")
    .attr("refX", 20)
    .attr("refY", 0)
    .attr("markerWidth", 6)
    .attr("markerHeight", 6)
    .attr("orient", "auto")
    .append("path")
    .attr("d", "M0,-5L10,0L0,5")
    .attr("fill", "var(--ccem-accent, #6366f1)")

  const g = svg.append("g")

  // Enable zoom/pan
  svg.call(d3.zoom()
    .scaleExtent([0.25, 4])
    .on("zoom", (event) => g.attr("transform", event.transform))
  )

  // Build node/edge data (d3 force mutates nodes in-place)
  const nodeData = nodes.map(n => ({ ...n, id: String(n.id) }))
  const edgeData = edges.map(e => ({ ...e, source: String(e.source), target: String(e.target) }))

  const simulation = d3.forceSimulation(nodeData)
    .force("link", d3.forceLink(edgeData).id(n => n.id).distance(100))
    .force("charge", d3.forceManyBody().strength(-180))
    .force("center", d3.forceCenter(width / 2, height / 2))
    .force("collision", d3.forceCollide(28))

  // Edges
  const link = g.append("g")
    .selectAll("line")
    .data(edgeData)
    .join("line")
    .attr("stroke", "var(--ccem-accent, #6366f1)")
    .attr("stroke-opacity", 0.5)
    .attr("stroke-width", 1.5)
    .attr("marker-end", "url(#prov-arrow)")

  // Edge labels
  const linkLabel = g.append("g")
    .selectAll("text")
    .data(edgeData.filter(e => e.label))
    .join("text")
    .text(e => e.label || "wasDerivedFrom")
    .attr("font-size", 9)
    .attr("fill", "var(--ccem-text-muted, #9ca3af)")
    .attr("text-anchor", "middle")

  // Nodes
  const node = g.append("g")
    .selectAll("circle")
    .data(nodeData)
    .join("circle")
    .attr("r", 14)
    .attr("fill", "var(--ccem-surface-2, #1e1e2e)")
    .attr("stroke", "var(--ccem-accent, #6366f1)")
    .attr("stroke-width", 1.5)
    .call(d3.drag()
      .on("start", (event, d) => {
        if (!event.active) simulation.alphaTarget(0.3).restart()
        d.fx = d.x; d.fy = d.y
      })
      .on("drag", (event, d) => { d.fx = event.x; d.fy = event.y })
      .on("end", (event, d) => {
        if (!event.active) simulation.alphaTarget(0)
        d.fx = null; d.fy = null
      })
    )

  // Node labels
  const nodeLabel = g.append("g")
    .selectAll("text")
    .data(nodeData)
    .join("text")
    .text(n => (n.label || n.id || "").slice(0, 16))
    .attr("font-size", 9)
    .attr("text-anchor", "middle")
    .attr("dy", 22)
    .attr("fill", "var(--ccem-text-secondary, #d1d5db)")

  simulation.on("tick", () => {
    link
      .attr("x1", d => d.source.x)
      .attr("y1", d => d.source.y)
      .attr("x2", d => d.target.x)
      .attr("y2", d => d.target.y)

    linkLabel
      .attr("x", d => ((d.source.x || 0) + (d.target.x || 0)) / 2)
      .attr("y", d => ((d.source.y || 0) + (d.target.y || 0)) / 2)

    node.attr("cx", d => d.x).attr("cy", d => d.y)
    nodeLabel.attr("x", d => d.x).attr("y", d => d.y)
  })
}

const ProvenanceLineageGraph = {
  mounted() {
    ensureD3()
      .then(lib => { d3 = lib; drawGraph(this.el, d3) })
      .catch(err => console.warn("[ProvenanceLineageGraph] D3 load failed:", err))
  },

  updated() {
    if (d3) drawGraph(this.el, d3)
  }
}

export default ProvenanceLineageGraph
