import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { key: String, open: Boolean }

  connect() {
    const held = this.held
    if (held !== null) this.element.open = held
  }

  keep() {
    if (!this.hasKeyValue) return

    try {
      localStorage.setItem(this.store, this.element.open ? "1" : "0")
    } catch {
      // a private window or blocked site data, so the default stands
    }
  }

  get store() {
    return `mn-open-${this.keyValue}`
  }

  get held() {
    if (!this.hasKeyValue) return null

    try {
      const was = localStorage.getItem(this.store)
      return was === null ? null : was === "1"
    } catch {
      return null
    }
  }
}
