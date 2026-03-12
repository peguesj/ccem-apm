/**
 * GettingStartedShowcase LiveView Hook
 *
 * Two-column modal showcase with Lottie animations (via lottie-web),
 * dotted slide navigation, and CCEM APM telemetry reporting.
 *
 * Features covered:
 *   1. /upm — Unified Project Management
 *   2. /upm sync plan build — Planning & Build Pipeline
 *   3. /live-integration-testing — Browser-Driven E2E Testing
 *   4. /double-verify — Cross-Agent Verification
 *   5. /pr ship — Source Control Excellence
 */

const SHOWCASE_STORAGE_KEY = "ccem_showcase_complete";
const APM_BASE = "http://localhost:3032";

// --- Lottie Animation Data ---
// Compact Lottie JSON animations for each slide, using shape layers with keyframes.
// Colors from showcase-obsidian theme: #6366f1 (indigo), #818cf8 (light indigo),
// #34d399 (success green), #fbbf24 (warning amber), #e2e8f0 (soft white)

function rgba(hex, a = 1) {
  const r = parseInt(hex.slice(1, 3), 16) / 255;
  const g = parseInt(hex.slice(3, 5), 16) / 255;
  const b = parseInt(hex.slice(5, 7), 16) / 255;
  return [r, g, b, a];
}

const C = {
  indigo: rgba("#6366f1"),
  light: rgba("#818cf8"),
  green: rgba("#34d399"),
  amber: rgba("#fbbf24"),
  white: rgba("#e2e8f0"),
  dim: rgba("#a6adc8", 0.4),
  bg: rgba("#1e1e2e", 0.6),
};

function makeRect(x, y, w, h, color, delay = 0, dur = 30) {
  return {
    ty: 4, ddd: 0, ind: 0, sr: 1, nm: "R",
    ks: {
      o: { a: 1, k: [
        { t: delay, s: [0], e: [100] },
        { t: delay + dur, s: [100] }
      ]},
      r: { a: 0, k: 0 },
      p: { a: 0, k: [x + w/2, y + h/2, 0] },
      a: { a: 0, k: [0, 0, 0] },
      s: { a: 1, k: [
        { t: delay, s: [0, 0, 100], e: [100, 100, 100] },
        { t: delay + dur, s: [100, 100, 100] }
      ]}
    },
    shapes: [
      { ty: "rc", d: 1, s: { a: 0, k: [w, h] }, p: { a: 0, k: [0, 0] }, r: { a: 0, k: 8 }, nm: "R" },
      { ty: "fl", c: { a: 0, k: color }, o: { a: 0, k: 100 }, nm: "F" }
    ],
    ip: 0, op: 120, st: 0
  };
}

function makeCircle(cx, cy, r, color, delay = 0, dur = 20) {
  return {
    ty: 4, ddd: 0, ind: 0, sr: 1, nm: "C",
    ks: {
      o: { a: 1, k: [
        { t: delay, s: [0], e: [100] },
        { t: delay + dur, s: [100] }
      ]},
      r: { a: 0, k: 0 },
      p: { a: 0, k: [cx, cy, 0] },
      a: { a: 0, k: [0, 0, 0] },
      s: { a: 1, k: [
        { t: delay, s: [0, 0, 100], e: [100, 100, 100] },
        { t: delay + 15, s: [120, 120, 100], e: [100, 100, 100] },
        { t: delay + dur, s: [100, 100, 100] }
      ]}
    },
    shapes: [
      { ty: "el", d: 1, s: { a: 0, k: [r*2, r*2] }, p: { a: 0, k: [0, 0] }, nm: "E" },
      { ty: "fl", c: { a: 0, k: color }, o: { a: 0, k: 100 }, nm: "F" }
    ],
    ip: 0, op: 120, st: 0
  };
}

