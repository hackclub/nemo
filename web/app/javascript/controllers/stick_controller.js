import { Controller } from "@hotwired/stimulus"

const NEARLY = 60

export default class extends Controller {
  connect() {
    this.following = true
    this.onScroll = this.onScroll.bind(this)
    this.onLoad = this.onLoad.bind(this)

    this.element.addEventListener("scroll", this.onScroll, true)
    this.element.addEventListener("turbo:frame-load", this.onLoad)
    this.pin()
  }

  disconnect() {
    this.element.removeEventListener("scroll", this.onScroll, true)
    this.element.removeEventListener("turbo:frame-load", this.onLoad)
  }

  get log() {
    return this.element.querySelector(".chat-log")
  }

  onScroll(event) {
    const log = event.target
    if (!log.classList?.contains("chat-log")) return

    const left = log.scrollHeight - log.scrollTop - log.clientHeight
    this.following = left < NEARLY
  }

  onLoad() {
    if (this.following) this.pin()
  }

  pin() {
    const log = this.log
    if (log) log.scrollTop = log.scrollHeight
  }
}
