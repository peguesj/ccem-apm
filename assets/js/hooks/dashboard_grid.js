/**
 * DashboardGrid LiveView Hook
 *
 * Enables drag-to-reorder of dashboard widget cells using native HTML5
 * drag-and-drop API (no external dependencies required).
 *
 * On drag-end, fires `layout_reorder` event to LiveView with the new
 * widget order as an array of widget_id strings.
 *
 * The inner grid container (`#dashboard-grid-inner`) uses `phx-update="ignore"`
 * to prevent LiveView from overwriting DOM changes during drag operations.
 *
 * ## LiveView Event
 *
 *   `layout_reorder` — payload: { order: ["widget_a", "widget_b", ...] }
 *
 * ## Usage
 *
 *   <div id="dashboard-grid-outer" phx-hook="DashboardGrid">
 *     <div id="dashboard-grid-inner" phx-update="ignore">
 *       <div data-widget-id="agent_fleet" class="cursor-grab ...">...</div>
 *       ...
 *     </div>
 *   </div>
 */
const DashboardGrid = {
  mounted() {
    this.gridContainer = this.el.querySelector('#dashboard-grid-inner') || this.el
    this._dragSrc = null
    this._initDragHandlers()
  },

  updated() {
    // Re-initialize if the outer container reference changed
    this.gridContainer = this.el.querySelector('#dashboard-grid-inner') || this.el
    this._initDragHandlers()
  },

  destroyed() {
    if (this.gridContainer) {
      this.gridContainer.querySelectorAll('[data-widget-id]').forEach(cell => {
        cell.removeEventListener('dragstart', this._onDragStart)
        cell.removeEventListener('dragend', this._onDragEnd)
        cell.removeEventListener('dragover', this._onDragOver)
        cell.removeEventListener('drop', this._onDrop)
      })
    }
  },

  _initDragHandlers() {
    if (!this.gridContainer) return

    const cells = this.gridContainer.querySelectorAll('[data-widget-id]')

    cells.forEach(cell => {
      // Remove old listeners before adding new ones to avoid duplicates
      cell.removeEventListener('dragstart', this._onDragStart)
      cell.removeEventListener('dragend', this._onDragEnd)
      cell.removeEventListener('dragover', this._onDragOver)
      cell.removeEventListener('drop', this._onDrop)
      cell.removeEventListener('dragleave', this._onDragLeave)

      cell.setAttribute('draggable', 'true')

      this._onDragStart = (e) => this._handleDragStart(e, cell)
      this._onDragEnd = (e) => this._handleDragEnd(e)
      this._onDragOver = (e) => this._handleDragOver(e, cell)
      this._onDrop = (e) => this._handleDrop(e, cell)
      this._onDragLeave = (e) => this._handleDragLeave(e, cell)

      cell.addEventListener('dragstart', this._onDragStart)
      cell.addEventListener('dragend', this._onDragEnd)
      cell.addEventListener('dragover', this._onDragOver)
      cell.addEventListener('drop', this._onDrop)
      cell.addEventListener('dragleave', this._onDragLeave)
    })
  },

  _handleDragStart(e, cell) {
    this._dragSrc = cell
    cell.classList.add('opacity-50', 'ring-2', 'ring-primary', 'cursor-grabbing')
    e.dataTransfer.effectAllowed = 'move'
    e.dataTransfer.setData('text/plain', cell.dataset.widgetId || '')
  },

  _handleDragEnd(e) {
    if (this._dragSrc) {
      this._dragSrc.classList.remove('opacity-50', 'ring-2', 'ring-primary', 'cursor-grabbing')
      this._dragSrc = null
    }
    // Remove all drag-over indicators
    this.gridContainer.querySelectorAll('[data-widget-id]').forEach(c => {
      c.classList.remove('border-primary', 'border-2', 'bg-primary/5')
    })
    // Emit new order
    const order = this._collectOrder()
    if (order.length > 0) {
      this.pushEvent('layout_reorder', { order })
    }
  },

  _handleDragOver(e, cell) {
    if (!this._dragSrc || this._dragSrc === cell) return
    e.preventDefault()
    e.dataTransfer.dropEffect = 'move'
    cell.classList.add('border-primary', 'border-2', 'bg-primary/5')
  },

  _handleDragLeave(e, cell) {
    cell.classList.remove('border-primary', 'border-2', 'bg-primary/5')
  },

  _handleDrop(e, cell) {
    e.preventDefault()
    e.stopPropagation()

    if (!this._dragSrc || this._dragSrc === cell) return

    cell.classList.remove('border-primary', 'border-2', 'bg-primary/5')

    // Reorder: insert dragSrc before drop target
    const parent = this.gridContainer
    const cells = [...parent.querySelectorAll('[data-widget-id]')]
    const srcIdx = cells.indexOf(this._dragSrc)
    const dstIdx = cells.indexOf(cell)

    if (srcIdx < dstIdx) {
      parent.insertBefore(this._dragSrc, cell.nextSibling)
    } else {
      parent.insertBefore(this._dragSrc, cell)
    }
  },

  _collectOrder() {
    if (!this.gridContainer) return []
    return [...this.gridContainer.querySelectorAll('[data-widget-id]')]
      .map(cell => cell.dataset.widgetId)
      .filter(Boolean)
  }
}

export default DashboardGrid
