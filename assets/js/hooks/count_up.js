/**
 * CountUp — animates a numeric value from its current displayed value to
 * the target specified in data-value.
 *
 * Attributes:
 *   data-value    target number (integer or float, required)
 *   data-decimals number of decimal places to render (default 0)
 *
 * Animation: 400ms ease-out via requestAnimationFrame.
 * On updated(): re-reads data-value and animates from the current rendered
 * value to the new target so repeated updates chain smoothly.
 */
const DURATION = 400

const CountUp = {
  mounted() {
    this._current = 0
    this._rafId   = null
    this._animate(0, this._target())
  },

  updated() {
    const from = this._current
    this._stop()
    this._animate(from, this._target())
  },

  destroyed() {
    this._stop()
  },

  _target() {
    return parseFloat(this.el.dataset.value || "0")
  },

  _decimals() {
    return parseInt(this.el.dataset.decimals || "0", 10)
  },

  _animate(from, to) {
    const decimals = this._decimals()
    const startTime = performance.now()
    const delta = to - from

    const tick = (now) => {
      const elapsed  = now - startTime
      const progress = Math.min(elapsed / DURATION, 1)
      // ease-out cubic
      const eased    = 1 - Math.pow(1 - progress, 3)
      this._current  = from + delta * eased
      this.el.textContent = this._current.toFixed(decimals)

      if (progress < 1) {
        this._rafId = requestAnimationFrame(tick)
      } else {
        this._current = to
        this.el.textContent = to.toFixed(decimals)
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
  }
}

export default CountUp
