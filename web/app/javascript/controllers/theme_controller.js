import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["option"]

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
    if (!key) return

    const box = event.currentTarget.getBoundingClientRect()
    const pointer = event.clientX || event.clientY
    const at = pointer
      ? { x: event.clientX, y: event.clientY }
      : { x: box.left + box.width / 2, y: box.top + box.height / 2 }
    window.MnTheme?.pick(key, at)
  }

  render() {
    if (!window.MnTheme) return

    const { pinned } = window.MnTheme.state()
    const live = document.documentElement.getAttribute("data-theme")

    this.optionTargets.forEach((el) => {
      const key = el.dataset.themeKey
      el.setAttribute("aria-pressed", key === pinned ? "true" : "false")
      el.classList.toggle("on", key === live)
      el.classList.toggle("auto", !pinned && key === live)
    })
  }
}
