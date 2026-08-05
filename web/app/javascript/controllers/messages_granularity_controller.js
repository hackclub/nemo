import SelectorController from "controllers/selector"

export default class extends SelectorController {
  static targets = ["container"]
  static values = { url: String }

  get param() { return "messages_granularity" }
  get requestedWith() { return "member-messages" }
}
