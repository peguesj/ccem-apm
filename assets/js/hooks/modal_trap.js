/**
 * ModalTrap — keyboard focus trap for modal dialogs.
 *
 * On mount:  saves the previously focused element and moves focus into the modal.
 * Tab/Shift+Tab: cycles focus within focusable descendants only.
 * Escape:    pushes "close_modal" event to LiveView.
 * destroyed(): restores focus to the element that had it before the modal opened.
 */
const FOCUSABLE =
  'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), ' +
  'textarea:not([disabled]), [tabindex]:not([tabindex="-1"])'

const ModalTrap = {
  mounted() {
    this._prior = document.activeElement

    this._onKeyDown = this._onKeyDown.bind(this)
    document.addEventListener("keydown", this._onKeyDown, true)

    // Move focus to the first focusable element inside the modal (or the modal itself)
    const first = this._focusable()[0]
    if (first) {
      first.focus()
    } else {
      // Make the container focusable as a fallback
      if (!this.el.hasAttribute("tabindex")) this.el.setAttribute("tabindex", "-1")
      this.el.focus()
    }
  },

  destroyed() {
    document.removeEventListener("keydown", this._onKeyDown, true)
    if (this._prior && typeof this._prior.focus === "function") {
      this._prior.focus()
    }
  },

  _focusable() {
    return Array.from(this.el.querySelectorAll(FOCUSABLE)).filter(
      (el) => !el.closest("[aria-hidden='true']") && !el.closest("[inert]")
    )
  },

  _onKeyDown(e) {
    if (e.key === "Escape") {
      e.preventDefault()
      this.pushEvent("close_modal", {})
      return
    }

    if (e.key !== "Tab") return

    const nodes = this._focusable()
    if (nodes.length === 0) {
      e.preventDefault()
      return
    }

    const first = nodes[0]
    const last  = nodes[nodes.length - 1]
    const active = document.activeElement

    if (e.shiftKey) {
      // Shift+Tab: if focus is on first (or outside modal), wrap to last
      if (active === first || !this.el.contains(active)) {
        e.preventDefault()
        last.focus()
      }
    } else {
      // Tab: if focus is on last (or outside modal), wrap to first
      if (active === last || !this.el.contains(active)) {
        e.preventDefault()
        first.focus()
      }
    }
  }
}

export default ModalTrap
