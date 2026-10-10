import { Controller } from "@hotwired/stimulus"
import { raise, lower, depth, topmost, popupOpen, aboveOpen, drawerOpen, inDrawer, inAbove } from "lib/layers"

const REACHABLE = [
  "a[href]", "button:not([disabled])", "input:not([type=hidden]):not([disabled])",
  "select:not([disabled])", "textarea:not([disabled])", "summary", "[tabindex]:not([tabindex='-1'])"
].join(", ")

const LAYER_STEP = 3
const VEIL_FLOOR = 100

export default class extends Controller {
  static targets = ["flip", "box"]
  static values = { id: String }

  connect() {
    this.onOpenClick = this.onOpenClick.bind(this)
    this.onDocumentKey = this.onDocumentKey.bind(this)
    this.onKeys = this.onKeys.bind(this)
    this.onSubmit = this.onSubmit.bind(this)
    document.addEventListener("click", this.onOpenClick)
    document.addEventListener("keydown", this.onDocumentKey)
    this.boxTarget.addEventListener("keydown", this.onKeys)
    this.boxTarget.addEventListener("submit", this.onSubmit)
    this.was = this.flipTarget.checked
    if (this.was) this.entered()
  }

  disconnect() {
    lower(this)
    document.removeEventListener("click", this.onOpenClick)
    document.removeEventListener("keydown", this.onDocumentKey)
    this.boxTarget.removeEventListener("keydown", this.onKeys)
    this.boxTarget.removeEventListener("submit", this.onSubmit)
  }

  onOpenClick(event) {
    const trigger = event.target.closest(`[data-modal-open="${this.idValue}"]`)
    if (trigger) {
      event.preventDefault()
      this.opener = trigger
      trigger.closest("details.menu[open], details.picker[open]")?.removeAttribute("open")
      this.open()
      return
    }

    if (!this.flipTarget.checked || !topmost(this) || event.defaultPrevented) return
    if (event.composedPath().includes(this.boxTarget)) return
    if (inDrawer(event.target) || inAbove(event.target)) return

    event.preventDefault()
    this.shut()
  }

  get covered() {
    return aboveOpen() || (drawerOpen() && depth(this) === 0)
  }

  holdsEscape(event) {
    return event.defaultPrevented || this.covered || popupOpen(this.boxTarget)
  }

  // a form that targets a turbo frame leaves the page in place, so the dialog
  // has to stand down on its own
  onSubmit() {
    this.shut()
  }

  onDocumentKey(event) {
    if (event.key !== "Escape" || !this.flipTarget.checked || !topmost(this)) return
    if (this.holdsEscape(event)) return

    event.preventDefault()
    this.shut()
  }

  sync() {
    const on = this.flipTarget.checked
    if (on === this.was) return

    this.was = on
    if (on) this.entered()
    else this.left()
  }

  open() {
    if (this.flipTarget.checked) return

    this.flipTarget.checked = true
    this.sync()
  }

  shut(event) {
    if (event?.type === "click") event.preventDefault()
    if (!this.flipTarget.checked) return

    this.flipTarget.checked = false
    this.sync()
  }

  entered() {
    raise(this)
    this.stackAt(depth(this))
    if (!this.opener || this.boxTarget.contains(this.opener)) this.opener = document.activeElement
    requestAnimationFrame(() => {
      const first = this.boxTarget.querySelector("[autofocus]") || this.reachable()[0]
      ;(first || this.boxTarget).focus()
    })
  }

  stackAt(level) {
    const veil = this.element.querySelector(".modal-veil")
    const wrap = this.element.querySelector(".modal-wrap")
    if (veil) veil.style.zIndex = level > 0 ? String(VEIL_FLOOR + (level * LAYER_STEP)) : ""
    if (wrap) wrap.style.zIndex = level > 0 ? String(VEIL_FLOOR + 1 + (level * LAYER_STEP)) : ""
  }

  left() {
    lower(this)
    this.stackAt(0)
    const url = new URL(location.href)
    if (url.searchParams.has("open") || url.searchParams.has("do")) {
      url.searchParams.delete("open")
      url.searchParams.delete("do")
      history.replaceState(history.state, "", url)
    }
    const back = this.opener
    this.opener = null
    if (back && back.isConnected && typeof back.focus === "function") back.focus()
  }

  onKeys(event) {
    if (event.key === "Escape" && this.holdsEscape(event)) return
    if (event.key === "Escape") {
      event.preventDefault()
      event.stopPropagation()
      return this.shut()
    }
    if (event.key !== "Tab") return

    const all = this.reachable()
    if (all.length === 0) return event.preventDefault()

    const first = all[0]
    const last = all[all.length - 1]
    const here = document.activeElement
    if (event.shiftKey && (here === first || here === this.boxTarget)) {
      event.preventDefault()
      last.focus()
    } else if (!event.shiftKey && here === last) {
      event.preventDefault()
      first.focus()
    }
  }

  reachable() {
    return [...this.boxTarget.querySelectorAll(REACHABLE)]
      .filter((el) => el.offsetParent !== null || el === document.activeElement)
  }
}
