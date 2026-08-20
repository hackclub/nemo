import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["claim", "resolve", "merge", "open"]

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
    if (event.target.closest('[data-controller~="row-link"]')) return

    this.close()
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
      case "m":
        if (this.hasMergeTarget) this.mergeTarget.click()
        break
      case "Enter":
        if (this.hasOpenTarget) this.openTarget.click()
        break
    }
  }
}