function makeLine(x1, y1, x2, y2, color, delay = 0, dur = 20) {
  return {
    ty: 4, ddd: 0, ind: 0, sr: 1, nm: "L",
    ks: {
      o: { a: 1, k: [
        { t: delay, s: [0], e: [80] },
        { t: delay + dur, s: [80] }
      ]},
      r: { a: 0, k: 0 },
      p: { a: 0, k: [0, 0, 0] },
      a: { a: 0, k: [0, 0, 0] },
      s: { a: 0, k: [100, 100, 100] }
    },
    shapes: [
      {
        ty: "sh", d: 1, nm: "P",
        ks: { a: 0, k: { i: [[0,0],[0,0]], o: [[0,0],[0,0]], v: [[x1,y1],[x2,y2]], c: false } }
      },
      { ty: "st", c: { a: 0, k: color }, o: { a: 0, k: 100 }, w: { a: 0, k: 2 }, lc: 2, lj: 2, nm: "S" }
    ],
    ip: 0, op: 120, st: 0
  };
}

function makeCheckmark(cx, cy, size, color, delay = 0) {
  const s = size;
  return {
    ty: 4, ddd: 0, ind: 0, sr: 1, nm: "Check",
    ks: {
      o: { a: 1, k: [
        { t: delay, s: [0], e: [100] },
        { t: delay + 15, s: [100] }
      ]},
      r: { a: 0, k: 0 },
      p: { a: 0, k: [cx, cy, 0] },
      a: { a: 0, k: [0, 0, 0] },
      s: { a: 1, k: [
        { t: delay, s: [0, 0, 100], e: [120, 120, 100] },
        { t: delay + 10, s: [120, 120, 100], e: [100, 100, 100] },
        { t: delay + 20, s: [100, 100, 100] }
      ]}
    },
    shapes: [
      {
        ty: "sh", d: 1, nm: "Chk",
        ks: { a: 0, k: {
          i: [[0,0],[0,0],[0,0]],
          o: [[0,0],[0,0],[0,0]],
          v: [[-s*0.4, 0], [-s*0.1, s*0.3], [s*0.4, -s*0.3]],
          c: false
        }}
      },
      { ty: "st", c: { a: 0, k: color }, o: { a: 0, k: 100 }, w: { a: 0, k: 3 }, lc: 2, lj: 2, nm: "S" }
    ],
    ip: 0, op: 120, st: 0
  };
}

function lottieBase(layers, w = 360, h = 280) {
  return { v: "5.5.7", fr: 30, ip: 0, op: 120, w, h, nm: "anim", ddd: 0, assets: [], layers };
}

// Slide 1: /upm — Orchestration network (connected nodes)
const anim_upm = lottieBase([
  // Central hub
  makeCircle(180, 140, 24, C.indigo, 0),
  // Surrounding nodes
  makeCircle(80, 80, 16, C.light, 10),
  makeCircle(280, 80, 16, C.light, 15),
  makeCircle(80, 200, 16, C.light, 20),
  makeCircle(280, 200, 16, C.light, 25),
  makeCircle(180, 40, 14, C.green, 30),
  makeCircle(180, 240, 14, C.green, 35),
  // Connections
  makeLine(180, 140, 80, 80, C.dim, 40),
  makeLine(180, 140, 280, 80, C.dim, 45),
  makeLine(180, 140, 80, 200, C.dim, 50),
  makeLine(180, 140, 280, 200, C.dim, 55),
  makeLine(180, 140, 180, 40, C.dim, 58),
  makeLine(180, 140, 180, 240, C.dim, 60),
  // Pulse ring on center
  makeCircle(180, 140, 32, [...C.indigo.slice(0,3), 0.2], 65, 30),
]);

