import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["container", "select"]
  static values = { url: String }

  async change() {
    const url = new URL(window.location)
    url.searchParams.set("activity_granularity", this.selectTarget.value)

    const resp = await fetch(`${this.urlValue}?${url.searchParams}`, {
      headers: { "X-Requested-With": "activity-charts", Accept: "text/html" }
    })
    this.containerTarget.innerHTML = await resp.text()
    history.replaceState({}, "", url)
  }
}
