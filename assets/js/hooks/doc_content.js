/**
 * DocContent hook for DocsLive.
 * Syntax highlighting via highlight.js, line numbering,
 * language header bars with copy buttons, and Mermaid diagram rendering.
 */
import hljs from "highlight.js/lib/core"
import elixir from "highlight.js/lib/languages/elixir"
import javascript from "highlight.js/lib/languages/javascript"
import typescript from "highlight.js/lib/languages/typescript"
import bash from "highlight.js/lib/languages/bash"
import json from "highlight.js/lib/languages/json"
import swift from "highlight.js/lib/languages/swift"
import sql from "highlight.js/lib/languages/sql"
import yaml from "highlight.js/lib/languages/yaml"
import xml from "highlight.js/lib/languages/xml"
import css from "highlight.js/lib/languages/css"
import erlang from "highlight.js/lib/languages/erlang"

hljs.registerLanguage("elixir", elixir)
hljs.registerLanguage("javascript", javascript)
hljs.registerLanguage("js", javascript)
hljs.registerLanguage("typescript", typescript)
hljs.registerLanguage("ts", typescript)
hljs.registerLanguage("bash", bash)
hljs.registerLanguage("shell", bash)
hljs.registerLanguage("sh", bash)
hljs.registerLanguage("json", json)
hljs.registerLanguage("swift", swift)
hljs.registerLanguage("sql", sql)
hljs.registerLanguage("yaml", yaml)
hljs.registerLanguage("html", xml)
hljs.registerLanguage("xml", xml)
hljs.registerLanguage("css", css)
hljs.registerLanguage("erlang", erlang)

// Language display names and colors for header badges
const LANG_META = {
  elixir: { label: "Elixir", color: "#a855f7" },
  javascript: { label: "JavaScript", color: "#eab308" },
  js: { label: "JavaScript", color: "#eab308" },
  typescript: { label: "TypeScript", color: "#3b82f6" },
  ts: { label: "TypeScript", color: "#3b82f6" },
  bash: { label: "Bash", color: "#22c55e" },
  shell: { label: "Shell", color: "#22c55e" },
  sh: { label: "Shell", color: "#22c55e" },
  json: { label: "JSON", color: "#f97316" },
  html: { label: "HTML", color: "#ef4444" },
  xml: { label: "XML", color: "#ef4444" },
  css: { label: "CSS", color: "#3b82f6" },
  sql: { label: "SQL", color: "#06b6d4" },
  swift: { label: "Swift", color: "#f97316" },
  yaml: { label: "YAML", color: "#ec4899" },
  toml: { label: "TOML", color: "#8b5cf6" },
  erlang: { label: "Erlang", color: "#a3024a" },
  text: { label: "Text", color: "#6b7280" },
  mermaid: { label: "Diagram", color: "#10b981" },
}

const DocContent = {
  mounted() {
    this.processCodeBlocks()
    this.renderMermaid()
  },

  updated() {
    this.processCodeBlocks()
    this.renderMermaid()
  },

  /**
   * Pipeline: highlight → line numbers → header/copy → wrapper
   */
  processCodeBlocks() {
    this.el.querySelectorAll("pre > code").forEach((code) => {
      const pre = code.parentElement
      if (pre.dataset.decorated) return
      pre.dataset.decorated = "true"

      // Detect language from class (Earmark emits bare class like "elixir")
      const lang = this.detectLanguage(code)

      // Skip mermaid blocks entirely — they are handled by renderMermaid()
      if (lang === "mermaid") return

      // 1. Syntax highlighting
      if (lang && lang !== "text" && lang !== "mermaid") {
        try {
          if (hljs.getLanguage(lang)) {
            hljs.highlightElement(code)
          } else {
            // Try auto-detection for unknown languages
            const result = hljs.highlightAuto(code.textContent)
            if (result.language) {
              code.innerHTML = result.value
              code.classList.add(`hljs`, `language-${result.language}`)
            }
          }
        } catch (e) {
          // Silently fall back to plain text
        }
      }

      // 2. Line numbers (skip for very short blocks — 1-2 lines)
      const lineCount = (code.innerHTML.match(/\n/g) || []).length + 1
      if (lineCount > 2) {
        this.addLineNumbers(code, lineCount)
      }

      // 3. Header bar with language badge + copy button
      const meta = lang ? LANG_META[lang.toLowerCase()] || { label: lang, color: "#6b7280" } : null

      const header = document.createElement("div")
      header.className = "code-block-header"

      if (meta) {
        const badge = document.createElement("span")
        badge.className = "flex items-center gap-1.5 text-[11px] font-medium tracking-wide"
        badge.style.color = meta.color
        badge.innerHTML = `<span style="width:8px;height:8px;border-radius:50%;background:${meta.color};display:inline-block;opacity:0.7"></span>${meta.label}`
        header.appendChild(badge)
      } else {
        header.appendChild(document.createElement("span"))
      }

      // Copy button (copies raw text, not HTML)
      const rawText = code.textContent
      const btn = document.createElement("button")
      btn.className = "copy-btn"
      btn.textContent = "Copy"
      btn.addEventListener("click", () => {
        navigator.clipboard.writeText(rawText).then(() => {
          btn.textContent = "Copied!"
          btn.classList.add("copied")
          setTimeout(() => {
            btn.textContent = "Copy"
            btn.classList.remove("copied")
          }, 1500)
        })
      })
      header.appendChild(btn)

      // 4. Wrap pre in container with header
      const wrapper = document.createElement("div")
      wrapper.className = "code-block-wrapper"
      pre.parentNode.insertBefore(wrapper, pre)
      wrapper.appendChild(header)
      wrapper.appendChild(pre)
    })
  },

  /**
   * Extract language from code element classes.
   * Earmark emits bare class names like "elixir", "javascript", etc.
   */
  detectLanguage(code) {
    return Array.from(code.classList)
      .map((c) => c.replace(/^language-/, ""))
      .find((c) => c && c !== "highlight" && !c.startsWith("hljs"))
  },

  /**
   * Add line number gutter to a code block.
   * Wraps each line in a span with a data-line attribute for CSS numbering.
   */
  addLineNumbers(code, lineCount) {
    // Build gutter element
    const gutter = document.createElement("div")
    gutter.className = "code-line-numbers"
    gutter.setAttribute("aria-hidden", "true")

    const lines = []
    for (let i = 1; i <= lineCount; i++) {
      lines.push(`<span>${i}</span>`)
    }
    gutter.innerHTML = lines.join("\n")

    // Add gutter before code content
    const pre = code.parentElement
    pre.classList.add("has-line-numbers")
    pre.insertBefore(gutter, code)
  },

  renderMermaid() {
    const diagrams = this.el.querySelectorAll(".mermaid")
    if (!diagrams.length) return

    const tryRender = (attempts = 0) => {
      if (window.mermaid) {
        diagrams.forEach((el) => {
          if (el.dataset.processed) {
            el.removeAttribute("data-processed")
            el.innerHTML = el.dataset.src || el.textContent
          }
        })
        try {
          window.mermaid.run({ nodes: Array.from(diagrams) })
        } catch (e) {
          console.warn("Mermaid render error:", e)
        }
      } else if (attempts < 30) {
        setTimeout(() => tryRender(attempts + 1), 200)
      }
    }
    tryRender()
  },
}

export default DocContent
