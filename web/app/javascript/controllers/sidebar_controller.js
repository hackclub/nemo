import { Controller } from "@hotwired/stimulus"

const MODE_COOKIE = "sidebar"
const WIDTH_COOKIE = "sidebarw"
const ICON = "sidebar-icon"
const OPEN = "sidebar-open"
const DRAGGING = "sidebar-dragging"
const MOBILE = "(max-width: 899px)"
const MIN_WIDTH_PX = 200
const MAX_WIDTH_PX = 460
const DRAG_THRESHOLD_PX = 3

export default class extends Controller {
  static reconnectOnMorph = false

  connect() {
    this.root = document.documentElement
    this.nav = this.element.querySelector(".cpane")
    if (!this.nav) return

    this.mobile = window.matchMedia(MOBILE)
    this.root.classList.toggle(ICON, this.readCookie(MODE_COOKIE) === "icon")

    const width = parseInt(this.readCookie(WIDTH_COOKIE), 10)
    if (width >= MIN_WIDTH_PX && width <= MAX_WIDTH_PX) this.root.style.setProperty("--sidebar-w", `${width}px`)
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
    this.writeCookie(MODE_COOKIE, icon ? "icon" : "wide")
  }

  close() {
    this.root.classList.remove(OPEN)
  }

  drag(event) {
    if (this.mobile.matches || event.button !== 0) return

    event.preventDefault()
    this.rail = event.currentTarget
    this.from = event.clientX
    this.startWidth = this.nav.getBoundingClientRect().width
    this.hasMoved = false
    this.rail.setPointerCapture(event.pointerId)
    this.root.classList.add(DRAGGING)
  }

  move(event) {
    if (this.from == null) return

    const delta = event.clientX - this.from
    if (!this.hasMoved && Math.abs(delta) <= DRAG_THRESHOLD_PX) return

    this.hasMoved = true
    if (this.root.classList.contains(ICON)) {
      if (delta < 24) return

      this.root.classList.remove(ICON)
      this.writeCookie(MODE_COOKIE, "wide")
      this.startWidth = MIN_WIDTH_PX
      this.from = event.clientX
      return
    }

    const width = Math.min(MAX_WIDTH_PX, Math.max(MIN_WIDTH_PX, this.startWidth + delta))
    this.root.style.setProperty("--sidebar-w", `${Math.round(width)}px`)
  }

  drop(event) {
    if (this.from == null) return

    this.rail?.releasePointerCapture?.(event.pointerId)
    this.root.classList.remove(DRAGGING)
    const dragged = this.hasMoved
    this.from = null
    this.rail = null

    if (!dragged) {
      this.toggle()
      return
    }

    const width = parseInt(this.root.style.getPropertyValue("--sidebar-w"), 10)
    if (width) this.writeCookie(WIDTH_COOKIE, String(width))
  }

  readCookie(name) {
    return document.cookie
      .split("; ")
      .find((pair) => pair.startsWith(`${name}=`))
      ?.split("=")[1]
  }

  writeCookie(name, value) {
    document.cookie = `${name}=${value}; path=/; max-age=31536000; samesite=lax`
  }
}
