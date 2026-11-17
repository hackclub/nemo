import { Controller } from "@hotwired/stimulus"

const BOTTOM_THRESHOLD = 60
const LOG = "chatscroll"

export default class extends Controller {
  static reconnectOnMorph = false

  connect() {
    this.followBottom = true
    this.onScroll = this.onScroll.bind(this)
    this.onLoad = this.onLoad.bind(this)
    this.onAppend = this.onAppend.bind(this)
    this.onImage = this.onImage.bind(this)

    this.element.addEventListener("scroll", this.onScroll, true)
    this.element.addEventListener("turbo:frame-load", this.onLoad)
    this.element.addEventListener("chat:changed", this.onAppend)
    this.element.addEventListener("load", this.onImage, true)
    this.scrollToBottomAfterRender()
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

    const distanceFromBottom = log.scrollHeight - log.scrollTop - log.clientHeight
    this.followBottom = distanceFromBottom < BOTTOM_THRESHOLD
  }

  onLoad(event) {
    if (event.target.closest?.("[data-earlier]")) return

    this.followBottom = true
    this.scrollToBottomAfterRender()
  }

  onAppend() {
    if (this.followBottom) this.scrollToBottomAfterRender()
  }

  onImage(event) {
    if (!this.followBottom || event.target.tagName !== "IMG") return
    if (!this.log?.contains(event.target)) return

    this.scrollToBottom()
  }

  scrollToBottomAfterRender() {
    this.scrollToBottom()
    requestAnimationFrame(() => this.scrollToBottom())
  }

  scrollToBottom() {
    const log = this.log
    if (log) log.scrollTop = log.scrollHeight
  }
}
