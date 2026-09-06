import { Controller } from "@hotwired/stimulus"

const MODE = "sidebar"
const WIDTH = "sidebarw"
const ICON = "sidebar-icon"
const OPEN = "sidebar-open"
const DRAGGING = "sidebar-dragging"
const MOBILE = "(max-width: 899px)"
const MIN = 200
const MAX = 460
const SLOP = 3

export default class extends Controller {
  connect() {
    this.root = document.documentElement
    this.nav = this.element.querySelector(".cpane")
    if (!this.nav) return

    this.mobile = window.matchMedia(MOBILE)
    this.root.classList.toggle(ICON, this.remembered(MODE) === "icon")

    const width = parseInt(this.remembered(WIDTH), 10)
    if (width >= MIN && width <= MAX) this.root.style.setProperty("--sidebar-w", `${width}px`)
  }

  disconnect() {
    this.root?.classList.remove(OPEN, DRAGGING)
  }

  toggle() {
    if (this.mobile.matches) {
      this.root.classList.toggle(OPEN)
      return
    }

    const icon = this.root.classList.toggle(ICON)
    this.root.classList.remove(OPEN)
    this.remember(MODE, icon ? "icon" : "wide")
  }

  close() {
    this.root.classList.remove(OPEN)
  }

  drag(event) {
    if (this.mobile.matches || event.button !== 0) return

    event.preventDefault()
    this.rail = event.currentTarget
    this.from = event.clientX
    this.was = this.nav.getBoundingClientRect().width
    this.moved = false
    this.rail.setPointerCapture(event.pointerId)
    this.root.classList.add(DRAGGING)
  }

  move(event) {
    if (this.from == null) return

    const delta = event.clientX - this.from
    if (!this.moved && Math.abs(delta) <= SLOP) return

    this.moved = true
    if (this.root.classList.contains(ICON)) {
      if (delta < 24) return

      this.root.classList.remove(ICON)
      this.remember(MODE, "wide")
      this.was = MIN
      this.from = event.clientX
      return
    }

    const width = Math.min(MAX, Math.max(MIN, this.was + delta))
    this.root.style.setProperty("--sidebar-w", `${Math.round(width)}px`)
  }

  drop(event) {
    if (this.from == null) return

    this.rail?.releasePointerCapture?.(event.pointerId)
    this.root.classList.remove(DRAGGING)
    const dragged = this.moved
    this.from = null
    this.rail = null

    if (!dragged) {
      this.toggle()
      return
    }

    const width = parseInt(this.root.style.getPropertyValue("--sidebar-w"), 10)
    if (width) this.remember(WIDTH, String(width))
  }

  remembered(name) {
    return document.cookie
      .split("; ")
      .find((pair) => pair.startsWith(`${name}=`))
      ?.split("=")[1]
  }

  remember(name, value) {
    document.cookie = `${name}=${value}; path=/; max-age=31536000; samesite=lax`
  }
}
