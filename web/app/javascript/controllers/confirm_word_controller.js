import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { word: String }
  static targets = ["field", "go"]

  connect() {
    this.fit()
  }

  fit() {
    if (!this.hasGoTarget) return

    const typed = this.hasFieldTarget ? this.fieldTarget.value.trim() : ""
    const wanted = this.wordValue.trim()
    this.goTarget.disabled = typed.toLowerCase() !== wanted.toLowerCase()
  }
}
