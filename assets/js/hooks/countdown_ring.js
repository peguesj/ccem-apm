/**
 * CountdownRing — conic-gradient arc that drains over a TTL window.
 *
 * Attributes:
 *   data-ttl-ms     total duration in milliseconds (required)
 *   data-elapsed-ms milliseconds already consumed when mounted/updated (default 0)
 *
 * The element must have a defined width/height and border-radius:50% so the
 * conic-gradient renders as a circle. The hook writes the gradient directly on
 * el.style.background and keeps the RAF loop running until destroyed.
 */
const CountdownRing = {
  mounted() {
    this._start()
  },

  updated() {
    this._stop()
    this._start()
  },

  destroyed() {
    this._stop()
  },

  _start() {
    const ttl = parseInt(this.el.dataset.ttlMs || "20000", 10)
    const elapsed = parseInt(this.el.dataset.elapsedMs || "0", 10)

    if (ttl <= 0) {
      this._setDeg(0)
      return
    }

    const startTime = performance.now()
    const startRemaining = Math.max(0, ttl - elapsed)

    const tick = (now) => {
      const delta = now - startTime
      const remaining = Math.max(0, startRemaining - delta)
      const fraction = remaining / ttl
      const deg = Math.round(fraction * 360)
      this._setDeg(deg)

      if (remaining > 0 && this._rafId !== null) {
        this._rafId = requestAnimationFrame(tick)
      } else {
        this._rafId = null
      }
    }

    this._rafId = requestAnimationFrame(tick)
  },

  _stop() {
    if (this._rafId != null) {
      cancelAnimationFrame(this._rafId)
      this._rafId = null
    }
  },

  _setDeg(deg) {
    this.el.style.background =
      `conic-gradient(var(--apm-accent, #6366f1) ${deg}deg, transparent 0)`
  }
}

export default CountdownRing
