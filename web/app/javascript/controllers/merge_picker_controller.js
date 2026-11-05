import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["case", "form", "submit", "count"]

  initialize() {
    this.selected = new Set()
  }

  connect() {
    this.sync()
  }

  formTargetConnected() {
    this.sync()
  }

  change(event) {
    const box = event.currentTarget
    if (box.checked) {
      this.selected.add(box.value)
    } else {
      this.selected.delete(box.value)
    }
    this.sync()
  }

  sync() {
    if (!this.hasFormTarget) return

    const visible = new Set(this.caseTargets.map((box) => box.value))
    this.caseTargets.forEach((box) => { box.checked = this.selected.has(box.value) })
    this.formTarget.querySelectorAll("[data-merge-picker-hidden]").forEach((input) => input.remove())

    this.selected.forEach((id) => {
      if (visible.has(id)) return

      const input = document.createElement("input")
      input.type = "hidden"
      input.name = "case_ids[]"
      input.value = id
      input.dataset.mergePickerHidden = "true"
      this.formTarget.append(input)
    })

    const selected = this.selected.size
    this.countTarget.textContent = selected === 0 ? "Select at least one case" : `${selected} selected`
    this.submitTarget.disabled = selected === 0
    this.submitTarget.classList.toggle("is-off", selected === 0)
  }
}
