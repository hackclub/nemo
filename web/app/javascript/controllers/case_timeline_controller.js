import { Controller } from "@hotwired/stimulus"

const OPEN = "mn-dock"
const PIN = "mn-dock-pin"

export default class extends Controller {
  static targets = ["panel", "toggle", "pin"]

  connect() {
    this.onKey = this.onKey.bind(this)
    this.onClick = this.onClick.bind(this)
    document.addEventListener("keydown", this.onKey)
    document.addEventListener("click", this.onClick)
    this.mark()
  }

  disconnect() {
    document.removeEventListener("keydown", this.onKey)
    document.removeEventListener("click", this.onClick)
  }

  get open() {
    return document.documentElement.classList.contains("dock-open")
  }

  get pinned() {
    return document.documentElement.classList.contains("dock-pinned")
  }

  mark() {
    if (this.hasToggleTarget) this.toggleTarget.setAttribute("aria-pressed", String(this.open))
    if (this.hasPinTarget) this.pinTarget.setAttribute("aria-pressed", String(this.pinned))
  }

  remember(key, on, yes, no) {
    try {
      localStorage.setItem(key, on ? yes : no)
    } catch (error) {
      return
    }
  }

  toggle(event) {
    if (event) event.preventDefault()
    const open = document.documentElement.classList.toggle("dock-open")
    this.mark()
    this.remember(OPEN, open, "open", "shut")
  }

  pin(event) {
    if (event) event.preventDefault()
    const pinned = document.documentElement.classList.toggle("dock-pinned")
    this.mark()
    this.remember(PIN, pinned, "pinned", "loose")
  }

  close() {
    if (!this.open) return
    document.documentElement.classList.remove("dock-open")
    this.mark()
    this.remember(OPEN, false, "open", "shut")
  }

  onClick(event) {
    if (!this.open || this.pinned) return
    if (!this.hasPanelTarget) return
    if (this.panelTarget.contains(event.target)) return
    if (event.target.closest('[data-action*="case-timeline#toggle"]')) return

    this.close()
  }

  onKey(event) {
    if (!this.open || this.pinned) return
    if (document.activeElement?.closest("input, textarea, select")) return

    if (event.key === "Escape") this.close()
  }
}
