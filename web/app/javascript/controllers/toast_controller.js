import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { delay: { type: Number, default: 3000 } }

  connect() {
    this.timer = setTimeout(() => this.dismiss(), this.delayValue)
  }

  disconnect() {
    clearTimeout(this.timer)
  }

  dismiss() {
    clearTimeout(this.timer)
    this.element.classList.add("is-leaving")
    this.element.addEventListener("transitionend", () => this.element.remove(), { once: true })
    setTimeout(() => this.element.remove(), 400)
  }
}
