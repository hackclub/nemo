import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["panel"]

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

  open(event) {
    event.preventDefault()
    if (this.hasPanelTarget) this.panelTarget.classList.add("is-open")
  }

  close() {
    if (this.hasPanelTarget) this.panelTarget.classList.remove("is-open")
  }

  onClick(event) {
    if (!this.hasPanelTarget) return
    if (!this.panelTarget.classList.contains("is-open")) return
    if (this.panelTarget.contains(event.target)) return
    if (event.target.closest('[data-action*="case-timeline#open"]')) return

    this.close()
  }

  onKey(event) {
    if (!this.hasPanelTarget) return
    if (!this.panelTarget.classList.contains("is-open")) return
    if (document.activeElement?.closest("input, textarea, select")) return

    if (event.key === "Escape") this.close()
  }
}
