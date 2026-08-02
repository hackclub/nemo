import { Controller } from "@hotwired/stimulus"

export default class SelectorController extends Controller {
  static targets = ["container", "select"]
  static values = { url: String }

  get param() {
    throw new Error("selector controllers must define a param")
  }

  get requestedWith() {
    throw new Error("selector controllers must define a requestedWith")
  }

  async change() {
    const url = new URL(window.location)
    url.searchParams.set(this.param, this.selectTarget.value)

    const resp = await fetch(`${this.urlValue}?${url.searchParams}`, {
      headers: { "X-Requested-With": this.requestedWith, Accept: "text/html" }
    })
    this.containerTarget.innerHTML = await resp.text()
    history.replaceState({}, "", url)
  }
}
