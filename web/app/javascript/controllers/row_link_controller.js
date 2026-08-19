import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { href: String }

  go(event) {
    if (event.target.closest("a, button, input, label, summary, details")) return

    const drawer = document.getElementById("case-drawer")
    if (drawer) drawer.src = this.hrefValue
  }
}
