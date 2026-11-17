import { Controller } from "@hotwired/stimulus"

const DURATION_MS = 900
const LEADING_NUMBER = /^(\d[\d,]*)(.*)$/s
const NUMBER_FORMAT = new Intl.NumberFormat("en-US")

export default class extends Controller {
  static reconnectOnMorph = false

  connect() {
    this.frames = new Set()
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return

    this.element.querySelectorAll(".metric-value").forEach((node) => this.run(node))
  }

  disconnect() {
    this.frames.forEach((frame) => cancelAnimationFrame(frame))
    this.frames.clear()
  }

  run(node) {
    const text = node.textContent.trim()
    const match = text.match(LEADING_NUMBER)
    if (!match) return

    const target = Number(match[1].replaceAll(",", ""))
    if (!Number.isFinite(target) || target === 0) return

    const suffix = match[2]
    const startedAt = performance.now()
    const step = (now) => {
      const progress = Math.min((now - startedAt) / DURATION_MS, 1)
      if (progress === 1) {
        node.textContent = text
        return
      }

      const eased = 1 - Math.pow(1 - progress, 3)
      node.textContent = `${NUMBER_FORMAT.format(Math.round(target * eased))}${suffix}`
      this.request(step)
    }
    this.request(step)
  }

  request(step) {
    const frame = requestAnimationFrame((now) => {
      this.frames.delete(frame)
      step(now)
    })
    this.frames.add(frame)
  }
}