// Slide 2: /upm sync plan build — Pipeline stages
const anim_pipeline = lottieBase([
  // Pipeline stages (left to right)
  makeRect(20, 100, 70, 50, C.indigo, 0),    // sync
  makeRect(110, 100, 70, 50, C.light, 15),    // plan
  makeRect(200, 100, 70, 50, C.green, 30),    // build
  makeRect(290, 100, 50, 50, C.amber, 45),    // verify
  // Arrows between
  makeLine(90, 125, 110, 125, C.white, 10),
  makeLine(180, 125, 200, 125, C.white, 25),
  makeLine(270, 125, 290, 125, C.white, 40),
  // Labels (small rects as label backgrounds)
  makeRect(30, 170, 50, 16, [...C.indigo.slice(0,3), 0.3], 5),
  makeRect(120, 170, 50, 16, [...C.light.slice(0,3), 0.3], 20),
  makeRect(210, 170, 50, 16, [...C.green.slice(0,3), 0.3], 35),
  makeRect(295, 170, 40, 16, [...C.amber.slice(0,3), 0.3], 50),
  // Progress bar at bottom
  makeRect(20, 220, 320, 6, [...C.indigo.slice(0,3), 0.15], 0),
  makeRect(20, 220, 80, 6, C.indigo, 10, 50),
  makeRect(100, 220, 80, 6, C.light, 25, 40),
  makeRect(200, 220, 80, 6, C.green, 40, 30),
]);

// Slide 3: /live-integration-testing — Browser with checkmarks
const anim_testing = lottieBase([
  // Browser frame
  makeRect(40, 30, 280, 200, [...C.white.slice(0,3), 0.05], 0, 20),
  // Title bar
  makeRect(40, 30, 280, 24, [...C.indigo.slice(0,3), 0.3], 5),
  // Browser dots
  makeCircle(58, 42, 4, C.green, 10),
  makeCircle(72, 42, 4, C.amber, 12),
  makeCircle(86, 42, 4, [...C.white.slice(0,3), 0.3], 14),
  // Test rows
  makeRect(60, 70, 240, 28, [...C.green.slice(0,3), 0.1], 20),
  makeRect(60, 106, 240, 28, [...C.green.slice(0,3), 0.1], 30),
  makeRect(60, 142, 240, 28, [...C.green.slice(0,3), 0.1], 40),
  makeRect(60, 178, 240, 28, [...C.amber.slice(0,3), 0.1], 50),
  // Checkmarks
  makeCheckmark(80, 84, 12, C.green, 25),
  makeCheckmark(80, 120, 12, C.green, 35),
  makeCheckmark(80, 156, 12, C.green, 45),
  makeCheckmark(80, 192, 12, C.amber, 55),
  // Status bar
  makeRect(40, 240, 280, 20, [...C.green.slice(0,3), 0.2], 60),
]);

// Slide 4: /double-verify — Dual verification badges
const anim_verify = lottieBase([
  // First verification circle
  makeCircle(120, 130, 50, [...C.indigo.slice(0,3), 0.15], 0, 25),
  makeCircle(120, 130, 36, [...C.indigo.slice(0,3), 0.3], 10, 20),
  makeCheckmark(120, 130, 20, C.green, 20),
  // Second verification circle (overlapping)
  makeCircle(240, 130, 50, [...C.green.slice(0,3), 0.15], 25, 25),
  makeCircle(240, 130, 36, [...C.green.slice(0,3), 0.3], 35, 20),
  makeCheckmark(240, 130, 20, C.green, 45),
  // Connection arc between them
  makeLine(156, 130, 204, 130, C.light, 50, 15),
  // Consensus badge (center)
  makeCircle(180, 210, 18, C.green, 60, 20),
  makeCheckmark(180, 210, 10, C.white, 70),
  // Labels
  makeRect(90, 200, 60, 14, [...C.indigo.slice(0,3), 0.2], 30),
  makeRect(210, 200, 60, 14, [...C.green.slice(0,3), 0.2], 55),
]);

