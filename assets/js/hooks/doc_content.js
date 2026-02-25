/**
 * DocContent hook for DocsLive.
 * Adds language labels and copy buttons to fenced code blocks.
 */
const DocContent = {
  mounted() {
    this.decorateCodeBlocks()
    this.renderMermaid()
  },

  updated() {
    this.decorateCodeBlocks()
    this.renderMermaid()
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
        try { window.mermaid.run({ nodes: Array.from(diagrams) }) }
        catch (e) { console.warn("Mermaid render error:", e) }
      } else if (attempts < 20) {
        setTimeout(() => tryRender(attempts + 1), 250)
      }
    }
    tryRender()
  },

  decorateCodeBlocks() {
    this.el.querySelectorAll("pre > code").forEach((code) => {
      const pre = code.parentElement
      if (pre.dataset.decorated) return

      pre.style.position = "relative"
      pre.dataset.decorated = "true"

      // Extract language from class like "elixir", "language-elixir", etc.
      const lang = Array.from(code.classList)
        .map((c) => c.replace(/^language-/, ""))
        .find((c) => c && c !== "highlight" && !c.startsWith("hljs"))

      // Container for label + copy button
      const toolbar = document.createElement("div")
      toolbar.className = "absolute top-2 right-2 flex items-center gap-2 select-none"

      if (lang) {
        const label = document.createElement("span")
        label.className =
          "text-[10px] uppercase tracking-wider text-base-content/30 font-mono"
        label.textContent = lang
        toolbar.appendChild(label)
      }

      // Copy button
      const btn = document.createElement("button")
      btn.className =
        "text-base-content/30 hover:text-base-content/60 transition-colors cursor-pointer"
      btn.title = "Copy code"
      btn.innerHTML = `<svg xmlns="http://www.w3.org/2000/svg" class="size-4" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" d="M15.75 17.25v3.375c0 .621-.504 1.125-1.125 1.125h-9.75a1.125 1.125 0 0 1-1.125-1.125V7.875c0-.621.504-1.125 1.125-1.125H6.75a9.06 9.06 0 0 1 1.5.124m7.5 10.376h3.375c.621 0 1.125-.504 1.125-1.125V11.25c0-4.46-3.243-8.161-7.5-8.876a9.06 9.06 0 0 0-1.5-.124H9.375c-.621 0-1.125.504-1.125 1.125v3.5m7.5 10.375H9.375a1.125 1.125 0 0 1-1.125-1.125v-9.25m12 6.625v-1.875a3.375 3.375 0 0 0-3.375-3.375h-1.5a1.125 1.125 0 0 1-1.125-1.125v-1.5a3.375 3.375 0 0 0-3.375-3.375H9.75" /></svg>`

      btn.addEventListener("click", () => {
        const text = code.textContent
        navigator.clipboard.writeText(text).then(() => {
          btn.innerHTML = `<span class="text-[10px] uppercase tracking-wider font-mono text-success">Copied!</span>`
          setTimeout(() => {
            btn.innerHTML = `<svg xmlns="http://www.w3.org/2000/svg" class="size-4" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" d="M15.75 17.25v3.375c0 .621-.504 1.125-1.125 1.125h-9.75a1.125 1.125 0 0 1-1.125-1.125V7.875c0-.621.504-1.125 1.125-1.125H6.75a9.06 9.06 0 0 1 1.5.124m7.5 10.376h3.375c.621 0 1.125-.504 1.125-1.125V11.25c0-4.46-3.243-8.161-7.5-8.876a9.06 9.06 0 0 0-1.5-.124H9.375c-.621 0-1.125.504-1.125 1.125v3.5m7.5 10.375H9.375a1.125 1.125 0 0 1-1.125-1.125v-9.25m12 6.625v-1.875a3.375 3.375 0 0 0-3.375-3.375h-1.5a1.125 1.125 0 0 1-1.125-1.125v-1.5a3.375 3.375 0 0 0-3.375-3.375H9.75" /></svg>`
          }, 1500)
        })
      })

      toolbar.appendChild(btn)
      pre.appendChild(toolbar)
    })
  },
}

export default DocContent
