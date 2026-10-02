import { Controller } from "@hotwired/stimulus"

const REACHABLE = "a[href], button:not([disabled]), label[tabindex], [tabindex='0']"

const MARGIN = 12
const FLOOR = 160

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
      pop.style.removeProperty("--menu-room")
      pop.style.removeProperty("left")
      pop.style.removeProperty("top")
      pop.classList.remove("menu-up")
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
    const pop = this.pop
    const box = this.summary.getBoundingClientRect()
    const below = window.innerHeight - box.bottom - MARGIN
    const above = box.top - MARGIN
    const up = below < FLOOR && above > below

    pop.classList.toggle("menu-up", up)
    pop.style.setProperty("--menu-room", `${Math.max(0, Math.round(up ? above : below))}px`)
    if (!pop.hasAttribute("popover")) return

    pop.style.left = "0px"
    pop.style.top = "0px"
    const size = pop.getBoundingClientRect()
    const start = pop.classList.contains("menu-start")
    const left = Math.max(MARGIN, Math.min(start ? box.left : box.right - size.width,
      window.innerWidth - MARGIN - size.width))
    const top = up ? box.top - size.height - 5 : box.bottom + 5

    pop.style.left = `${Math.round(left)}px`
    pop.style.top = `${Math.round(Math.max(MARGIN,
      Math.min(top, window.innerHeight - MARGIN - size.height)))}px`
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
