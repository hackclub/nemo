import { Controller } from "@hotwired/stimulus"

const NARROW = "(max-width: 899px)"

export default class extends Controller {
  connect() {
    this.narrow = window.matchMedia(NARROW)
    this.onChange = () => this.place()
    this.narrow.addEventListener("change", this.onChange)
    this.place()
  }

  disconnect() {
    this.narrow?.removeEventListener("change", this.onChange)
  }

  place() {
    const bar = this.element.querySelector(".mobar")
    const actions = this.element.querySelector(".ractions")
    const top = this.element.querySelector(".rhead > .rtop")
    if (!bar || !actions) return

    const home = this.narrow.matches ? bar : top
    if (home && actions.parentElement !== home) home.append(actions)
  }
}
