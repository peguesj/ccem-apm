/**
 * TooltipOverlay — Guided tour system for CCEM APM
 *
 * Provides a reusable tooltip tour with backdrop dimming, arrows,
 * and navigation (Next/Prev/Skip/Done). Triggered by `?` shortcut.
 *
 * Usage in LiveView:
 *   <div id="tour" phx-hook="TooltipOverlay"
 *        data-tour-config='[{"target":"#sidebar","title":"Navigation","body":"Browse pages here"},...]'>
 *   </div>
 */

const TooltipOverlay = {
  mounted() {
    this.steps = [];
    this.currentStep = 0;
    this.overlay = null;
    this.tooltip = null;
    this.active = false;

    // Parse config from data attribute
    const configAttr = this.el.dataset.tourConfig;
    if (configAttr) {
      try {
        this.steps = JSON.parse(configAttr);
      } catch (e) {
        console.warn("[TooltipOverlay] Invalid tour config:", e);
      }
    }

    // Listen for ? keyboard shortcut
    this._keyHandler = (e) => {
      if (e.key === "?" && !e.ctrlKey && !e.metaKey && !this._isInputFocused()) {
        e.preventDefault();
        this.toggle();
      }
    };
    document.addEventListener("keydown", this._keyHandler);

    // Listen for LiveView events
    this.handleEvent("start-tour", ({ steps }) => {
      if (steps) this.steps = steps;
      this.start();
    });

    this.handleEvent("stop-tour", () => this.stop());
  },

  destroyed() {
    document.removeEventListener("keydown", this._keyHandler);
    this.stop();
  },

  toggle() {
    this.active ? this.stop() : this.start();
  },

  start() {
    if (!this.steps.length) return;
    this.currentStep = 0;
    this.active = true;
    this._createOverlay();
    this._showStep(0);
  },

  stop() {
    this.active = false;
    this._removeOverlay();
    this.pushEventTo(this.el, "tour-ended", { step: this.currentStep });
  },

  _createOverlay() {
    // Backdrop
    this.overlay = document.createElement("div");
    Object.assign(this.overlay.style, {
      position: "fixed", top: 0, left: 0, width: "100vw", height: "100vh",
      background: "rgba(0,0,0,0.6)", zIndex: "9998",
      transition: "opacity 0.2s ease"
    });
    this.overlay.setAttribute("role", "dialog");
    this.overlay.setAttribute("aria-label", "Guided tour overlay");
    this.overlay.addEventListener("click", (e) => {
      if (e.target === this.overlay) this.stop();
    });

    // Tooltip container
    this.tooltip = document.createElement("div");
    Object.assign(this.tooltip.style, {
      position: "fixed", zIndex: "9999",
      background: "#1e1e2e", color: "#cdd6f4",
      borderRadius: "8px", padding: "16px 20px",
      boxShadow: "0 8px 32px rgba(0,0,0,0.4)",
      maxWidth: "320px", minWidth: "240px",
      border: "1px solid rgba(99,102,241,0.3)",
      fontFamily: "Inter, system-ui, sans-serif",
      fontSize: "14px", lineHeight: "1.5",
      transition: "opacity 0.2s ease, transform 0.2s ease"
    });

    // Arrow element
    this.arrow = document.createElement("div");
    Object.assign(this.arrow.style, {
      position: "absolute", width: "12px", height: "12px",
      background: "#1e1e2e", transform: "rotate(45deg)",
      border: "1px solid rgba(99,102,241,0.3)"
    });
    this.tooltip.appendChild(this.arrow);

    document.body.appendChild(this.overlay);
    document.body.appendChild(this.tooltip);
  },

  _removeOverlay() {
    if (this.overlay) { this.overlay.remove(); this.overlay = null; }
    if (this.tooltip) { this.tooltip.remove(); this.tooltip = null; }
    // Remove any target highlights
    document.querySelectorAll("[data-tour-highlight]").forEach(el => {
      el.removeAttribute("data-tour-highlight");
      el.style.removeProperty("position");
      el.style.removeProperty("z-index");
      el.style.removeProperty("box-shadow");
    });
  },

  _showStep(index) {
    if (index < 0 || index >= this.steps.length) { this.stop(); return; }
    this.currentStep = index;
    const step = this.steps[index];
    const target = document.querySelector(step.target);

    // Clear previous highlights
    document.querySelectorAll("[data-tour-highlight]").forEach(el => {
      el.removeAttribute("data-tour-highlight");
      el.style.removeProperty("z-index");
      el.style.removeProperty("box-shadow");
    });

    // Highlight target
    if (target) {
      target.setAttribute("data-tour-highlight", "true");
      target.style.zIndex = "9999";
      target.style.boxShadow = "0 0 0 4px rgba(99,102,241,0.5)";
      target.scrollIntoView({ behavior: "smooth", block: "center" });
    }

    // Build tooltip content
    const isFirst = index === 0;
    const isLast = index === this.steps.length - 1;

    this.tooltip.innerHTML = "";
    this.tooltip.appendChild(this.arrow);

    // Progress dots
    const progress = document.createElement("div");
    progress.style.cssText = "display:flex;gap:4px;margin-bottom:8px;";
    this.steps.forEach((_, i) => {
      const dot = document.createElement("span");
      dot.style.cssText = `width:6px;height:6px;border-radius:50%;background:${i === index ? "#6366f1" : "#45475a"};`;
      dot.setAttribute("aria-label", `Step ${i + 1} of ${this.steps.length}`);
      progress.appendChild(dot);
    });
    this.tooltip.appendChild(progress);

    // Title
    if (step.title) {
      const title = document.createElement("div");
      title.style.cssText = "font-weight:600;font-size:15px;margin-bottom:4px;color:#cdd6f4;";
      title.textContent = step.title;
      this.tooltip.appendChild(title);
    }

    // Body
    if (step.body) {
      const body = document.createElement("div");
      body.style.cssText = "color:#a6adc8;margin-bottom:12px;";
      body.textContent = step.body;
      this.tooltip.appendChild(body);
    }

    // Navigation buttons
    const nav = document.createElement("div");
    nav.style.cssText = "display:flex;justify-content:space-between;align-items:center;gap:8px;";

    const skipBtn = this._btn("Skip", () => this.stop(), "#6c7086");
    nav.appendChild(skipBtn);

    const rightNav = document.createElement("div");
    rightNav.style.cssText = "display:flex;gap:6px;";

    if (!isFirst) {
      rightNav.appendChild(this._btn("Previous", () => this._showStep(index - 1), "#45475a"));
    }

    if (isLast) {
      rightNav.appendChild(this._btn("Done", () => this.stop(), "#6366f1"));
    } else {
      rightNav.appendChild(this._btn("Next", () => this._showStep(index + 1), "#6366f1"));
    }

    nav.appendChild(rightNav);
    this.tooltip.appendChild(nav);

    // Position tooltip relative to target
    this._positionTooltip(target, step.placement || "bottom");

    // Announce for screen readers
    this.tooltip.setAttribute("role", "tooltip");
    this.tooltip.setAttribute("aria-live", "polite");
  },

  _positionTooltip(target, placement) {
    if (!target || !this.tooltip) return;

    const rect = target.getBoundingClientRect();
    const tt = this.tooltip.getBoundingClientRect();
    const gap = 16;
    let top, left;

    switch (placement) {
      case "top":
        top = rect.top - tt.height - gap;
        left = rect.left + (rect.width - tt.width) / 2;
        this.arrow.style.cssText += "bottom:-6px;left:50%;transform:translateX(-50%) rotate(45deg);border-top:none;border-left:none;";
        break;
      case "left":
        top = rect.top + (rect.height - tt.height) / 2;
        left = rect.left - tt.width - gap;
        this.arrow.style.cssText += "right:-6px;top:50%;transform:translateY(-50%) rotate(45deg);border-bottom:none;border-left:none;";
        break;
      case "right":
        top = rect.top + (rect.height - tt.height) / 2;
        left = rect.right + gap;
        this.arrow.style.cssText += "left:-6px;top:50%;transform:translateY(-50%) rotate(45deg);border-top:none;border-right:none;";
        break;
      default: // bottom
        top = rect.bottom + gap;
        left = rect.left + (rect.width - tt.width) / 2;
        this.arrow.style.cssText += "top:-6px;left:50%;transform:translateX(-50%) rotate(45deg);border-bottom:none;border-right:none;";
    }

    // Clamp to viewport
    top = Math.max(8, Math.min(top, window.innerHeight - tt.height - 8));
    left = Math.max(8, Math.min(left, window.innerWidth - tt.width - 8));

    this.tooltip.style.top = `${top}px`;
    this.tooltip.style.left = `${left}px`;
  },

  _btn(text, onClick, bg) {
    const btn = document.createElement("button");
    btn.textContent = text;
    btn.style.cssText = `padding:4px 12px;border-radius:4px;border:none;background:${bg};color:#cdd6f4;cursor:pointer;font-size:13px;font-family:inherit;`;
    btn.addEventListener("click", onClick);
    btn.addEventListener("mouseenter", () => { btn.style.opacity = "0.85"; });
    btn.addEventListener("mouseleave", () => { btn.style.opacity = "1"; });
    return btn;
  },

  _isInputFocused() {
    const el = document.activeElement;
    return el && (el.tagName === "INPUT" || el.tagName === "TEXTAREA" || el.contentEditable === "true");
  }
};

export default TooltipOverlay;
