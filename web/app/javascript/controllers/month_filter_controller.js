import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["picker", "group"]

  connect() {
    this.pick()
  }

  pick() {
    const month = this.pickerTarget.value
    this.groupTargets.forEach((group) => {
      group.hidden = group.dataset.month !== month
    })
  }
}
