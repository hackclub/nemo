import { Controller } from "@hotwired/stimulus"

let resume = null

export default class extends Controller {
  static values = { wait: { type: Number, default: 250 } }

  connect() {
    const at = resume
    resume = null
    if (at == null) return

    const field = this.field
    if (!field) return

    field.focus()
    const caret = Math.min(at, field.value.length)
    field.setSelectionRange(caret, caret)
  }

  disconnect() {
    clearTimeout(this.timer)
  }

  go() {
    clearTimeout(this.timer)
    this.timer = setTimeout(() => {
      const field = this.field
      if (field && document.activeElement === field) {
        resume = field.selectionStart ?? field.value.length
      }
      this.element.requestSubmit()
    }, this.waitValue)
  }

  get field() {
    return this.element.querySelector("input[type=search], .qsearch-in")
  }
}
