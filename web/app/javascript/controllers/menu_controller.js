import { Controller } from "@hotwired/stimulus"

const REACHABLE = "a[href], button:not([disabled]), label[tabindex], [tabindex='0']"

export default class extends Controller {
  connect() {
    this.onKeys = this.onKeys.bind(this)
    this.element.addEventListener("keydown", this.onKeys)
  }

  disconnect() {
    this.element.removeEventListener("keydown", this.onKeys)
  }

  get summary() {
    return this.element.querySelector("summary")
  }

  get items() {
    const pop = this.element.querySelector(".menu-pop")
    return pop ? [...pop.querySelectorAll(REACHABLE)] : []
  }

  onKeys(event) {
    if (event.key === "Escape") return this.shut(event)
    if (event.key === "Enter" || event.key === " ") return this.pick(event)

    const step = event.key === "ArrowDown" ? 1 : event.key === "ArrowUp" ? -1 : 0
    if (step !== 0) this.move(event, step)
  }

  shut(event) {
    if (!this.element.open) return

    event.preventDefault()
    this.element.removeAttribute("open")
    this.summary?.focus()
  }

  pick(event) {
    const label = event.target.closest("label[tabindex]")
    if (!label || !this.element.contains(label)) return

    event.preventDefault()
    label.click()
    this.element.removeAttribute("open")
  }

  move(event, step) {
    if (event.target === this.summary && !this.element.open) return

    const all = this.items
    if (all.length === 0) return

    event.preventDefault()
    if (!this.element.open) this.element.setAttribute("open", "")

    const at = all.indexOf(document.activeElement)
    const next = at < 0 ? (step > 0 ? 0 : all.length - 1) : (at + step + all.length) % all.length
    all[next].focus()
  }
}
