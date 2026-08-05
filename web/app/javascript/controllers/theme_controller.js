import { Controller } from "@hotwired/stimulus"

const KEY = "mn-theme"

export default class extends Controller {
  connect() {
    this.render(this.current())
  }

  toggle() {
    const next = this.current() === "dark" ? "light" : "dark"
    document.documentElement.setAttribute("data-theme", next)
    try {
      localStorage.setItem(KEY, next)
    } catch (e) {}
    this.render(next)
  }

  current() {
    const set = document.documentElement.getAttribute("data-theme")
    if (set === "dark" || set === "light") return set

    return window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light"
  }

  render(theme) {
    this.element.setAttribute("aria-checked", theme === "dark" ? "true" : "false")
  }
}
