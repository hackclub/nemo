import { Controller } from "@hotwired/stimulus"

const NEARLY = 60

export default class extends Controller {
  static targets = ["log"]

  connect() {
    this.following = true
    this.onScroll = this.onScroll.bind(this)
    this.onLoad = this.onLoad.bind(this)

    this.element.addEventListener("scroll", this.onScroll, true)
    this.element.addEventListener("turbo:frame-load", this.onLoad)
    this.element.addEventListener("chat:changed", this.onLoad)
    this.pin()
  }

  disconnect() {
    this.element.removeEventListener("scroll", this.onScroll, true)
    this.element.removeEventListener("turbo:frame-load", this.onLoad)
    this.element.removeEventListener("chat:changed", this.onLoad)
  }

  onScroll(event) {
    if (event.target !== this.logTarget) return

    const log = event.target
    const left = log.scrollHeight - log.scrollTop - log.clientHeight
    this.following = left < NEARLY
  }

  onLoad() {
    if (this.following) this.pin()
  }

  pin() {
    if (this.hasLogTarget) this.logTarget.scrollTop = this.logTarget.scrollHeight
  }
}
