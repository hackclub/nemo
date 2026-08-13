import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { id: String }

  write(event) {
    event.preventDefault()
    if (!navigator.clipboard) return

    navigator.clipboard.writeText(this.idValue).then(() => this.flash())
  }

  flash() {
    clearTimeout(this.timer)
    this.element.dataset.copied = "true"
    this.timer = setTimeout(() => delete this.element.dataset.copied, 1200)
  }
}
