/**
 * DrawerResize — drag-to-resize hook for the ConversationDrawer.
 *
 * Behaviour:
 *  - Mousedown on the resize handle starts a resize operation.
 *  - Mousemove updates the drawer height (clamped: min 56px, max 90vh).
 *  - Mouseup commits the height and pushes a `drawer_resized` event to the
 *    LiveView with the final pixel value.
 *  - Double-click on the handle toggles between collapsed (56px) and the
 *    default height stored in `data-default-height` (falls back to 40vh).
 *
 * Expected DOM structure:
 *   <div phx-hook="DrawerResize" data-default-height="400">
 *     <div data-resize-handle> <!-- drag target --> </div>
 *     ...drawer content...
 *   </div>
 */
const DrawerResize = {
  mounted() {
    this._defaultHeight = parseInt(this.el.dataset.defaultHeight || "400", 10)
    this._minHeight = 56
    this._maxHeightVh = 90
    this._dragging = false
    this._startY = 0
    this._startHeight = 0

    this._handle = this.el.querySelector("[data-resize-handle]")
    if (!this._handle) return

    this._onMousedown = this._onMousedown.bind(this)
    this._onMousemove = this._onMousemove.bind(this)
    this._onMouseup = this._onMouseup.bind(this)
    this._onDblclick = this._onDblclick.bind(this)

    this._handle.addEventListener("mousedown", this._onMousedown)
    this._handle.addEventListener("dblclick", this._onDblclick)
  },

  destroyed() {
    if (!this._handle) return
    this._handle.removeEventListener("mousedown", this._onMousedown)
    this._handle.removeEventListener("dblclick", this._onDblclick)
    document.removeEventListener("mousemove", this._onMousemove)
    document.removeEventListener("mouseup", this._onMouseup)
  },

  _maxHeightPx() {
    return Math.floor(window.innerHeight * this._maxHeightVh / 100)
  },

  _clamp(value) {
    return Math.max(this._minHeight, Math.min(this._maxHeightPx(), value))
  },

  _currentHeight() {
    return this.el.getBoundingClientRect().height
  },

  _applyHeight(px) {
    this.el.style.height = `${px}px`
  },

  _onMousedown(e) {
    e.preventDefault()
    this._dragging = true
    this._startY = e.clientY
    this._startHeight = this._currentHeight()
    document.addEventListener("mousemove", this._onMousemove)
    document.addEventListener("mouseup", this._onMouseup)
    document.body.style.userSelect = "none"
  },

  _onMousemove(e) {
    if (!this._dragging) return
    // Handle is at the top of the drawer — dragging up increases height.
    const delta = this._startY - e.clientY
    const newHeight = this._clamp(this._startHeight + delta)
    this._applyHeight(newHeight)
  },

  _onMouseup(e) {
    if (!this._dragging) return
    this._dragging = false
    document.removeEventListener("mousemove", this._onMousemove)
    document.removeEventListener("mouseup", this._onMouseup)
    document.body.style.userSelect = ""

    const finalHeight = this._clamp(this._currentHeight())
    this._applyHeight(finalHeight)
    this.pushEvent("drawer_resized", { height: finalHeight })
  },

  _onDblclick(_e) {
    const current = this._currentHeight()
    if (current <= this._minHeight + 4) {
      // Currently collapsed — expand to default
      const h = this._clamp(this._defaultHeight)
      this._applyHeight(h)
      this.pushEvent("drawer_resized", { height: h })
    } else {
      // Currently open — collapse
      this._applyHeight(this._minHeight)
      this.pushEvent("drawer_resized", { height: this._minHeight })
    }
  }
}

export default DrawerResize
