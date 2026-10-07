import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["option", "accent", "name", "swatch"]

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

    window.MnTheme?.pick(key, this.origin(event))
  }

  tint(event) {
    if (!window.MnTheme) return

    window.MnTheme.tint(!window.MnTheme.state().accent, this.origin(event))
  }

  origin(event) {
    const box = event.currentTarget.getBoundingClientRect()
    const pointer = event.clientX || event.clientY
    return pointer
      ? { x: event.clientX, y: event.clientY }
      : { x: box.left + box.width / 2, y: box.top + box.height / 2 }
  }

  render() {
    if (!window.MnTheme) return

    const { pinned, accent } = window.MnTheme.state()
    const live = document.documentElement.getAttribute("data-theme")

    this.optionTargets.forEach((el) => {
      const key = el.dataset.themeKey
      el.setAttribute("aria-pressed", key === pinned ? "true" : "false")
      el.classList.toggle("on", key === live)
      el.classList.toggle("auto", !pinned && key === live)
    })

    this.accentTargets.forEach((el) => {
      if (el.type === "checkbox") el.checked = Boolean(accent)
      else el.setAttribute("aria-pressed", accent ? "true" : "false")
    })

    this.mirror(this.optionTargets.find((el) => el.dataset.themeKey === live), pinned)
  }

  mirror(option, pinned) {
    if (!option) return

    if (this.hasNameTarget) {
      const label = option.querySelector(".theme-name")?.textContent
      this.nameTarget.textContent = pinned ? label : `${label}, auto`
    }
    if (this.hasSwatchTarget) {
      const chip = option.querySelector(".theme-chip")
      this.swatchTarget.style.setProperty("--chip",
        chip ? chip.style.getPropertyValue("--chip") : "")
    }
  }
}
