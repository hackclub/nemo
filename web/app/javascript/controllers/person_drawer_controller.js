import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    this.onKey = this.onKey.bind(this)
    this.onClick = this.onClick.bind(this)
    document.addEventListener("keydown", this.onKey)
    document.addEventListener("click", this.onClick)
  }

  disconnect() {
    document.removeEventListener("keydown", this.onKey)
    document.removeEventListener("click", this.onClick)
  }

  close() {
    this.element.innerHTML = ""
    this.element.removeAttribute("src")
  }

  onClick(event) {
    if (this.element.matches(":empty")) return
    if (this.element.contains(event.target)) return
    if (event.target.closest('[data-turbo-frame="person-drawer"]')) return

    this.close()
  }

  onKey(event) {
    if (this.element.matches(":empty")) return
    if (document.activeElement?.closest("input, textarea, select")) return

    if (event.key === "Escape") this.close()
  }
}
