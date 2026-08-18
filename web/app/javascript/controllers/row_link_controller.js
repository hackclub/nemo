import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"

export default class extends Controller {
  static values = { href: String }

  go(event) {
    if (event.target.closest("a, button, input, label, summary, details")) return

    Turbo.visit(this.hrefValue)
  }
}
