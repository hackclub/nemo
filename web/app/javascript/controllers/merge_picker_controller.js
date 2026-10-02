import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["case", "form", "keeper", "submit", "count"]
  static values = { baseId: Number, baseOpenedAt: String }

  initialize() {
    this.selected = new Map()
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
      this.selected.set(box.value, box.dataset.openedAt)
    } else {
      this.selected.delete(box.value)
    }
    this.sync()
  }

  sync() {
    if (!this.hasFormTarget) return

    const visible = new Set(this.caseTargets.map((box) => box.value))
    this.caseTargets.forEach((box) => { box.checked = this.selected.has(box.value) })
    this.formTarget.querySelectorAll("[data-merge-picker-held]").forEach((input) => input.remove())

    this.selected.forEach((_openedAt, id) => {
      if (visible.has(id)) return

      const input = document.createElement("input")
      input.type = "hidden"
      input.name = "case_ids[]"
      input.value = id
      input.dataset.mergePickerHeld = "true"
      this.formTarget.append(input)
    })

    this.keeperTarget.value = this.keeperId()
    const selected = this.selected.size
    const total = selected + 1
    this.countTarget.textContent = selected === 0 ? "Select at least one case" : `${selected} selected`
    this.submitTarget.value = selected === 0 ? "Merge cases" : `Merge ${total} cases`
    this.submitTarget.disabled = selected === 0
    this.submitTarget.classList.toggle("is-off", selected === 0)
  }

  keeperId() {
    let keeper = { id: this.baseIdValue, openedAt: Date.parse(this.baseOpenedAtValue) }
    this.selected.forEach((openedAt, id) => {
      const timestamp = Date.parse(openedAt)
      if (timestamp < keeper.openedAt) keeper = { id, openedAt: timestamp }
    })
    return keeper.id
  }
}
