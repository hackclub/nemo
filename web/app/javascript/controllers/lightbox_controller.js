import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["box", "shot", "name", "original"]

  connect() {
    this.onClick = this.onClick.bind(this)
    this.onBackdrop = this.onBackdrop.bind(this)
    this.element.addEventListener("click", this.onClick)
    this.boxTarget.addEventListener("click", this.onBackdrop)
  }

  disconnect() {
    this.element.removeEventListener("click", this.onClick)
    this.boxTarget.removeEventListener("click", this.onBackdrop)
  }

  onClick(event) {
    const opener = event.target.closest("[data-lightbox]")
    if (!opener || event.metaKey || event.ctrlKey || event.shiftKey || event.button !== 0) return

    event.preventDefault()
    this.opener = opener
    this.show(opener.getAttribute("href"), opener.dataset.lightbox)
  }

  show(src, name) {
    if (!src) return

    this.shotTarget.removeAttribute("src")
    this.shotTarget.alt = name || "attachment"
    this.shotTarget.src = src
    this.nameTarget.textContent = name || "attachment"
    this.originalTarget.href = src
    if (!this.boxTarget.open) this.boxTarget.showModal()
  }

  // a click that lands on the dialog itself is a click on the backdrop
  onBackdrop(event) {
    if (event.target === this.boxTarget) this.shut()
  }

  shut() {
    if (this.boxTarget.open) this.boxTarget.close()
    this.shotTarget.removeAttribute("src")
    const back = this.opener
    this.opener = null
    if (back && back.isConnected) back.focus()
  }
}
