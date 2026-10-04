import { Controller } from "@hotwired/stimulus"
import { placePop, clearPop } from "lib/place_pop"

const REACHABLE = "a[href], button:not([disabled]), label[tabindex], [tabindex='0']"

export default class extends Controller {
  connect() {
    this.onKeys = this.onKeys.bind(this)
    this.onToggle = this.onToggle.bind(this)
    this.onMove = this.onMove.bind(this)
    this.element.addEventListener("keydown", this.onKeys)
    this.element.addEventListener("toggle", this.onToggle)
    if (this.pop && typeof this.pop.showPopover === "function") {
      this.pop.setAttribute("popover", "manual")
    }
  }

  disconnect() {
    this.element.removeEventListener("keydown", this.onKeys)
    this.element.removeEventListener("toggle", this.onToggle)
    this.unwatch()
  }

  get pop() {
    return this.element.querySelector(".menu-pop")
  }

  onToggle() {
    const pop = this.pop
    if (!pop) return

    if (!this.element.open) {
      if (pop.matches(":popover-open")) pop.hidePopover()
      clearPop(pop)
      this.unwatch()
      return
    }

    if (pop.hasAttribute("popover") && !pop.matches(":popover-open")) pop.showPopover()
    this.place()
    window.addEventListener("resize", this.onMove)
    document.addEventListener("scroll", this.onMove, true)
  }

  onMove() {
    if (this.element.open) this.place()
  }

  unwatch() {
    window.removeEventListener("resize", this.onMove)
    document.removeEventListener("scroll", this.onMove, true)
  }

  place() {
    placePop(this.pop, this.summary)
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
