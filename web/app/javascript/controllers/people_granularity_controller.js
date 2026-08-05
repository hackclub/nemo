import SelectorController from "controllers/selector"

export default class extends SelectorController {
  static targets = ["container"]
  static values = { url: String }

  get param() { return "people_granularity" }
  get requestedWith() { return "active-people" }
}
