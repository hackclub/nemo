import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["field"]
  static values = { url: String, wait: { type: Number, default: 200 } }

  look() {
    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.fetch(), this.waitValue)
  }

  fetch() {
    const frame = document.getElementById("merge-body")
    if (!frame) return

    const asked = this.fieldTarget.value.trim()
    frame.src = asked ? `${this.urlValue}?q=${encodeURIComponent(asked)}` : this.urlValue
  }

  disconnect() {
    clearTimeout(this.timer)
  }
}
