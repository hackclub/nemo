import SelectorController from "controllers/selector"

export default class extends SelectorController {
  static targets = ["container", "select"]
  static values = { url: String }

  get param() { return "cohort_month" }
  get requestedWith() { return "onboarding-funnel" }
}
