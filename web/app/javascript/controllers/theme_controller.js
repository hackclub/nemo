import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["option", "follow", "ratio"]

  connect() {
    this.onTheme = () => this.render()
    document.addEventListener("mn:theme", this.onTheme)
    this.render()
  }

  disconnect() {
    document.removeEventListener("mn:theme", this.onTheme)
  }

  pick(event) {
    const key = event.currentTarget.dataset.themeKey
    if (key) window.MnTheme?.pick(key)
  }

  follow(event) {
    window.MnTheme?.follow(event.currentTarget.getAttribute("aria-checked") !== "true")
  }

  render() {
    const api = window.MnTheme
    if (!api) return

    const state = api.state()
    const live = document.documentElement.getAttribute("data-theme")

    this.optionTargets.forEach((el) => {
      const key = el.dataset.themeKey
      el.setAttribute("aria-pressed", !state.follow && key === state.pinned ? "true" : "false")
      el.classList.toggle("on", key === live)
      el.classList.toggle("auto", state.follow && key === live)
    })

    this.followTargets.forEach((el) => {
      el.setAttribute("aria-checked", state.follow ? "true" : "false")
    })

    this.measure()
  }

  measure() {
    if (!this.hasRatioTarget) return

    const css = getComputedStyle(document.documentElement)
    const read = (name) => css.getPropertyValue(name).trim()

    this.ratioTargets.forEach((el) => {
      const pair = el.dataset.pair.split("/")
      const value = contrast(read(`--${pair[0]}`), read(`--${pair[1]}`))
      el.textContent = value ? `${value.toFixed(1)}:1` : "n/a"
    })
  }
}

function contrast(a, b) {
  const ya = luminance(a)
  const yb = luminance(b)
  if (ya == null || yb == null) return null

  return (Math.max(ya, yb) + 0.05) / (Math.min(ya, yb) + 0.05)
}

const probe = document.createElement("canvas").getContext("2d", { willReadFrequently: true })

function luminance(colour) {
  if (!colour) return null

  probe.canvas.width = probe.canvas.height = 1
  probe.clearRect(0, 0, 1, 1)
  probe.fillStyle = "#000"
  probe.fillStyle = colour
  probe.fillRect(0, 0, 1, 1)

  const [r, g, b] = probe.getImageData(0, 0, 1, 1).data
  const lin = (v) => {
    const s = v / 255
    return s <= 0.03928 ? s / 12.92 : Math.pow((s + 0.055) / 1.055, 2.4)
  }

  return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
}
