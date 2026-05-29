// TableKeyNav — keyboard navigation for ds-data-table tables.
// Referenced by `data_table/1` in components/design_system.ex.
//
// Behavior:
//   - On mount, mark all tbody rows tabindex="-1" and the first tabindex="0".
//   - ArrowDown / ArrowUp move focus among rows.
//   - Home / End jump to first / last.
//   - Enter triggers a click on the focused row (so phx-click bindings fire).
//
// This was the missing hook surfaced by the v10.3.0 UAT crawl —
// `phx-hook="TableKeyNav"` was referenced on 6+ pages but never registered,
// emitting `unknown hook found for "TableKeyNav"` on every mount (CP-310).

const TableKeyNav = {
  mounted() {
    const rows = this._rows();
    if (!rows.length) return;

    rows.forEach((row, idx) => {
      row.setAttribute("tabindex", idx === 0 ? "0" : "-1");
      row.dataset.tableKeyNavIdx = String(idx);
    });

    this._onKeyDown = (e) => this._handleKey(e);
    this.el.addEventListener("keydown", this._onKeyDown);
  },

  updated() {
    // Re-index after LiveView patches change the row set.
    const rows = this._rows();
    rows.forEach((row, idx) => {
      if (!row.hasAttribute("tabindex")) {
        row.setAttribute("tabindex", "-1");
      }
      row.dataset.tableKeyNavIdx = String(idx);
    });
  },

  destroyed() {
    if (this._onKeyDown) {
      this.el.removeEventListener("keydown", this._onKeyDown);
    }
  },

  _rows() {
    return Array.from(this.el.querySelectorAll("tbody tr"));
  },

  _handleKey(e) {
    const rows = this._rows();
    if (!rows.length) return;

    const active = document.activeElement;
    const currentIdx = rows.indexOf(active);

    let nextIdx = null;
    switch (e.key) {
      case "ArrowDown":
        nextIdx = currentIdx < 0 ? 0 : Math.min(currentIdx + 1, rows.length - 1);
        break;
      case "ArrowUp":
        nextIdx = currentIdx < 0 ? 0 : Math.max(currentIdx - 1, 0);
        break;
      case "Home":
        nextIdx = 0;
        break;
      case "End":
        nextIdx = rows.length - 1;
        break;
      case "Enter":
        if (currentIdx >= 0) {
          e.preventDefault();
          rows[currentIdx].click();
        }
        return;
      default:
        return;
    }

    if (nextIdx !== null) {
      e.preventDefault();
      if (currentIdx >= 0) rows[currentIdx].setAttribute("tabindex", "-1");
      rows[nextIdx].setAttribute("tabindex", "0");
      rows[nextIdx].focus();
      rows[nextIdx].scrollIntoView({ block: "nearest" });
    }
  },
};

export default TableKeyNav;
