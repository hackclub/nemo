import SelectorController from "controllers/selector"

export default class extends SelectorController {
  static targets = ["container", "select"]
  static values = { url: String }

  get param() { return "recurrence_month" }
  get requestedWith() { return "recurrence-funnel" }
}
