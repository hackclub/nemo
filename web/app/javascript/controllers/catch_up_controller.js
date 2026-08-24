import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { frame: String }

  connect() {
    this.dropped = false
    this.onChange = this.onChange.bind(this)

    const source = this.source
    if (!source) return

    this.watch = new MutationObserver(this.onChange)
    this.watch.observe(source, { attributeFilter: ["connected"] })
  }

  disconnect() {
    if (this.watch) this.watch.disconnect()
  }

  get source() {
    return this.element.querySelector("turbo-cable-stream-source")
  }

  onChange() {
    const source = this.source
    if (!source) return

    if (!source.hasAttribute("connected")) {
      this.dropped = true
      return
    }

    if (!this.dropped) return

    this.dropped = false
    this.catchUp()
  }

  catchUp() {
    const frame = document.getElementById(this.frameValue)
    if (frame) frame.reload()
  }
}
