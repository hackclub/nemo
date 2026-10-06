import { Controller } from "@hotwired/stimulus"

const SLOW_AFTER = 10000
const LANDED_FOR = 1600

export default class extends Controller {
  static targets = ["slow"]

  connect() {
    this.mark()
    this.waitForSlack()
  }

  disconnect() {
    clearTimeout(this.slowTimer)
    clearTimeout(this.landedTimer)
  }

  get enforcementStatus() {
    return this.element.dataset.enforcementStatus
  }

  mark() {
    if (this.element.dataset.landed !== "true") return

    this.element.classList.add("just-landed")
    this.landedTimer = setTimeout(() => {
      this.element.classList.remove("just-landed")
    }, LANDED_FOR)
  }

  waitForSlack() {
    if (this.enforcementStatus !== "pending" || !this.hasSlowTarget) return

    this.slowTimer = setTimeout(() => {
      this.slowTarget.hidden = false
    }, SLOW_AFTER)
  }
}
