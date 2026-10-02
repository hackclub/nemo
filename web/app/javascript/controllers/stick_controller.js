import { Controller } from "@hotwired/stimulus"

const NEARLY = 60
const LOG = "chatscroll"

export default class extends Controller {
  connect() {
    this.following = true
    this.onScroll = this.onScroll.bind(this)
    this.onLoad = this.onLoad.bind(this)
    this.onAppend = this.onAppend.bind(this)
    this.onImage = this.onImage.bind(this)

    this.element.addEventListener("scroll", this.onScroll, true)
    this.element.addEventListener("turbo:frame-load", this.onLoad)
    this.element.addEventListener("chat:changed", this.onAppend)
    this.element.addEventListener("load", this.onImage, true)
    this.settle()
  }

  disconnect() {
    this.element.removeEventListener("scroll", this.onScroll, true)
    this.element.removeEventListener("turbo:frame-load", this.onLoad)
    this.element.removeEventListener("chat:changed", this.onAppend)
    this.element.removeEventListener("load", this.onImage, true)
  }

  get log() {
    return this.element.querySelector(`.${LOG}`)
  }

  onScroll(event) {
    const log = event.target
    if (!log.classList?.contains(LOG)) return

    const left = log.scrollHeight - log.scrollTop - log.clientHeight
    this.following = left < NEARLY
  }

  onLoad() {
    this.following = true
    this.settle()
  }

  onAppend() {
    if (this.following) this.settle()
  }

  onImage(event) {
    if (!this.following || event.target.tagName !== "IMG") return
    if (!this.log?.contains(event.target)) return

    this.pin()
  }

  settle() {
    this.pin()
    requestAnimationFrame(() => this.pin())
  }

  pin() {
    const log = this.log
    if (log) log.scrollTop = log.scrollHeight
  }
}
