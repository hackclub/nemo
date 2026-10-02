import { Controller } from "@hotwired/stimulus"

const WIDTH = "queuew"
const DRAGGING = "sidebar-dragging"
const MOBILE = "(max-width: 899px)"
const MIN = 280
const MAX = 620

export default class extends Controller {
  connect() {
    this.root = document.documentElement
    this.pane = this.element.querySelector(".pane:not(.cpane)")
    if (!this.pane) return

    this.mobile = window.matchMedia(MOBILE)
    const width = parseInt(this.remembered(), 10)
    if (width >= MIN && width <= MAX) this.root.style.setProperty("--queue-w", `${width}px`)
  }

  disconnect() {
    this.root?.classList.remove(DRAGGING)
  }

  drag(event) {
    if (this.mobile.matches || event.button !== 0) return

    event.preventDefault()
    this.grip = event.currentTarget
    this.from = event.clientX
    this.was = this.pane.getBoundingClientRect().width
    this.grip.setPointerCapture(event.pointerId)
    this.root.classList.add(DRAGGING)
  }

  move(event) {
    if (this.from == null) return

    const width = Math.min(MAX, Math.max(MIN, this.was + event.clientX - this.from))
    this.root.style.setProperty("--queue-w", `${Math.round(width)}px`)
  }

  drop(event) {
    if (this.from == null) return

    this.grip?.releasePointerCapture?.(event.pointerId)
    this.root.classList.remove(DRAGGING)
    this.from = null
    this.grip = null

    const width = parseInt(this.root.style.getPropertyValue("--queue-w"), 10)
    if (width) document.cookie = `${WIDTH}=${width}; path=/; max-age=31536000; samesite=lax`
  }

  remembered() {
    return document.cookie
      .split("; ")
      .find((pair) => pair.startsWith(`${WIDTH}=`))
      ?.split("=")[1]
  }
}
