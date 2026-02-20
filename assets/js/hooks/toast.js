/**
 * Toast LiveView JS Hook
 *
 * SCADA-themed toast notifications for agent lifecycle events.
 * Listens for "show_toast" push_events from LiveView.
 */

const SCADA_COLORS = {
  success: "#7eef6d",
  error: "#ff6b5a",
  warning: "#ffaa44",
  info: "#5daaff"
}

const MAX_VISIBLE = 5
const DEFAULT_DURATION = 5000

const Toast = {
  mounted() {
    this.handleEvent("show_toast", (toast) => {
      this.showToast(toast)
    })
  },

  showToast({ type, title, message, duration, category, agent_id }) {
    const container = this.getOrCreateContainer()
    const toasts = container.querySelectorAll(".toast-item")

    // Enforce max visible limit
    if (toasts.length >= MAX_VISIBLE) {
      this.dismissToast(toasts[0])
    }

    const color = SCADA_COLORS[type] || SCADA_COLORS.info
    const dismissAfter = duration || DEFAULT_DURATION

    const toast = document.createElement("div")
    toast.className = "toast-item"
    toast.style.cssText = [
      "position: relative",
      "display: flex",
      "align-items: flex-start",
      "gap: 12px",
      "padding: 14px 16px",
      "margin-top: 8px",
      "min-width: 320px",
      "max-width: 420px",
      "background: rgba(28, 37, 54, 0.85)",
      `border-left: 3px solid ${color}`,
      "border-radius: 6px",
      "backdrop-filter: blur(12px)",
      "-webkit-backdrop-filter: blur(12px)",
      "box-shadow: 0 8px 32px rgba(0, 0, 0, 0.35)",
      "color: #e2e8f0",
      "font-family: 'JetBrains Mono', 'SF Mono', 'Fira Code', monospace",
      "font-size: 13px",
      "animation: toast-slide-in 0.3s ease-out forwards",
      "pointer-events: auto"
    ].join(";")

    const body = document.createElement("div")
    body.style.cssText = "flex: 1; min-width: 0;"

    if (title) {
      const titleEl = document.createElement("div")
      titleEl.style.cssText = [
        "font-weight: 600",
        "margin-bottom: 4px",
        `color: ${color}`,
        "font-size: 13px",
        "line-height: 1.3"
      ].join(";")
      titleEl.textContent = title
      body.appendChild(titleEl)
    }

    if (message) {
      const msgEl = document.createElement("div")
      msgEl.style.cssText = [
        "color: #94a3b8",
        "font-size: 12px",
        "line-height: 1.4",
        "word-break: break-word"
      ].join(";")
      msgEl.textContent = message
      body.appendChild(msgEl)
    }

    if (category || agent_id) {
      const metaEl = document.createElement("div")
      metaEl.style.cssText = [
        "margin-top: 6px",
        "font-size: 10px",
        "color: #64748b",
        "letter-spacing: 0.05em",
        "text-transform: uppercase"
      ].join(";")
      const parts = []
      if (category) parts.push(category)
      if (agent_id) parts.push(agent_id)
      metaEl.textContent = parts.join(" / ")
      body.appendChild(metaEl)
    }

    toast.appendChild(body)

    // Close button
    const closeBtn = document.createElement("button")
    closeBtn.style.cssText = [
      "background: none",
      "border: none",
      "color: #64748b",
      "cursor: pointer",
      "font-size: 16px",
      "line-height: 1",
      "padding: 0 0 0 8px",
      "flex-shrink: 0",
      "transition: color 0.15s ease"
    ].join(";")
    closeBtn.textContent = "\u00d7"
    closeBtn.addEventListener("mouseenter", () => { closeBtn.style.color = "#e2e8f0" })
    closeBtn.addEventListener("mouseleave", () => { closeBtn.style.color = "#64748b" })
    closeBtn.addEventListener("click", () => { this.dismissToast(toast) })
    toast.appendChild(closeBtn)

    container.appendChild(toast)

    // Auto-dismiss
    toast._dismissTimer = setTimeout(() => {
      this.dismissToast(toast)
    }, dismissAfter)
  },

  dismissToast(toast) {
    if (!toast || toast._dismissing) return
    toast._dismissing = true
    if (toast._dismissTimer) clearTimeout(toast._dismissTimer)

    toast.style.animation = "toast-fade-out 0.25s ease-in forwards"
    toast.addEventListener("animationend", () => { toast.remove() }, { once: true })
  },

  getOrCreateContainer() {
    let container = document.getElementById("toast-container")
    if (!container) {
      container = document.createElement("div")
      container.id = "toast-container"
      container.style.cssText = [
        "position: fixed",
        "bottom: 20px",
        "right: 20px",
        "z-index: 9999",
        "display: flex",
        "flex-direction: column",
        "align-items: flex-end",
        "pointer-events: none"
      ].join(";")
      document.body.appendChild(container)
    }
    return container
  }
}

export default Toast
