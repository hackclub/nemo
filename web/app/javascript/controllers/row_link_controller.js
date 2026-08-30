import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { href: String }

  go(event) {
    if (event.target.closest("a, button, input, label, summary, details")) return
    if (event.metaKey || event.ctrlKey || event.shiftKey || event.button !== 0) return

    if (window.Turbo) {
      window.Turbo.visit(this.hrefValue)
    } else {
      window.location.href = this.hrefValue
    }
  }
}
