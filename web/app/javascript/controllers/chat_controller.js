import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["field", "pill", "send"]
  static values = { reporter: Boolean, noteUrl: String, replyUrl: String }

  connect() {
    this.toReporter = false
    this.grow()
  }

  focus() {
    this.fieldTarget.focus()
  }

  type() {
    if (!this.toReporter && this.reporterValue && /^>\s/.test(this.fieldTarget.value)) {
      this.fieldTarget.value = this.fieldTarget.value.replace(/^>\s/, "")
      this.aim(true)
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

  aim(atReporter) {
    this.toReporter = atReporter
    this.pillTarget.hidden = !atReporter
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
