import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    this.onKey = (event) => {
      if (event.repeat || event.metaKey || event.ctrlKey || event.altKey) return
      if (event.target.matches("input, textarea, select, [contenteditable='true']")) return
      if (document.querySelector(".modal-flip:checked")) return

      const key = event.key.toLocaleLowerCase()
      if (!/^[cantr]$/.test(key)) return

      const control = document.querySelector(`[data-shortcut='${key}']:not([aria-disabled='true'])`)
      if (!control) return

      event.preventDefault()
      control.click()
    }
    document.addEventListener("keydown", this.onKey)
  }

  disconnect() {
    document.removeEventListener("keydown", this.onKey)
  }
}
