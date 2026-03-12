/**
 * ShiftSelect hook — capture-phase click interceptor for shift+click range selection.
 * Mount on a <table> element. Rows must have data-row-index attributes.
 * Elements with data-no-select will not trigger selection.
 *
 * Events pushed to LiveView:
 *   - range_select: { from: int, to: int }  — on shift+click
 */
const ShiftSelect = {
  mounted() {
    this._lastIdx = null;

    // Capture phase fires before Phoenix's bubble-phase handlers.
    this._clickHandler = (e) => {
      const row = e.target.closest("[data-row-index]");
      if (!row) return;

      // Skip clicks on action buttons and other non-select zones.
      if (e.target.closest("[data-no-select]")) return;

      const idx = parseInt(row.dataset.rowIndex, 10);
      if (isNaN(idx)) return;

      if (e.shiftKey && this._lastIdx !== null) {
        // Range select — stop the event so the row's phx-click doesn't also fire.
        e.preventDefault();
        e.stopPropagation();
        const from = Math.min(this._lastIdx, idx);
        const to = Math.max(this._lastIdx, idx);
        this.pushEvent("range_select", { from, to });
        // Intentionally do NOT update lastIdx — anchor stays fixed.
      } else {
        // Normal click — just track the anchor index. Phoenix handles toggle_row.
        this._lastIdx = idx;
      }
    };
    this.el.addEventListener("click", this._clickHandler, true /* capture phase */);
  },

  destroyed() {
    this._lastIdx = null;
    if (this._clickHandler) {
      this.el.removeEventListener("click", this._clickHandler, true);
    }
  }
};

export default ShiftSelect;
