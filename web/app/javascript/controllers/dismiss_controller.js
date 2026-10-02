import { Controller } from "@hotwired/stimulus"

const POPUPS = "details.menu[open], details.picker[open]"

export default class extends Controller {
  connect() {
    this.away = this.away.bind(this)
    this.escape = this.escape.bind(this)
    document.addEventListener("click", this.away)
    document.addEventListener("keydown", this.escape)
  }

  disconnect() {
    document.removeEventListener("click", this.away)
    document.removeEventListener("keydown", this.escape)
  }

  away(event) {
    for (const open of this.element.querySelectorAll(POPUPS)) {
      if (!open.contains(event.target)) open.removeAttribute("open")
    }
  }

  escape(event) {
    if (event.key !== "Escape") return

    for (const open of this.element.querySelectorAll(POPUPS)) {
      open.removeAttribute("open")
    }
  }
}
