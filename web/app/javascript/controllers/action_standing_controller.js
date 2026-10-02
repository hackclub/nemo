import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { url: String }
  static targets = ["fields", "expiry", "channel", "locks", "aimed", "standing", "why"]

  connect() {
    this.fit()
    this.shape()
  }

  look() {
    const frame = this.element.querySelector("turbo-frame#action-standing")
    const form = this.element.querySelector("form")
    if (!frame || !form) return

    const asked = new URLSearchParams({
      target_user_id: new FormData(form).get("target_user_id") ?? ""
    })
    frame.src = `${this.urlValue}?${asked}`
    frame.reload()
  }

  fit() {
    if (!this.hasFieldsTarget) return

    const chosen = this.element.querySelector('input[name="standing_guard_id"]:checked')
    this.fieldsTarget.hidden = Boolean(chosen && chosen.value)
  }

  shape() {
    const kind = this.element.querySelector('select[name="type_key"]')?.selectedOptions[0]
    if (!kind) return

    const onThread = kind.dataset.lock === "true"

    if (this.hasExpiryTarget) {
      this.expiryTarget.hidden = onThread || kind.dataset.expires !== "true"
    }
    if (this.hasChannelTarget) {
      this.channelTarget.hidden = onThread || kind.dataset.channel !== "true"
    }
    if (this.hasLocksTarget) this.locksTarget.hidden = !onThread
    if (this.hasAimedTarget) this.aimedTarget.hidden = onThread
    if (this.hasStandingTarget) this.standingTarget.hidden = onThread
    if (this.hasWhyTarget) this.whyTarget.hidden = onThread
  }
}
