import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { url: String }
  static targets = ["fields", "expiry", "channel", "locks", "targetFields", "standing", "why", "deactivation", "submit"]

  connect() {
    this.toggleFields()
    this.toggleKindFields()
  }

  reloadStanding() {
    const frame = this.element.querySelector("turbo-frame#action-standing")
    const form = this.element.querySelector("form")
    if (!frame || !form) return

    const params = new URLSearchParams({
      target_user_id: new FormData(form).get("target_user_id") ?? ""
    })
    frame.src = `${this.urlValue}?${params}`
    frame.reload()
  }

  toggleFields() {
    if (this.hasFieldsTarget) {
      const selectedGuard = this.element.querySelector('input[name="standing_guard_id"]:checked')
      this.fieldsTarget.hidden = Boolean(selectedGuard && selectedGuard.value)
    }
    this.toggleDeactivation()
  }

  toggleKindFields() {
    const kind = this.selectedKind()
    if (!kind) return

    const onThread = kind.dataset.lock === "true"

    if (this.hasExpiryTarget) {
      this.expiryTarget.hidden = onThread || kind.dataset.expires !== "true"
    }
    if (this.hasChannelTarget) {
      this.channelTarget.hidden = onThread || kind.dataset.channel !== "true"
    }
    if (this.hasLocksTarget) this.locksTarget.hidden = !onThread
    if (this.hasTargetFieldsTarget) this.targetFieldsTarget.hidden = onThread
    if (this.hasStandingTarget) this.standingTarget.hidden = onThread
    for (const why of this.whyTargets) why.hidden = onThread
    this.toggleDeactivation()
  }

  toggleDeactivation() {
    const kind = this.selectedKind()
    const frame = this.element.querySelector("turbo-frame#action-standing")
    const fieldsShown = !this.hasFieldsTarget || !this.fieldsTarget.hidden
    const deactivates = Boolean(kind && kind.dataset.deactivates === "true" && fieldsShown &&
      frame?.dataset.deactivated !== "true")

    if (this.hasDeactivationTarget) {
      this.deactivationTarget.hidden = !deactivates
      this.deactivationTarget.textContent = `Deactivates ${this.targetName() || "the account"}`
    }
    if (this.hasSubmitTarget) this.submitTarget.value = deactivates ? "Log and deactivate" : "Log"
  }

  selectedKind() {
    return this.element.querySelector('select[name="type_key"]')?.selectedOptions[0]
  }

  targetName() {
    if (!this.hasTargetFieldsTarget) return null

    return this.targetFieldsTarget.querySelector(".token-label")?.textContent?.trim() || null
  }
}
