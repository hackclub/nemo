import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    this.onKey = this.onKey.bind(this)
    this.onClick = this.onClick.bind(this)
    document.addEventListener("keydown", this.onKey)
    document.addEventListener("click", this.onClick)
  }

  disconnect() {
    clearTimeout(this.fallback)
    document.removeEventListener("keydown", this.onKey)
    document.removeEventListener("click", this.onClick)
  }

  close() {
    if (this.element.matches(":empty") || this.element.classList.contains("is-leaving")) return

    this.element.classList.add("is-leaving")

    const done = () => {
      clearTimeout(this.fallback)
      this.element.removeEventListener("animationend", done)
      this.element.innerHTML = ""
      this.element.removeAttribute("src")
      this.element.classList.remove("is-leaving")
    }

    this.element.addEventListener("animationend", done)
    this.fallback = setTimeout(done, 400)
  }

  onClick(event) {
    if (this.element.matches(":empty")) return
    if (this.element.contains(event.target)) return
    if (event.target.closest('[data-turbo-frame="person-drawer"]')) return

    this.close()
  }

  onKey(event) {
    if (this.element.matches(":empty")) return

    if (event.key === "Escape") this.close()
  }
}
