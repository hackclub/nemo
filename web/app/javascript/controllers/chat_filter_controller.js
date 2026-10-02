import { Controller } from "@hotwired/stimulus"

const ONLY = "only-replies"
const INTERNAL = "chat"

export default class extends Controller {
  static targets = ["all", "replies"]
  static values = { key: String }

  connect() {
    this.apply = this.apply.bind(this)
    this.element.addEventListener("turbo:frame-load", this.apply)
    this.only = this.held
    this.apply()
  }

  disconnect() {
    this.element.removeEventListener("turbo:frame-load", this.apply)
  }

  showAll() {
    this.pick(false)
  }

  onlyReplies() {
    this.pick(true)
  }

  pick(only) {
    this.only = only
    this.keep()
    this.apply()
    this.pin()
  }

  apply() {
    if (!this.hasAllTarget || !this.hasRepliesTarget) return

    this.element.classList.toggle(ONLY, this.only)
    this.allTarget.setAttribute("aria-pressed", String(!this.only))
    this.repliesTarget.setAttribute("aria-pressed", String(this.only))
    this.tidyDays()
  }

  tidyDays() {
    const log = this.log
    if (!log) return

    let rule = null
    let shown = 0
    let total = 0

    for (const node of log.children) {
      if (node.dataset.earlier !== undefined || node.dataset.nothing !== undefined) continue
      if (node.classList.contains("dayrule")) {
        if (rule) rule.hidden = shown === 0
        rule = node
        shown = 0
        continue
      }
      if (node.classList.contains("msg") && !this.dropped(node)) {
        shown += 1
        total += 1
      }
    }
    if (rule) rule.hidden = shown === 0

    const note = log.querySelector("[data-nothing]")
    if (note) note.hidden = !this.only || total > 0 || log.querySelector(".msg") === null
  }

  dropped(node) {
    return this.only && node.dataset.kind === INTERNAL
  }

  pin() {
    const log = this.log
    if (log) log.scrollTop = log.scrollHeight
  }

  get log() {
    return this.element.querySelector(".chatscroll")
  }

  get store() {
    return `mn-chat-replies-${this.keyValue}`
  }

  get held() {
    try {
      return localStorage.getItem(this.store) === "1"
    } catch {
      return false
    }
  }

  keep() {
    try {
      localStorage.setItem(this.store, this.only ? "1" : "0")
    } catch {
      return
    }
  }
}
