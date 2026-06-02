/**
 * DrawerSlide — slide-from-right panel animation.
 *
 * Attributes:
 *   data-open   any truthy string ("true", "1") opens the drawer;
 *               absent or "false" / "0" closes it.
 *
 * The element is expected to be positioned fixed/absolute with
 * right:0 and full height. The hook manages translateX transitions.
 * 250ms cubic-bezier(0.16,1,0.3,1) matches the v11 motion spec.
 */
const EASING   = "cubic-bezier(0.16,1,0.3,1)"
const DURATION = "250ms"

const DrawerSlide = {
  mounted() {
    // Set up base transition without triggering a layout flash
    this.el.style.transition = `transform ${DURATION} ${EASING}`
    this._apply(this._isOpen())
  },

  updated() {
    this._apply(this._isOpen())
  },

  destroyed() {
    // Nothing to clean up — transition is inline style only
  },

  _isOpen() {
    const v = this.el.dataset.open
    return v !== undefined && v !== "false" && v !== "0" && v !== ""
  },

  _apply(open) {
    this.el.style.transform = open ? "translateX(0)" : "translateX(100%)"
    // Accessibility: remove from tab order when closed
    if (open) {
      this.el.removeAttribute("aria-hidden")
      this.el.removeAttribute("inert")
    } else {
      this.el.setAttribute("aria-hidden", "true")
      this.el.setAttribute("inert", "")
    }
  }
}

export default DrawerSlide
