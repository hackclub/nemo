import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["pane", "nav"]

  show(event) {
    const name = event.params.pane
    this.paneTargets.forEach((pane) => {
      pane.hidden = pane.dataset.paneName !== name
    })
    this.navTargets.forEach((nav) => {
      nav.classList.toggle("is-active", nav.dataset.paneName === name)
    })
  }
}
