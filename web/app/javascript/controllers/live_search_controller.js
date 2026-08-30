import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { wait: { type: Number, default: 250 } }

  disconnect() {
    clearTimeout(this.timer)
  }

  go() {
    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.element.requestSubmit(), this.waitValue)
  }
}
