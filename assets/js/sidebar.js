const STORAGE_KEY = "apm_sidebar_collapsed";
const SIDEBAR_ID = "apm-sidebar";
const COLLAPSED_CLASS = "sidebar-collapsed";

window.apmSidebar = {
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
};

window.apmSidebar.init();
