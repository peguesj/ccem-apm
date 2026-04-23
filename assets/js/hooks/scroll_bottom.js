/**
 * ScrollBottom — auto-scrolls the element to the bottom whenever children
 * are mutated (new messages appended) or when the hook is first mounted.
 */
const ScrollBottom = {
  mounted() {
    this.scrollToBottom()
    this.observer = new MutationObserver(() => this.scrollToBottom())
    this.observer.observe(this.el, { childList: true, subtree: true })
  },
  updated() {
    this.scrollToBottom()
  },
  scrollToBottom() {
    this.el.scrollTop = this.el.scrollHeight
  },
  destroyed() {
    this.observer?.disconnect()
  }
}

export default ScrollBottom
