import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["container", "select"]
  static values = { url: String }

  async change() {
    const params = new URLSearchParams({ top_posters_month: this.selectTarget.value })
    const resp = await fetch(`${this.urlValue}?${params}`, {
      headers: { "X-Requested-With": "top-posters", Accept: "text/html" }
    })
    this.containerTarget.innerHTML = await resp.text()
  }
}
