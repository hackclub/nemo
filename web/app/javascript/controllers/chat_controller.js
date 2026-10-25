import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["field", "send", "anon", "team", "reply", "box"]
  static values = { reporter: Boolean, reporterLabel: String, case: String, noteUrl: String, replyUrl: String }

  connect() {
    this.anonymous = false
    this.onSubmitEnd = this.onSubmitEnd.bind(this)
    this.element.addEventListener("turbo:submit-end", this.onSubmitEnd)
    this.setRecipient(false)
    this.resizeField()
  }

  disconnect() {
    this.element.removeEventListener("turbo:submit-end", this.onSubmitEnd)
  }

  onSubmitEnd(event) {
    if (!event.detail?.success) return

    this.fieldTarget.value = ""
    this.setRecipient(false)
    this.resizeField()
    this.fieldTarget.focus()
  }

  focus() {
    this.fieldTarget.focus()
  }

  type() {
    const prefixMatch = /^(~?)([?>])\s?/.exec(this.fieldTarget.value)

    if (prefixMatch && this.reporterValue && !this.toReporter) {
      this.fieldTarget.value = this.fieldTarget.value.slice(prefixMatch[0].length)
      this.setRecipient(true, prefixMatch[1] === "~")
    } else if (this.toReporter && !this.anonymous && /^~\s?/.test(this.fieldTarget.value)) {
      this.fieldTarget.value = this.fieldTarget.value.replace(/^~\s?/, "")
      this.setRecipient(true, true)
    }

    this.resizeField()
  }

  keys(event) {
    if (event.defaultPrevented) return

    if (event.key === "Enter" && !event.shiftKey && !this.mentionPopupOpen()) {
      event.preventDefault()
      if (!this.sendTarget.disabled && this.fieldTarget.value.trim()) {
        this.element.requestSubmit()
      }
      return
    }

    if (event.key === "Backspace" && this.toReporter && this.caretAtStart()) {
      event.preventDefault()
      this.setRecipient(false)
    }
  }

  messageTeam() {
    this.setRecipient(false)
    this.fieldTarget.focus()
  }

  replyToReporter() {
    this.setRecipient(true, this.anonymous)
    this.fieldTarget.focus()
  }

  setRecipient(atReporter, anonymous = false) {
    this.toReporter = atReporter
    this.anonymous = atReporter && anonymous
    if (this.hasTeamTarget) this.teamTarget.setAttribute("aria-pressed", String(!atReporter))
    if (this.hasReplyTarget) {
      this.replyTarget.setAttribute("aria-pressed", String(atReporter))
      this.replyTarget.textContent = this.replyLabel()
    }
    if (this.hasBoxTarget) this.boxTarget.dataset.recipient = atReporter ? "reporter" : "team"
    this.anonTarget.value = this.anonymous ? "1" : ""
    this.element.action = atReporter ? this.replyUrlValue : this.noteUrlValue
    this.sendTarget.setAttribute("aria-label", atReporter ? "Send to reporter" : "Send to team")
  }

  replyLabel() {
    const parts = [`Reply to ${this.reporterLabelValue || "reporter"}`]
    if (this.caseValue) parts.push(`case ${this.caseValue}`)
    if (this.anonymous) parts.push("anonymous")
    return parts.join(", ")
  }

  mentionPopupOpen() {
    const pop = this.element.querySelector('[data-mention-target="pop"]')
    return pop ? pop.matches(":popover-open") : false
  }

  caretAtStart() {
    return this.fieldTarget.selectionStart === 0 && this.fieldTarget.selectionEnd === 0
  }

  resizeField() {
    const field = this.fieldTarget
    field.style.height = "auto"
    field.style.height = `${Math.min(field.scrollHeight, 160)}px`
  }
}
