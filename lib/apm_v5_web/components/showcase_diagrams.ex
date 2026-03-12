defmodule ApmV5Web.Components.ShowcaseDiagrams do
  @moduledoc """
  Pure SVG diagram components for the Getting Started wizard.

  Renders C4 L2 Container diagrams with anime.js progressive reveal.
  WCAG AA compliant with prefers-reduced-motion support.
  """

  use Phoenix.Component

  @doc """
  C4 L2 Container diagram showing CCEM APM architecture.
  Animates nodes progressively when visible. Respects prefers-reduced-motion.
  """
  attr :id, :string, default: "ccem-c4-diagram"
  attr :class, :string, default: ""

  def c4_container_diagram(assigns) do
    ~H"""
    <div id={@id} class={["showcase-diagram relative", @class]} data-animate="true">
      <svg
        viewBox="0 0 800 500"
        xmlns="http://www.w3.org/2000/svg"
        class="w-full h-auto max-h-[280px]"
        role="img"
        aria-label="CCEM APM Architecture — C4 Container Diagram"
      >
        <title>CCEM APM Architecture</title>
        <desc>C4 Level 2 Container diagram showing the CCEM APM system boundary with its internal services and external integrations.</desc>

        <defs>
          <linearGradient id="grad-primary" x1="0%" y1="0%" x2="100%" y2="100%">
            <stop offset="0%" style="stop-color:#6366f1;stop-opacity:0.9" />
            <stop offset="100%" style="stop-color:#818cf8;stop-opacity:0.9" />
          </linearGradient>
          <linearGradient id="grad-secondary" x1="0%" y1="0%" x2="100%" y2="100%">
            <stop offset="0%" style="stop-color:#1e1e2e;stop-opacity:0.95" />
            <stop offset="100%" style="stop-color:#313244;stop-opacity:0.95" />
          </linearGradient>
          <filter id="shadow-sm">
            <feDropShadow dx="0" dy="2" stdDeviation="3" flood-opacity="0.3" />
          </filter>
        </defs>

        <%!-- System boundary --%>
        <g class="diagram-node" data-anim-delay="0" opacity="0">
          <rect x="120" y="60" width="560" height="380" rx="12"
            fill="none" stroke="#6366f1" stroke-width="2" stroke-dasharray="8,4" opacity="0.4" />
          <text x="140" y="88" fill="#6366f1" font-size="14" font-weight="600"
            font-family="Inter, system-ui, sans-serif">CCEM APM v5</text>
        </g>

        <%!-- External: Claude Code Agents --%>
        <g class="diagram-node" data-anim-delay="100" opacity="0">
          <rect x="10" y="180" width="100" height="70" rx="8"
            fill="url(#grad-secondary)" stroke="#a6adc8" stroke-width="1.5" filter="url(#shadow-sm)" />
          <text x="60" y="210" text-anchor="middle" fill="#cdd6f4" font-size="11"
            font-family="Inter, system-ui, sans-serif" font-weight="600">Claude Code</text>
          <text x="60" y="228" text-anchor="middle" fill="#a6adc8" font-size="9"
            font-family="Inter, system-ui, sans-serif">Agents</text>
        </g>

        <%!-- External: CCEMAgent --%>
        <g class="diagram-node" data-anim-delay="150" opacity="0">
          <rect x="690" y="180" width="100" height="70" rx="8"
            fill="url(#grad-secondary)" stroke="#a6adc8" stroke-width="1.5" filter="url(#shadow-sm)" />
          <text x="740" y="210" text-anchor="middle" fill="#cdd6f4" font-size="11"
            font-family="Inter, system-ui, sans-serif" font-weight="600">CCEMAgent</text>
          <text x="740" y="228" text-anchor="middle" fill="#a6adc8" font-size="9"
            font-family="Inter, system-ui, sans-serif">macOS Menu Bar</text>
        </g>

        <%!-- Phoenix Web (LiveView) --%>
        <g class="diagram-node" data-anim-delay="200" opacity="0">
          <rect x="300" y="80" width="200" height="55" rx="8"
            fill="url(#grad-primary)" filter="url(#shadow-sm)" />
          <text x="400" y="105" text-anchor="middle" fill="#fff" font-size="12"
            font-family="Inter, system-ui, sans-serif" font-weight="600">Phoenix LiveView</text>
          <text x="400" y="122" text-anchor="middle" fill="#e2e8f0" font-size="9"
            font-family="Inter, system-ui, sans-serif">Dashboard + 20 LiveViews</text>
        </g>

        <%!-- REST API --%>
        <g class="diagram-node" data-anim-delay="300" opacity="0">
          <rect x="145" y="160" width="150" height="50" rx="8"
            fill="url(#grad-primary)" filter="url(#shadow-sm)" />
          <text x="220" y="182" text-anchor="middle" fill="#fff" font-size="12"
            font-family="Inter, system-ui, sans-serif" font-weight="600">REST API</text>
          <text x="220" y="198" text-anchor="middle" fill="#e2e8f0" font-size="9"
            font-family="Inter, system-ui, sans-serif">56+ Endpoints</text>
        </g>

        <%!-- AG-UI Protocol --%>
        <g class="diagram-node" data-anim-delay="400" opacity="0">
          <rect x="505" y="160" width="150" height="50" rx="8"
            fill="url(#grad-primary)" filter="url(#shadow-sm)" />
          <text x="580" y="182" text-anchor="middle" fill="#fff" font-size="12"
            font-family="Inter, system-ui, sans-serif" font-weight="600">AG-UI Protocol</text>
          <text x="580" y="198" text-anchor="middle" fill="#e2e8f0" font-size="9"
            font-family="Inter, system-ui, sans-serif">SSE Events + State</text>
        </g>

        <%!-- GenServer Cluster --%>
        <g class="diagram-node" data-anim-delay="500" opacity="0">
          <rect x="200" y="240" width="180" height="55" rx="8"
            fill="url(#grad-secondary)" stroke="#6366f1" stroke-width="1.5" filter="url(#shadow-sm)" />
          <text x="290" y="263" text-anchor="middle" fill="#cdd6f4" font-size="11"
            font-family="Inter, system-ui, sans-serif" font-weight="600">OTP GenServers</text>
          <text x="290" y="280" text-anchor="middle" fill="#a6adc8" font-size="9"
            font-family="Inter, system-ui, sans-serif">34+ Supervised Processes</text>
        </g>

        <%!-- ETS Storage --%>
        <g class="diagram-node" data-anim-delay="600" opacity="0">
          <rect x="420" y="240" width="150" height="55" rx="8"
            fill="url(#grad-secondary)" stroke="#6366f1" stroke-width="1.5" filter="url(#shadow-sm)" />
          <text x="495" y="263" text-anchor="middle" fill="#cdd6f4" font-size="11"
            font-family="Inter, system-ui, sans-serif" font-weight="600">ETS Tables</text>
          <text x="495" y="280" text-anchor="middle" fill="#a6adc8" font-size="9"
            font-family="Inter, system-ui, sans-serif">In-Memory State</text>
        </g>

        <%!-- PubSub --%>
        <g class="diagram-node" data-anim-delay="700" opacity="0">
          <rect x="300" y="330" width="200" height="45" rx="8"
            fill="url(#grad-secondary)" stroke="#34d399" stroke-width="1.5" filter="url(#shadow-sm)" />
          <text x="400" y="350" text-anchor="middle" fill="#34d399" font-size="11"
            font-family="Inter, system-ui, sans-serif" font-weight="600">Phoenix PubSub</text>
          <text x="400" y="366" text-anchor="middle" fill="#a6adc8" font-size="9"
            font-family="Inter, system-ui, sans-serif">Real-time Event Bus</text>
        </g>

        <%!-- Connections --%>
        <g class="diagram-edge" data-anim-delay="800" opacity="0">
          <%!-- Agents → REST API --%>
          <line x1="110" y1="215" x2="145" y2="190" stroke="#a6adc8" stroke-width="1.5" />
          <%!-- CCEMAgent → AG-UI --%>
          <line x1="690" y1="215" x2="655" y2="190" stroke="#a6adc8" stroke-width="1.5" />
          <%!-- REST → GenServers --%>
          <line x1="220" y1="210" x2="260" y2="240" stroke="#6366f1" stroke-width="1" stroke-dasharray="4,3" />
          <%!-- AG-UI → GenServers --%>
          <line x1="560" y1="210" x2="400" y2="255" stroke="#6366f1" stroke-width="1" stroke-dasharray="4,3" />
          <%!-- GenServers → ETS --%>
          <line x1="380" y1="265" x2="420" y2="265" stroke="#6366f1" stroke-width="1" stroke-dasharray="4,3" />
          <%!-- GenServers → PubSub --%>
          <line x1="290" y1="295" x2="350" y2="330" stroke="#34d399" stroke-width="1" stroke-dasharray="4,3" />
          <%!-- ETS → PubSub --%>
          <line x1="495" y1="295" x2="450" y2="330" stroke="#34d399" stroke-width="1" stroke-dasharray="4,3" />
          <%!-- PubSub → LiveView --%>
          <line x1="400" y1="330" x2="400" y2="135" stroke="#34d399" stroke-width="1" stroke-dasharray="4,3" />
        </g>
      </svg>

      <script>
        // Progressive reveal animation with prefers-reduced-motion respect
        (function() {
          const diagram = document.getElementById("<%= @id %>");
          if (!diagram) return;

          const prefersReduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

          const nodes = diagram.querySelectorAll("[data-anim-delay]");
          if (prefersReduced) {
            nodes.forEach(n => n.setAttribute("opacity", "1"));
            return;
          }

          const observer = new IntersectionObserver((entries) => {
            entries.forEach(entry => {
              if (entry.isIntersecting) {
                nodes.forEach(node => {
                  const delay = parseInt(node.dataset.animDelay || 0);
                  setTimeout(() => {
                    node.style.transition = "opacity 0.5s ease, transform 0.5s ease";
                    node.setAttribute("opacity", "1");
                    node.style.transform = "translateY(0)";
                  }, delay);
                });
                observer.unobserve(entry.target);
              }
            });
          }, { threshold: 0.3 });

          // Set initial transform for animation
          nodes.forEach(node => {
            node.style.transform = "translateY(8px)";
          });

          observer.observe(diagram);
        })();
      </script>
    </div>
    """
  end
end
