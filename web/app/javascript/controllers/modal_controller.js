import { Controller } from "@hotwired/stimulus"

const REACHABLE = [
  "a[href]", "button:not([disabled])", "input:not([type=hidden]):not([disabled])",
  "select:not([disabled])", "textarea:not([disabled])", "summary", "[tabindex]:not([tabindex='-1'])"
].join(", ")

export default class extends Controller {
  static targets = ["flip", "box"]
  static values = { id: String }

  connect() {
    this.onOpenClick = this.onOpenClick.bind(this)
    this.onKeys = this.onKeys.bind(this)
    document.addEventListener("click", this.onOpenClick)
    this.boxTarget.addEventListener("keydown", this.onKeys)
    this.was = this.flipTarget.checked
    if (this.was) this.entered()
  }

  disconnect() {
    document.removeEventListener("click", this.onOpenClick)
    this.boxTarget.removeEventListener("keydown", this.onKeys)
  }

  onOpenClick(event) {
    const trigger = event.target.closest(`[data-modal-open="${this.idValue}"]`)
    if (!trigger) return

    event.preventDefault()
    this.opener = trigger
    trigger.closest("details[open]")?.removeAttribute("open")
    this.open()
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

  shut() {
    if (!this.flipTarget.checked) return

    this.flipTarget.checked = false
    this.sync()
  }

  entered() {
    if (!this.opener || this.boxTarget.contains(this.opener)) this.opener = document.activeElement
    requestAnimationFrame(() => {
      const first = this.reachable()[0]
      ;(first || this.boxTarget).focus()
    })
  }

  left() {
    const back = this.opener
    this.opener = null
    if (back && back.isConnected && typeof back.focus === "function") back.focus()
  }

  onKeys(event) {
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
