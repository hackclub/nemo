import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["category", "reason"]
  static values = { categories: Array }

  connect() {
    this.toggle()
  }

  toggle() {
    if (!this.hasCategoryTarget) return

    const hidden = this.categoriesValue.includes(this.categoryTarget.value)
    for (const reason of this.reasonTargets) {
      reason.hidden = hidden
      for (const field of reason.querySelectorAll("textarea")) field.disabled = hidden
    }
  }
}
