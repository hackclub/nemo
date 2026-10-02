import { Controller } from "@hotwired/stimulus"

const CHANNEL_SCOPED = ["channel_ban"]

export default class extends Controller {
  static targets = ["channel"]

  connect() {
    this.fit()
  }

  fit() {
    if (!this.hasChannelTarget) return

    const kind = this.element.querySelector('input[name="kind"]:checked')?.value
    this.channelTarget.hidden = !CHANNEL_SCOPED.includes(kind)
  }
}
