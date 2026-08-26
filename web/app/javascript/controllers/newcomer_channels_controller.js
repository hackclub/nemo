import SelectorController from "controllers/selector"

export default class extends SelectorController {
  static targets = ["container"]
  static values = { url: String }

  get param() { return "newcomer_measure" }
  get requestedWith() { return "newcomer-channels" }
}
