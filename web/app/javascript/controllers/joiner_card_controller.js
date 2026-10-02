import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["frame"]

  connect() {
    this.onClick = this.onClick.bind(this)
    document.addEventListener("click", this.onClick)
  }

  disconnect() {
    document.removeEventListener("click", this.onClick)
  }

  onClick(event) {
    const trigger = event.target.closest("[data-joiner-card]")
    if (!trigger || !this.hasFrameTarget) return

    const url = trigger.getAttribute("data-joiner-card")
    if (this.frameTarget.getAttribute("src") === url) return

    this.frameTarget.removeAttribute("complete")
    this.frameTarget.innerHTML = ""
    this.frameTarget.setAttribute("src", url)
  }
}
