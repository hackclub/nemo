import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["box", "all", "bar", "count", "field", "go"]

  connect() {
    this.sync()
  }

  get picked() {
    return this.boxTargets.filter((box) => box.checked)
  }

  toggle() {
    this.sync()
  }

  toggleAll() {
    const want = this.allTarget.checked
    this.boxTargets.forEach((box) => {
      box.checked = want
    })
    this.sync()
  }

  sync() {
    const picked = this.picked
    const count = picked.length

    if (this.hasAllTarget) {
      this.allTarget.checked = count > 0 && count === this.boxTargets.length
      this.allTarget.indeterminate = count > 0 && count < this.boxTargets.length
    }

    if (this.hasBarTarget) this.barTarget.hidden = count === 0
    if (this.hasCountTarget) this.countTarget.textContent = String(count)

    this.element.querySelectorAll("[data-picked-row]").forEach((row) => {
      const box = row.querySelector("[data-pick-rows-target='box']")
      row.classList.toggle("is-picked", Boolean(box && box.checked))
    })

    this.carry(picked)
    this.fit()
  }

  carry(picked) {
    if (!this.hasFieldTarget) return

    this.fieldTarget.replaceChildren(
      ...picked.map((box) => {
        const held = document.createElement("input")
        held.type = "hidden"
        held.name = "user_ids[]"
        held.value = box.value
        return held
      })
    )
  }

  fit() {
    if (!this.hasGoTarget) return

    this.goTarget.disabled = this.picked.length === 0
  }

  clear() {
    this.boxTargets.forEach((box) => {
      box.checked = false
    })
    this.sync()
  }
}
