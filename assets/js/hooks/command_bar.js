/**
 * CommandBar JS Hook
 *
 * Handles:
 *  - Global Cmd+K / Ctrl+K to toggle the command bar
 *  - Arrow key navigation (up/down)
 *  - Enter to select the highlighted item
 *  - Escape to close
 *  - Backdrop click (handled server-side via phx-click)
 *  - Focus trapping and body scroll lock while open
 */

const STORAGE_KEY = "apm:command-bar-recent"
const MAX_RECENT = 5

export const CommandBarHook = {
  mounted() {
    this._open = false

    this._onKeydown = (e) => {
      // Cmd+K (macOS) or Ctrl+K (Windows/Linux) — toggle
      if ((e.metaKey || e.ctrlKey) && e.key === "k") {
        e.preventDefault()
        e.stopPropagation()
        this.pushEvent("toggle_command_bar", {})
        return
      }

      if (!this._open) return

      switch (e.key) {
        case "ArrowDown":
          e.preventDefault()
          this.pushEvent("command_bar_navigate", { direction: "down" })
          break

        case "ArrowUp":
          e.preventDefault()
          this.pushEvent("command_bar_navigate", { direction: "up" })
          break

        case "Enter":
          e.preventDefault()
          this.pushEvent("command_bar_select", {})
          break

        case "Escape":
          e.preventDefault()
          this.pushEvent("close_command_bar", {})
          break
      }
    }

    document.addEventListener("keydown", this._onKeydown, true)

    // Observer: watch for the modal appearing/disappearing to manage body scroll
    this._observer = new MutationObserver(() => this._syncState())
    this._observer.observe(this.el, { childList: true, subtree: false })
  },

  updated() {
    this._syncState()
  },

  destroyed() {
    document.removeEventListener("keydown", this._onKeydown, true)
    if (this._observer) this._observer.disconnect()
    this._unlockScroll()
  },

  // -------------------------------------------------------------------------
  // Internal helpers
  // -------------------------------------------------------------------------

  _syncState() {
    const modal = this.el.querySelector(".command-bar-modal")
    const isOpen = !!modal

    if (isOpen && !this._open) {
      this._open = true
      this._lockScroll()
      // Autofocus the input on next tick (after LiveView patch)
      requestAnimationFrame(() => {
        const input = document.getElementById("command-bar-input")
        if (input) input.focus()
      })
    } else if (!isOpen && this._open) {
      this._open = false
      this._unlockScroll()
    }
  },

  _lockScroll() {
    document.body.style.overflow = "hidden"
  },

  _unlockScroll() {
    document.body.style.overflow = ""
  },

  // Store a recently visited path for "Recent" section (future use)
  _recordRecent(label, path) {
    try {
      const recent = JSON.parse(localStorage.getItem(STORAGE_KEY) || "[]")
      const filtered = recent.filter((r) => r.path !== path)
      const updated = [{ label, path }, ...filtered].slice(0, MAX_RECENT)
      localStorage.setItem(STORAGE_KEY, JSON.stringify(updated))
    } catch (_) {
      // localStorage unavailable — silently ignore
    }
  },

  getRecent() {
    try {
      return JSON.parse(localStorage.getItem(STORAGE_KEY) || "[]")
    } catch (_) {
      return []
    }
  }
}

export default CommandBarHook
