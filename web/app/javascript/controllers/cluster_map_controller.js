import { Controller } from "@hotwired/stimulus"

const PACE = 700

export default class extends Controller {
  static targets = ["button"]
  static values = { steps: Number }

  disconnect() {
    this.stop()
  }

  play() {
    this.stop()
    this.show(0)
    let step = 0
    this.timer = setInterval(() => {
      step += 1
      if (step >= this.stepsValue) return this.stop()
      this.show(step)
    }, PACE)
  }

  stop() {
    if (this.timer) clearInterval(this.timer)
    this.timer = null
    this.show(this.stepsValue)
  }

  show(step) {
    this.element.querySelectorAll("[data-step]").forEach((one) => {
      one.classList.toggle("is-later", Number(one.dataset.step) > step)
    })
  }
}
