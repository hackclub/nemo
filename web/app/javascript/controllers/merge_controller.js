import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["count", "ids"]

  connect() {
    this.refresh()
  }

  refresh() {
    const ticked = this.element.querySelectorAll("input.tick-case:checked")
    const numbers = Array.from(ticked, (box) => `#${box.value}`)

    this.countTarget.textContent = numbers.length
    this.idsTarget.textContent = numbers.join(", ")
  }
}
