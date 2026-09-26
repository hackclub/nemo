import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { href: String }

  connect() {
    if (!this.element.hasAttribute("tabindex")) {
      this.element.setAttribute("tabindex", "0")
      this.element.setAttribute("role", "link")
    }
  }

  go(event) {
    if (event.target.closest("a, button, input, label, summary, details")) return
    if (event.key && event.key !== "Enter") return
    if (!event.key && (event.metaKey || event.ctrlKey || event.shiftKey || event.button !== 0)) return

    if (window.Turbo) {
      window.Turbo.visit(this.hrefValue)
    } else {
      window.location.href = this.hrefValue
    }
  }
}
