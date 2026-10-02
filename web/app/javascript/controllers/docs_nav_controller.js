import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  go(event) {
    const link = event.target.closest("a[href^='#']")
    if (!link || !this.element.contains(link)) return

    const id = link.getAttribute("href").slice(1)
    const section = document.getElementById(id)
    if (!section) return

    event.preventDefault()
    section.scrollIntoView({ behavior: this.easing, block: "start" })
    history.replaceState(history.state, "", `#${id}`)
  }

  get easing() {
    return matchMedia("(prefers-reduced-motion: reduce)").matches ? "auto" : "smooth"
  }
}
