import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["claim", "resolve", "open"]

  connect() {
    this.onKey = this.onKey.bind(this)
    document.addEventListener("keydown", this.onKey)
  }

  disconnect() {
    document.removeEventListener("keydown", this.onKey)
  }

  close() {
    this.element.innerHTML = ""
    this.element.removeAttribute("src")
  }

  onKey(event) {
    if (this.element.matches(":empty")) return
    if (document.activeElement?.closest("input, textarea, select")) return

    switch (event.key) {
      case "Escape":
        this.close()
        break
      case "a":
        if (this.hasClaimTarget) this.claimTarget.requestSubmit()
        break
      case "r":
        if (this.hasResolveTarget) this.resolveTarget.click()
        break
      case "Enter":
        if (this.hasOpenTarget) this.openTarget.click()
        break
    }
  }
}
