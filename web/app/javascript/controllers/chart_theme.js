import { Controller } from "@hotwired/stimulus"

export function palette() {
  const css = getComputedStyle(document.documentElement)
  const token = (name) => css.getPropertyValue(name).trim()

  return {
    accent: token("--accent"),
    warn: token("--warn"),
    ink: token("--ink"),
    ink2: token("--ink-2"),
    ink3: token("--ink-3"),
    line: token("--line"),
    lineSoft: token("--line-soft"),
    card: token("--card")
  }
}

export class ThemedChartController extends Controller {
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
    throw new Error("themed chart controllers must implement draw()")
  }
}
