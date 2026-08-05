import { Controller } from "@hotwired/stimulus"
import {
  Chart,
  BarController,
  BarElement,
  CategoryScale,
  LinearScale,
  Tooltip,
  Legend,
} from "chart.js"

Chart.register(BarController, BarElement, CategoryScale, LinearScale, Tooltip, Legend)

function token(name) {
  return getComputedStyle(document.documentElement).getPropertyValue(name).trim()
}

export default class extends Controller {
  static values = { type: String, data: Object, options: Object }

  connect() {
    this.draw()
    this.observer = new MutationObserver(() => this.redraw())
    this.observer.observe(document.documentElement, { attributeFilter: ["data-theme"] })
    this.media = window.matchMedia("(prefers-color-scheme: dark)")
    this.onScheme = () => this.redraw()
    this.media.addEventListener("change", this.onScheme)
  }

  disconnect() {
    this.observer?.disconnect()
    this.media?.removeEventListener("change", this.onScheme)
    this.chart?.destroy()
  }

  redraw() {
    this.chart?.destroy()
    this.draw()
  }

  draw() {
    const accent = token("--accent")
    const ink3 = token("--ink-3")
    const lineSoft = token("--line-soft")

    const data = {
      ...this.dataValue,
      datasets: this.dataValue.datasets.map((set) => ({
        backgroundColor: accent,
        borderRadius: 3,
        ...set,
      })),
    }

    const axis = {
      ticks: { color: ink3 },
      grid: { color: lineSoft, drawBorder: false },
      border: { display: false },
    }

    this.chart = new Chart(this.element, {
      type: this.typeValue,
      data: data,
      options: {
        ...this.optionsValue,
        scales: { x: axis, y: axis, ...(this.optionsValue.scales || {}) },
      },
    })
  }
}
