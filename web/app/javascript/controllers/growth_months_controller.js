import SelectorController from "controllers/selector"

export default class extends SelectorController {
  static targets = ["container", "select"]
  static values = { url: String }

  get param() { return "growth_months" }
  get requestedWith() { return "growth" }
}
