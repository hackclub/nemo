import { Controller } from "@hotwired/stimulus"

const MAX = 12

export default class extends Controller {
  static targets = ["rows", "row", "blank"]

  connect() {
    if (!this.rowTargets.length) this.add()
    this.rowTargets.forEach((row) => this.fit(row))
  }

  add() {
    if (this.rowTargets.length >= MAX) return

    const mark = this.rowTargets.length + Date.now() % 1000
    this.rowsTarget.insertAdjacentHTML("beforeend",
      this.blankTarget.innerHTML.replaceAll("__i__", String(mark)))
    const row = this.rowTargets[this.rowTargets.length - 1]
    this.fit(row)
    row.querySelector("select")?.focus()
  }

  drop(event) {
    event.target.closest("[data-conditions-target='row']")?.remove()
    if (!this.rowTargets.length) this.add()
  }

  swap(event) {
    this.fit(event.target.closest("[data-conditions-target='row']"))
  }

  // the operator list and the number of value boxes both follow the field's kind
  fit(row) {
    if (!row) return

    const field = row.querySelector(".cond-field")
    const kind = field.selectedOptions[0]?.dataset.kind
    const ops = row.querySelector(".cond-op")

    const key = field.value
    let first = null
    ops.querySelectorAll("optgroup").forEach((group) => {
      const mine = group.dataset.for === key
      group.hidden = !mine
      group.disabled = !mine
      if (mine && !first) first = group.querySelector("option")
    })
    if (ops.selectedOptions[0]?.closest("optgroup")?.dataset.for !== key && first) {
      first.selected = true
    }

    const arity = Number(ops.selectedOptions[0]?.dataset.arity ?? 1)
    row.querySelectorAll(".cond-val").forEach((box, slot) => {
      box.hidden = slot >= arity
      box.type = kind === "text" ? "text" : "number"
      if (box.hidden) box.value = ""
    })
    const unit = row.querySelector(".cond-unit")
    if (unit) unit.hidden = arity === 0
  }
}
