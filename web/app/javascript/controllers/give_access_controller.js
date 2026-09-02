import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["role", "scope", "channels", "area", "empty", "note", "scopes"]
  static values = { baselines: Object, channelRole: { type: String, default: "promethean" } }

  connect() {
    this.settle()
  }

  settle() {
    const role = this.picked()
    const carried = new Set(this.baselinesValue[role] || [])

    this.channelsTarget.hidden = role !== this.channelRoleValue

    let left = 0
    for (const row of this.scopeTargets) {
      const gone = carried.has(row.dataset.key)
      row.hidden = gone
      if (gone) {
        const box = row.querySelector("input[type=checkbox]")
        if (box) box.checked = false
      } else {
        left += 1
      }
    }

    for (const area of this.areaTargets) {
      const rows = this.scopeTargets.filter((row) => row.dataset.area === area.dataset.area)
      area.hidden = rows.every((row) => row.hidden)
    }

    if (this.hasEmptyTarget) this.emptyTarget.hidden = left > 0
    if (this.hasScopesTarget) this.scopesTarget.hidden = left === 0
    if (this.hasNoteTarget) this.noteTarget.textContent = this.roleNote(role)
  }

  roleNote(role) {
    const carried = (this.baselinesValue[role] || []).length
    if (!role) return "A member. Reads the overview and public channels."
    if (carried === 0) return ""
    return `Carries ${carried} capabilit${carried === 1 ? "y" : "ies"} on its own.`
  }

  picked() {
    const on = this.roleTargets.find((one) => one.checked)
    return on ? on.value : ""
  }
}
