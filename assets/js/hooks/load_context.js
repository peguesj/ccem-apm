/**
 * LoadContext — LiveView hook for lazy-loading notification context panels.
 *
 * Mounted on hidden <span> elements inside collapsible formation/UPM panels.
 * On mount, fires the "load_context" server event with id + type so the
 * LiveView can populate `lazy_context` for that notification.
 */
const LoadContext = {
  mounted() {
    const id = this.el.getAttribute("phx-value-id") || this.el.dataset.id
    const type = this.el.getAttribute("phx-value-type") || this.el.dataset.type
    if (id && type) {
      this.pushEvent("load_context", { id, type })
    }
  }
}

export default LoadContext