// Slide 5: /pr ship — Rocket / package launch
const anim_ship = lottieBase([
  // Platform/launch pad
  makeRect(100, 220, 160, 8, C.dim, 0),
  // Package body (rocket)
  makeRect(155, 120, 50, 80, C.indigo, 5, 20),
  // Nose cone (triangle approx with small rect)
  makeRect(160, 100, 40, 20, C.light, 10, 15),
  makeCircle(180, 95, 12, C.light, 15, 15),
  // Fins
  makeRect(145, 180, 15, 24, [...C.indigo.slice(0,3), 0.7], 12),
  makeRect(200, 180, 15, 24, [...C.indigo.slice(0,3), 0.7], 14),
  // Flame particles
  makeCircle(180, 218, 10, C.amber, 30, 10),
  makeCircle(175, 228, 8, [...C.amber.slice(0,3), 0.7], 33, 10),
  makeCircle(185, 232, 6, [...C.amber.slice(0,3), 0.5], 36, 10),
  // Launch motion - additional flame bursts
  makeCircle(170, 240, 12, [...C.amber.slice(0,3), 0.3], 40, 15),
  makeCircle(190, 245, 10, [...C.amber.slice(0,3), 0.2], 42, 15),
  // Stars around
  makeCircle(60, 60, 3, C.white, 50),
  makeCircle(300, 50, 3, C.white, 52),
  makeCircle(40, 160, 2, C.white, 54),
  makeCircle(320, 140, 2, C.white, 56),
  makeCircle(280, 180, 3, C.white, 58),
  // Success badge
  makeCircle(300, 80, 16, C.green, 65),
  makeCheckmark(300, 80, 8, C.white, 70),
]);

const ANIMATIONS = [anim_upm, anim_pipeline, anim_testing, anim_verify, anim_ship];

// --- Slide Content ---
const SLIDES = [
  {
    id: "upm",
    command: "/upm",
    title: "Unified Project Management",
    subtitle: "End-to-end workflow orchestration",
    description: "UPM transforms feature ideas into shipped code through a structured pipeline. It generates PRDs, creates Plane issues, deploys agent formations, and gates every wave with type checking.",
    features: [
      "PRD generation with Ralph methodology",
      "Plane PM issue creation & sync",
      "Formation-based agent deployment",
      "TypeScript/Elixir gate checks between waves",
      "Checkpoint tracking in CLAUDE.md"
    ]
  },
  {
    id: "pipeline",
    command: "/upm sync plan build",
    title: "Planning & Build Pipeline",
    subtitle: "From idea to implementation in waves",
    description: "Sync keeps your tracking systems aligned. Plan generates stories from feature descriptions. Build deploys agent formations in dependency-ordered waves with automatic gating.",
    features: [
      "sync — detect & repair drift across systems",
      "plan — generate PRD with user stories",
      "build — deploy agents in waves",
      "Automatic wave gating (tsc/mix compile)",
      "Kill criteria on 3+ agent failures"
    ]
  },
  {
    id: "testing",
    command: "/live-integration-testing",
    title: "Browser-Driven E2E Testing",
    subtitle: "Multi-provider test orchestration",
    description: "Run live integration tests against your running application using Chrome DevTools, Playwright, and Puppeteer. Automated auth flow, DOM inspection, console error capture, and visual verification.",
    features: [
      "Chrome DevTools MCP for inspection",
      "Playwright for E2E test flows",
      "Puppeteer for rendering verification",
      "Automated Azure AD auth flow",
      "Screenshot capture & DOM snapshots"
    ]
  },
  {
    id: "verify",
    command: "/double-verify",
    title: "Cross-Agent Verification",
    subtitle: "Independent consensus verification",
    description: "Spawn two independent verification agents that separately assess your code changes. Results are compared for consensus — catching issues that a single pass might miss.",
    features: [
      "Two independent verification agents",
      "Parallel execution for speed",
      "Consensus-based pass/fail",
      "5-stage toast event pipeline",
      "Integrated with /upm verify gate"
    ]
  },
  {
    id: "ship",
    command: "/pr ship",
    title: "Source Control Excellence",
    subtitle: "Verified commit, push, and PR creation",
    description: "Ship runs full verification before committing. Creates atomic commits with story summaries, pushes to remote, and opens PRs with test results in the body. Updates Plane and CLAUDE.md checkpoints.",
    features: [
      "Hard verification gate before commit",
      "Atomic commits with story summaries",
      "PR creation with test matrix",
      "Plane issue state sync to Done",
      "Checkpoint marking in CLAUDE.md"
    ]
  }
];

