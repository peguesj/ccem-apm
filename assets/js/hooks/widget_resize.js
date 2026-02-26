/**
 * WidgetResize Hook
 * Adds a drag handle to the bottom of any widget content div,
 * enabling the user to resize the widget height by dragging.
 * On release, sends a "widget_resize" event back to LiveView.
 */
const WidgetResize = {
  mounted() {
    this.widgetId = this.el.dataset.widgetId
    if (!this.widgetId) return

    // Find the content area (first div child with data-resizable)
    this.target = this.el.querySelector("[data-resizable]")
    if (!this.target) return

    // Create drag handle
    this.handle = document.createElement("div")
    this.handle.className = [
      "w-full h-1.5 rounded-b cursor-ns-resize opacity-0 hover:opacity-100",
      "bg-base-content/20 hover:bg-primary/50 transition-opacity duration-150",
      "flex items-center justify-center"
    ].join(" ")
    this.handle.title = "Drag to resize"

    this.el.appendChild(this.handle)

    this._onMouseDown = this.onMouseDown.bind(this)
    this.handle.addEventListener("mousedown", this._onMouseDown)
  },

  destroyed() {
    if (this.handle) {
      this.handle.removeEventListener("mousedown", this._onMouseDown)
    }
  },

  onMouseDown(e) {
    e.preventDefault()
    const startY = e.clientY
    const startH = this.target.offsetHeight

    const onMove = (e) => {
      const newH = Math.max(100, Math.min(900, startH + (e.clientY - startY)))
      this.target.style.height = newH + "px"
    }

    const onUp = (e) => {
      const newH = Math.max(100, Math.min(900, startH + (e.clientY - startY)))
      document.removeEventListener("mousemove", onMove)
      document.removeEventListener("mouseup", onUp)
      this.pushEvent("widget_resize", { id: this.widgetId, height: newH })
    }

    document.addEventListener("mousemove", onMove)
    document.addEventListener("mouseup", onUp)
  }
}

export default WidgetResize
