import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { seconds: { type: Number, default: 10 } }

  connect() {
    this.timer = setInterval(() => this.refresh(), this.secondsValue * 1000)
  }

  disconnect() {
    clearInterval(this.timer)
  }

  refresh() {
    if (document.hidden) return

    Turbo.visit(window.location.href, { action: "replace" })
  }
}