// --- APM Reporting ---
function reportToAPM(eventType, data) {
  try {
    const payload = {
      type: "info",
      title: `Showcase: ${eventType}`,
      message: JSON.stringify(data),
      category: "upm",
      ...data
    };
    fetch(`${APM_BASE}/api/notify`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload)
    }).catch(() => {}); // fire-and-forget
  } catch (_) {}
}

// --- Hook ---
const GettingStartedShowcase = {
  mounted() {
    this.current = 0;
    this.total = SLIDES.length;
    this.lottieInstances = [];
    this.prefersReduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    this.eventsReady = false;

    // Check if already completed — element starts hidden via style="display:none"
    if (localStorage.getItem(SHOWCASE_STORAGE_KEY) === "true") {
      return;
    }

    // First visit — show the showcase
    this.el.style.display = "";
    reportToAPM("showcase_opened", { slide: 0, slide_id: SLIDES[0].id });

    this.renderSlide(0);
    this.bindEvents();
    this.loadLottie();

    // Listen for re-show from LiveView (Help menu)
    this.handleEvent("showcase:reshow", () => {
      localStorage.removeItem(SHOWCASE_STORAGE_KEY);
      this.current = 0;
      this.el.style.display = "";
      this.el.style.opacity = "1";
      this.renderSlide(0);
      if (!this.eventsReady) this.bindEvents();
      this.loadLottie();
      reportToAPM("showcase_reopened", { slide: 0 });
    });
  },

  destroyed() {
    this.lottieInstances.forEach(inst => {
      try { inst.destroy(); } catch (_) {}
    });
  },

  async loadLottie() {
    // Load lottie-web from CDN if not already loaded
    if (!window.lottie) {
      try {
        const script = document.createElement("script");
        script.src = "https://cdnjs.cloudflare.com/ajax/libs/lottie-web/5.12.2/lottie.min.js";
        script.onload = () => this.initAnimation(this.current);
        document.head.appendChild(script);
      } catch (_) {
        // Fallback: animations will just be static
      }
    } else {
      this.initAnimation(this.current);
    }
  },

  initAnimation(slideIdx) {
    if (!window.lottie) return;

    const container = this.el.querySelector(`[data-lottie-target="${slideIdx}"]`);
    if (!container) return;

    // Clear previous
    container.innerHTML = "";

    try {
      const inst = window.lottie.loadAnimation({
        container,
        renderer: "svg",
        loop: true,
        autoplay: !this.prefersReduced,
        animationData: ANIMATIONS[slideIdx]
      });
      this.lottieInstances[slideIdx] = inst;
    } catch (_) {}
  },

  renderSlide(idx) {
    const slide = SLIDES[idx];
    const slidesContainer = this.el.querySelector("[data-showcase-slides]");
    if (!slidesContainer) return;

    slidesContainer.innerHTML = `
      <div class="flex gap-6 h-full" role="group" aria-label="Slide ${idx + 1} of ${this.total}: ${slide.title}">
        <!-- Left: Lottie animation -->
        <div class="w-[360px] flex-shrink-0 flex items-center justify-center rounded-xl bg-base-300/50 border border-base-300">
          <div data-lottie-target="${idx}" class="w-full h-[280px]"
               role="img" aria-label="${slide.title} animation"></div>
        </div>
        <!-- Right: Content -->
        <div class="flex-1 flex flex-col justify-center min-w-0">
          <div class="inline-flex items-center gap-2 mb-3">
            <code class="px-2 py-0.5 rounded bg-primary/15 text-primary text-xs font-mono font-semibold">${slide.command}</code>
          </div>
          <h3 class="text-xl font-bold text-base-content mb-1">${slide.title}</h3>
          <p class="text-sm text-base-content/60 mb-3">${slide.subtitle}</p>
          <p class="text-sm text-base-content/80 leading-relaxed mb-4">${slide.description}</p>
          <ul class="space-y-1.5">
            ${slide.features.map(f => `
              <li class="flex items-start gap-2 text-sm text-base-content/70">
                <svg class="w-4 h-4 text-success flex-shrink-0 mt-0.5" viewBox="0 0 20 20" fill="currentColor">
                  <path fill-rule="evenodd" d="M16.707 5.293a1 1 0 010 1.414l-8 8a1 1 0 01-1.414 0l-4-4a1 1 0 011.414-1.414L8 12.586l7.293-7.293a1 1 0 011.414 0z" clip-rule="evenodd"/>
                </svg>
                <span>${f}</span>
              </li>
            `).join("")}
          </ul>
        </div>
      </div>
    `;

    // Update dots
    this.el.querySelectorAll("[data-dot]").forEach((dot, i) => {
      dot.classList.toggle("bg-primary", i === idx);
      dot.classList.toggle("w-6", i === idx);
      dot.classList.toggle("bg-base-content/20", i !== idx);
      dot.classList.toggle("w-2", i !== idx);
      dot.setAttribute("aria-current", i === idx ? "step" : "false");
    });

    // Update nav buttons
    const prevBtn = this.el.querySelector("[data-prev]");
    const nextBtn = this.el.querySelector("[data-next]");
    if (prevBtn) prevBtn.classList.toggle("invisible", idx === 0);
    if (nextBtn) nextBtn.textContent = idx === this.total - 1 ? "Get Started" : "Next";

    // Counter
    const counter = this.el.querySelector("[data-counter]");
    if (counter) counter.textContent = `${idx + 1} / ${this.total}`;

    // Init lottie for this slide
    setTimeout(() => this.initAnimation(idx), 50);
  },

  bindEvents() {
    this.eventsReady = true;

    this.el.querySelector("[data-next]")?.addEventListener("click", () => {
      if (this.current >= this.total - 1) {
        this.complete();
      } else {
        this.goTo(this.current + 1);
      }
    });

    this.el.querySelector("[data-prev]")?.addEventListener("click", () => {
      if (this.current > 0) this.goTo(this.current - 1);
    });

    this.el.querySelector("[data-skip]")?.addEventListener("click", () => {
      this.complete();
    });

    this.el.querySelector("[data-dismiss]")?.addEventListener("click", () => {
      this.complete();
    });

    this.el.querySelectorAll("[data-dot]").forEach((dot, idx) => {
      dot.addEventListener("click", () => this.goTo(idx));
    });

    // Keyboard navigation
    this.el.addEventListener("keydown", (e) => {
      if (e.key === "ArrowRight" || e.key === "ArrowDown") {
        e.preventDefault();
        if (this.current < this.total - 1) this.goTo(this.current + 1);
      } else if (e.key === "ArrowLeft" || e.key === "ArrowUp") {
        e.preventDefault();
        if (this.current > 0) this.goTo(this.current - 1);
      } else if (e.key === "Escape") {
        this.complete();
      }
    });
  },

  goTo(idx) {
    if (idx < 0 || idx >= this.total || idx === this.current) return;
    this.current = idx;
    this.renderSlide(idx);

    reportToAPM("showcase_slide_viewed", {
      slide: idx,
      slide_id: SLIDES[idx].id,
      command: SLIDES[idx].command
    });
  },

  complete() {
    localStorage.setItem(SHOWCASE_STORAGE_KEY, "true");
    reportToAPM("showcase_completed", {
      slides_viewed: this.current + 1,
      total_slides: this.total
    });

    // Fade out
    this.el.style.transition = "opacity 0.3s ease";
    this.el.style.opacity = "0";
    setTimeout(() => {
      this.el.style.display = "none";
      // Notify LiveView
      this.pushEvent("showcase:dismiss", {});
    }, 300);
  }
};

export default GettingStartedShowcase;
