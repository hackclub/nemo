import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["img"]

  connect() {
    if (this.hasImgTarget && this.imgTarget.complete && this.imgTarget.naturalWidth === 0) this.gone()
  }

  gone() {
    this.imgTarget.remove()
  }
}
