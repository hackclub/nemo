import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["label"]

  connect() {
    this.show()
  }

  choose() {
    this.show()
    this.element.removeAttribute("open")
  }

  show() {
    const picked = this.element.querySelector("input:checked")
    this.labelTarget.textContent = picked
      ? picked.dataset.label
      : this.labelTarget.dataset.blank
  }
}
