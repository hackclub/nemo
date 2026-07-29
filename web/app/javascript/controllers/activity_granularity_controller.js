import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["container", "select"]
  static values = { url: String }

  async change() {
    const params = new URLSearchParams({ activity_granularity: this.selectTarget.value })
    const resp = await fetch(`${this.urlValue}?${params}`, {
      headers: { "X-Requested-With": "activity-charts", Accept: "text/html" }
    })
    this.containerTarget.innerHTML = await resp.text()
  }
}
