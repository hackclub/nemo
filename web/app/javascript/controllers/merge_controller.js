import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["count", "ids"]
  static values = { url: String }

  connect() {
    this.refresh()
  }

  refresh() {
    const numbers = this.ticked().map((box) => `#${box.value}`)

    this.countTarget.textContent = numbers.length
    this.idsTarget.textContent = numbers.join(", ")
  }

  confirm(event) {
    const frame = document.getElementById("merge-body")
    const flip = document.getElementById("merge-case")
    const ticked = this.ticked()
    if (!frame || !flip || ticked.length < 2) return

    event.preventDefault()
    const asked = new URLSearchParams()
    ticked.forEach((box) => asked.append("case_ids[]", box.value))
    flip.checked = true
    flip.dispatchEvent(new Event("change", { bubbles: true }))
    frame.src = `${this.urlValue}?${asked}`
  }

  ticked() {
    return Array.from(this.element.querySelectorAll("input.tick-case:checked"))
  }
}
