/**
 * MermaidHook — Client-side diagram rendering for Showcase v2
 *
 * Renders Mermaid (.mmd) and raw SVG diagrams in-browser with
 * Lottie-style SVG animations (progressive reveal, fade-in).
 *
 * Attributes:
 *   data-diagram-type: "mermaid" | "plantuml" | "svg"
 *   data-diagram-content: raw diagram source (mermaid syntax or SVG markup)
 *
 * For Mermaid: uses mermaid.js CDN (lazy-loaded on first use)
 * For SVG: injects directly with anime.js progressive reveal
 * For PlantUML: renders as code block (server-side rendering TBD)
 */

let mermaidLoaded = false;
let mermaidPromise = null;

function loadMermaid() {
  if (mermaidLoaded) return Promise.resolve();
  if (mermaidPromise) return mermaidPromise;

  mermaidPromise = new Promise((resolve, reject) => {
    const script = document.createElement("script");
    script.src = "https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js";
    script.onload = () => {
      window.mermaid.initialize({
        startOnLoad: false,
        theme: "dark",
        themeVariables: {
          primaryColor: "#6366f1",
          primaryTextColor: "#e2e8f0",
          primaryBorderColor: "#818cf8",
          lineColor: "#475569",
          secondaryColor: "#1e293b",
          tertiaryColor: "#0f172a",
          background: "#0a0a0f",
          mainBkg: "#1e1e2e",
          nodeBkg: "#1e293b",
          nodeBorder: "#475569",
          clusterBkg: "#0f172a",
          clusterBorder: "#334155",
          titleColor: "#e2e8f0",
          edgeLabelBackground: "#1e293b",
          fontFamily: "'Fira Code', 'JetBrains Mono', monospace",
        },
        securityLevel: "loose",
        flowchart: { curve: "basis", padding: 15 },
      });
      mermaidLoaded = true;
      resolve();
    };
    script.onerror = reject;
    document.head.appendChild(script);
  });

  return mermaidPromise;
}

function animateSvg(container) {
  // Progressive reveal animation for SVG elements
  const svgEl = container.querySelector("svg");
  if (!svgEl) return;

  // Set initial state
  svgEl.style.opacity = "0";
  svgEl.style.transform = "translateY(8px)";
  svgEl.style.transition = "opacity 0.4s ease, transform 0.4s ease";

  // Trigger animation
  requestAnimationFrame(() => {
    svgEl.style.opacity = "1";
    svgEl.style.transform = "translateY(0)";
  });

  // Animate individual nodes with stagger
  const nodes = svgEl.querySelectorAll(".node, .cluster, .edgePath, rect, circle, polygon");
  nodes.forEach((node, i) => {
    node.style.opacity = "0";
    node.style.transition = `opacity 0.3s ease ${i * 40}ms, transform 0.3s ease ${i * 40}ms`;
    node.style.transform = "scale(0.95)";

    requestAnimationFrame(() => {
      requestAnimationFrame(() => {
        node.style.opacity = "1";
        node.style.transform = "scale(1)";
      });
    });
  });

  // Animate edges with dash-march effect
  const edges = svgEl.querySelectorAll("path.flowchart-link, .edgePath path, line");
  edges.forEach((edge) => {
    const length = edge.getTotalLength ? edge.getTotalLength() : 100;
    edge.style.strokeDasharray = length;
    edge.style.strokeDashoffset = length;
    edge.style.transition = "stroke-dashoffset 0.8s ease 0.3s";

    requestAnimationFrame(() => {
      edge.style.strokeDashoffset = "0";
    });
  });
}

async function renderMermaid(container, content) {
  await loadMermaid();

  const id = `mermaid-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;

  try {
    const { svg } = await window.mermaid.render(id, content);
    container.innerHTML = svg;
    animateSvg(container);
  } catch (err) {
    // Fallback: show as code block
    container.innerHTML = `
      <div class="bg-base-300 rounded p-3 overflow-auto">
        <div class="text-error text-xs mb-2">Render error: ${err.message}</div>
        <pre class="text-xs font-mono text-base-content/70 whitespace-pre-wrap">${escapeHtml(content)}</pre>
      </div>
    `;
  }
}

function renderSvg(container, content) {
  container.innerHTML = content;
  animateSvg(container);
}

function renderPlantUml(container, content) {
  // PlantUML requires server-side rendering; show as formatted code
  container.innerHTML = `
    <div class="bg-base-300 rounded p-3 overflow-auto">
      <div class="badge badge-xs badge-warning mb-2">PlantUML — server rendering pending</div>
      <pre class="text-xs font-mono text-base-content/70 whitespace-pre-wrap">${escapeHtml(content)}</pre>
    </div>
  `;
}

function escapeHtml(str) {
  const div = document.createElement("div");
  div.textContent = str;
  return div.innerHTML;
}

const MermaidHook = {
  mounted() {
    this.render();
  },

  updated() {
    this.render();
  },

  render() {
    const type = this.el.dataset.diagramType;
    const content = this.el.dataset.diagramContent;

    if (!content) return;

    switch (type) {
      case "mermaid":
        renderMermaid(this.el, content);
        break;
      case "svg":
        renderSvg(this.el, content);
        break;
      case "plantuml":
        renderPlantUml(this.el, content);
        break;
      default:
        this.el.innerHTML = `<pre class="text-xs font-mono">${escapeHtml(content)}</pre>`;
    }
  },
};

export default MermaidHook;
