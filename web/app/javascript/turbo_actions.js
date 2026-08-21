import { Turbo } from "@hotwired/turbo-rails"

Turbo.StreamActions.reload_frame = function () {
  const frame = document.getElementById(this.target)
  if (!frame) return

  const src = this.getAttribute("src")
  if (src && frame.src !== src) {
    frame.src = src
    return
  }

  frame.reload()
}
