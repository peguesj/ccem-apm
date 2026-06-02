/**
 * SwipeDecide — pointer drag-to-decide gesture.
 *
 * Drag right ≥ 50px → "allow", left ≥ 50px → "deny".
 * Releases under threshold or on pointercancel snap back to origin.
 *
 * Attributes:
 *   data-item-id   identifier passed in the "swipe_decide" push event
 *
 * Push event payload: { id, decision: "allow" | "deny" }
 */
const THRESHOLD = 50

const SwipeDecide = {
  mounted() {
    this._onPointerDown = this._onPointerDown.bind(this)
    this._onPointerMove = this._onPointerMove.bind(this)
    this._onPointerUp   = this._onPointerUp.bind(this)
    this._onPointerCancel = this._onPointerCancel.bind(this)

    this.el.addEventListener("pointerdown", this._onPointerDown)
    this.el.style.touchAction = "pan-y"
    this.el.style.userSelect  = "none"
    this.el.style.willChange  = "transform"
    this.el.style.transition  = ""
  },

  destroyed() {
    this.el.removeEventListener("pointerdown", this._onPointerDown)
    this._detachMoveListeners()
  },

  _onPointerDown(e) {
    if (e.button !== 0 && e.pointerType === "mouse") return
    this._startX  = e.clientX
    this._dragging = true
    this.el.setPointerCapture(e.pointerId)
    this.el.style.transition = "none"

    this.el.addEventListener("pointermove",   this._onPointerMove)
    this.el.addEventListener("pointerup",     this._onPointerUp)
    this.el.addEventListener("pointercancel", this._onPointerCancel)
  },

  _onPointerMove(e) {
    if (!this._dragging) return
    const dx = e.clientX - this._startX
    this.el.style.transform = `translateX(${dx}px)`

    // Visual feedback tint
    const ratio = Math.min(Math.abs(dx) / (THRESHOLD * 2), 1)
    if (dx > 0) {
      this.el.style.boxShadow = `0 0 ${Math.round(ratio * 24)}px rgba(34,197,94,${ratio * 0.6})`
    } else if (dx < 0) {
      this.el.style.boxShadow = `0 0 ${Math.round(ratio * 24)}px rgba(239,68,68,${ratio * 0.6})`
    } else {
      this.el.style.boxShadow = ""
    }
  },

  _onPointerUp(e) {
    if (!this._dragging) return
    const dx = e.clientX - this._startX
    this._dragging = false
    this._detachMoveListeners()

    if (dx >= THRESHOLD) {
      this._commit("allow")
    } else if (dx <= -THRESHOLD) {
      this._commit("deny")
    } else {
      this._snapBack()
    }
  },

  _onPointerCancel() {
    this._dragging = false
    this._detachMoveListeners()
    this._snapBack()
  },

  _commit(decision) {
    const id = this.el.dataset.itemId
    // Animate off-screen then push
    const dir = decision === "allow" ? 1 : -1
    this.el.style.transition = "transform 200ms ease-out, opacity 200ms ease-out"
    this.el.style.transform  = `translateX(${dir * 120}%)`
    this.el.style.opacity    = "0"
    this.el.style.boxShadow  = ""
    setTimeout(() => {
      this.pushEvent("swipe_decide", { id, decision })
    }, 180)
  },

  _snapBack() {
    this.el.style.transition = "transform 300ms cubic-bezier(0.16,1,0.3,1), box-shadow 300ms ease"
    this.el.style.transform  = "translateX(0)"
    this.el.style.boxShadow  = ""
  },

  _detachMoveListeners() {
    this.el.removeEventListener("pointermove",   this._onPointerMove)
    this.el.removeEventListener("pointerup",     this._onPointerUp)
    this.el.removeEventListener("pointercancel", this._onPointerCancel)
  }
}

export default SwipeDecide
