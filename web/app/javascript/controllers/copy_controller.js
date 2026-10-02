import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { id: String }
  static targets = ["source"]

  write(event) {
    event.preventDefault()
    if (!navigator.clipboard) return

    navigator.clipboard.writeText(this.said()).then(() => this.flash())
  }

  said() {
    return this.hasSourceTarget ? this.sourceTarget.innerText : this.idValue
  }

  flash() {
    clearTimeout(this.timer)
    this.element.dataset.copied = "true"
    this.timer = setTimeout(() => delete this.element.dataset.copied, 1200)
  }
}
