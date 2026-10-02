import { Controller } from "@hotwired/stimulus"
import { catchUp } from "turbo_actions"

export default class extends Controller {
  static values = { frame: String }

  connect() {
    this.dropped = false
    this.onChange = this.onChange.bind(this)
    this.onVisible = this.onVisible.bind(this)

    document.addEventListener("visibilitychange", this.onVisible)

    const source = this.source
    if (!source) return

    this.watch = new MutationObserver(this.onChange)
    this.watch.observe(source, { attributeFilter: ["connected"] })
  }

  disconnect() {
    document.removeEventListener("visibilitychange", this.onVisible)
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

  onVisible() {
    if (document.visibilityState === "visible") this.catchUp()
  }

  catchUp() {
    catchUp(document.getElementById(this.frameValue))
  }
}
