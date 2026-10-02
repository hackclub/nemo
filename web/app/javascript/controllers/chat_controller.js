import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["field", "pill", "send", "aim", "anon", "drop"]
  static values = { reporter: Boolean, noteUrl: String, replyUrl: String }

  connect() {
    this.anonymous = false
    this.sent = this.sent.bind(this)
    this.element.addEventListener("turbo:submit-end", this.sent)
    this.aim(false)
    this.grow()
  }

  disconnect() {
    this.element.removeEventListener("turbo:submit-end", this.sent)
  }

  sent(event) {
    if (!event.detail?.success) return

    this.fieldTarget.value = ""
    this.aim(false)
    this.grow()
    this.fieldTarget.focus()
  }

  focus() {
    this.fieldTarget.focus()
  }

  type() {
    const marks = /^(~?)([?>])\s?/.exec(this.fieldTarget.value)

    if (marks && this.reporterValue && !this.toReporter) {
      this.fieldTarget.value = this.fieldTarget.value.slice(marks[0].length)
      this.aim(true, marks[1] === "~")
    } else if (this.toReporter && !this.anonymous && /^~\s?/.test(this.fieldTarget.value)) {
      this.fieldTarget.value = this.fieldTarget.value.replace(/^~\s?/, "")
      this.aim(true, true)
    }

    this.grow()
  }

  keys(event) {
    if (event.key === "Enter" && !event.shiftKey && !this.pickingAMention()) {
      event.preventDefault()
      if (!this.sendTarget.disabled && this.fieldTarget.value.trim()) {
        this.element.requestSubmit()
      }
      return
    }

    if (event.key === "Backspace" && this.toReporter && this.caretAtStart()) {
      event.preventDefault()
      this.aim(false)
    }
  }

  drop(event) {
    event.stopPropagation()
    this.aim(false)
    this.fieldTarget.focus()
  }

  aim(atReporter, anonymous = false) {
    this.toReporter = atReporter
    this.anonymous = atReporter && anonymous
    this.pillTarget.hidden = false
    this.pillTarget.dataset.mode = atReporter ? "reporter" : "team"
    this.dropTarget.hidden = !atReporter
    this.aimTarget.textContent = atReporter
      ? (this.anonymous ? "to reporter, anonymous" : "to reporter, from you")
      : "internal"
    this.anonTarget.value = this.anonymous ? "1" : ""
    this.element.action = atReporter ? this.replyUrlValue : this.noteUrlValue
    this.sendTarget.title = atReporter ? "Send to the reporter" : "Send to the team"
  }

  pickingAMention() {
    const pop = this.element.querySelector('[data-mention-target="results"]')
    return pop ? !pop.hidden : false
  }

  caretAtStart() {
    return this.fieldTarget.selectionStart === 0 && this.fieldTarget.selectionEnd === 0
  }

  grow() {
    const field = this.fieldTarget
    field.style.height = "auto"
    field.style.height = `${Math.min(field.scrollHeight, 160)}px`
  }
}
