const STORAGE_KEY = "apm_sidebar_collapsed";
const SIDEBAR_ID = "apm-sidebar";
const COLLAPSED_CLASS = "sidebar-collapsed";

// CP-309 — root.html.heex inline script defines window.apmSidebar with
// {toggle, toggleGroup, restoreGroups}. This file used to overwrite it with a
// reduced version causing TypeError: window.apmSidebar.restoreGroups is not a
// function on every page-loading-stop event. Merge instead of replace.
window.apmSidebar = Object.assign(window.apmSidebar || {}, {
  toggle() {
    const sidebar = document.getElementById(SIDEBAR_ID);
    if (!sidebar) return;
    const collapsed = sidebar.classList.toggle(COLLAPSED_CLASS);
    try {
      localStorage.setItem(STORAGE_KEY, collapsed ? "1" : "0");
    } catch (_) {
      // localStorage unavailable — non-fatal
    }
  },

  init() {
    const sidebar = document.getElementById(SIDEBAR_ID);
    if (!sidebar) return;
    try {
      if (localStorage.getItem(STORAGE_KEY) === "1") {
        sidebar.classList.add(COLLAPSED_CLASS);
      }
    } catch (_) {
      // localStorage unavailable — skip restore
    }
  },
});

// Defensive: ensure restoreGroups is always a function so the inline
// page-loading-stop handler never throws even if the root layout script
// didn't define it (e.g. minimal layouts in tests / embedded pages).
if (typeof window.apmSidebar.restoreGroups !== "function") {
  window.apmSidebar.restoreGroups = function () { /* no-op */ };
}

window.apmSidebar.init();
