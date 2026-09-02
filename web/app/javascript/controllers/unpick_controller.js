import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  down(event) {
    const input = event.currentTarget.querySelector("input[type=radio]")
    this.held = input ? input.checked : false
  }

  press(event) {
    const input = event.currentTarget.querySelector("input[type=radio]")
    if (!input || !this.held) return

    event.preventDefault()
    this.held = false
    input.checked = false
    input.dispatchEvent(new Event("change", { bubbles: true }))
  }
}
