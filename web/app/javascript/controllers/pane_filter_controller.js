import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["query", "row", "empty"]

  connect() {
    this.onKey = (event) => {
      if (event.key !== "/" || event.metaKey || event.ctrlKey || event.altKey) return
      if (event.target.matches("input, textarea, select, [contenteditable='true']")) return

      event.preventDefault()
      this.queryTarget.focus()
    }
    document.addEventListener("keydown", this.onKey)
  }

  disconnect() {
    document.removeEventListener("keydown", this.onKey)
  }

  filter() {
    const term = this.queryTarget.value.trim().toLocaleLowerCase()
    let shown = 0

    this.rowTargets.forEach((row) => {
      const matches = !term || row.textContent.toLocaleLowerCase().includes(term)
      row.hidden = !matches
      if (matches) shown += 1
    })

    if (this.hasEmptyTarget) this.emptyTarget.hidden = shown > 0
  }
}
