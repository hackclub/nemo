import { Controller } from "@hotwired/stimulus"

const KEY = "mn-theme"
const THEMES = ["system", "paper", "fog", "slate", "midnight", "ember"]

export default class extends Controller {
  connect() {
    this.render(this.current())
  }

  set(event) {
    const button = event.target.closest("[data-theme-set]")
    if (!button) return

    const theme = button.dataset.themeSet
    if (!THEMES.includes(theme)) return

    this.apply(theme)
    try {
      localStorage.setItem(KEY, theme)
    } catch (e) {}
    this.render(theme)
  }

  apply(theme) {
    const root = document.documentElement
    if (theme === "system") {
      root.removeAttribute("data-theme")
    } else {
      root.setAttribute("data-theme", theme)
    }
  }

  current() {
    const set = document.documentElement.getAttribute("data-theme")
    if (set === "dark") return "slate"
    if (set === "light") return "paper"

    return THEMES.includes(set) ? set : "system"
  }

  render(theme) {
    this.element.querySelectorAll("[data-theme-set]").forEach((button) => {
      button.setAttribute("aria-pressed", String(button.dataset.themeSet === theme))
    })
  }
}
