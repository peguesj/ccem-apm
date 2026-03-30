// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/apm_v5"
import topbar from "../vendor/topbar"

import DependencyGraph from "./hooks/dependency_graph"
import RalphFlowchart from "./hooks/ralph_flowchart"
import WidgetResize from "./hooks/widget_resize"
import SessionTimeline from "./hooks/session_timeline"
import FormationGraph from "./hooks/formation_graph"
import Toast from "./hooks/toast"
import DocContent from "./hooks/doc_content"
import WorkflowGraph from "./hooks/workflow_graph"
import ShiftSelect from "./hooks/shift_select"
import TooltipOverlay from "./hooks/tooltip_overlay"
import InspectorChat from "./hooks/inspector_chat"
import GettingStartedShowcase from "./hooks/getting_started_showcase"
import GettingStartedDashboard from "./hooks/getting_started_dashboard"
import ShowcaseHook from "./hooks/showcase"
import LoadContext from "./hooks/load_context"
import CcemAssistant from "./hooks/ccem_assistant"
import SkillsHook from "./hooks/skills"
import ShowcaseSyncHook from "./hooks/showcase_sync"
import AlignmentGraph from "./hooks/alignment_graph"

// Custom hooks for LiveView
const Hooks = {
  Clock: {
    mounted() {
      this.interval = setInterval(() => {
        const now = new Date()
        this.el.textContent = now.toLocaleTimeString("en-US", { hour12: false })
      }, 1000)
    },
    destroyed() {
      clearInterval(this.interval)
    }
  },
  CountdownTimer: {
    mounted() {
      const seconds = parseInt(this.el.dataset.seconds || "20", 10)
      const display = this.el.querySelector("[data-countdown-display]")
      let remaining = seconds

      this._timer = setInterval(() => {
        remaining -= 1
        if (display) display.textContent = remaining > 0 ? `${remaining}s` : "expired"
        if (remaining <= 0) {
          clearInterval(this._timer)
          this.el.classList.add("opacity-40", "pointer-events-none")
          if (display) display.classList.add("text-zinc-500")
        }
      }, 1000)
    },
    destroyed() {
      clearInterval(this._timer)
    }
  },
  DependencyGraph,
  RalphFlowchart,
  WidgetResize,
  SessionTimeline,
  FormationGraph,
  Toast,
  WorkflowGraph,
  DocContent,
  ShiftSelect,
  TooltipOverlay,
  InspectorChat,
  GettingStartedShowcase,
  GettingStartedDashboard,
  ShowcaseHook,
  LoadContext,
  CcemAssistant,
  SkillsHook,
  ShowcaseSyncHook,
  AlignmentGraph
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, ...Hooks},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

