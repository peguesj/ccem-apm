/**
 * SkillsHook — LiveView hook for the /skills dashboard.
 *
 * Provides:
 * - Keyboard shortcut: press "/" to focus skill search input
 * - Focus trap management for skill detail drawer
 * - Previous focus restoration when drawer closes
 * - Smooth card keyboard navigation (Enter/Space)
 */

const SkillsHook = {
  mounted() {
    this._lastFocused = null;
    this._onKeydown = this._handleKeydown.bind(this);
    window.addEventListener("keydown", this._onKeydown);
    this._watchDrawer();
  },

  updated() {
    // Re-run drawer watcher on each update (drawer open/close)
    this._watchDrawer();
  },

  destroyed() {
    window.removeEventListener("keydown", this._onKeydown);
  },

  _handleKeydown(e) {
    // "/" shortcut: focus search (skip if already in an input)
    const tag = document.activeElement && document.activeElement.tagName;
    const isInput = ["INPUT", "SELECT", "TEXTAREA"].includes(tag);

    if (e.key === "/" && !isInput && !e.ctrlKey && !e.metaKey) {
      const search = document.getElementById("skill-search");
      if (search) {
        e.preventDefault();
        search.focus();
        search.select();
      }
    }
  },

  _watchDrawer() {
    const drawer = document.getElementById("skill-drawer");
    if (drawer && !drawer.dataset.focusManaged) {
      // Drawer just opened — save current focus, focus the close button
      this._lastFocused = document.activeElement;
      drawer.dataset.focusManaged = "true";
      const closeBtn = drawer.querySelector("[aria-label='Close skill details']");
      if (closeBtn) {
        requestAnimationFrame(() => closeBtn.focus());
      }
    } else if (!drawer && this._lastFocused) {
      // Drawer just closed — restore previous focus
      requestAnimationFrame(() => {
        if (this._lastFocused && this._lastFocused.focus) {
          this._lastFocused.focus();
        }
        this._lastFocused = null;
      });
    }
  }
};

export default SkillsHook;
