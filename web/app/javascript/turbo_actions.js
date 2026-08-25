import { Turbo } from "@hotwired/turbo-rails"

export function reloadFrame(frame, src = null) {
  if (!frame) return

  const want = src || frame.dataset.src
  if (want && frame.getAttribute("src") !== want) {
    frame.setAttribute("src", want)
    return
  }

  if (frame.getAttribute("src")) frame.reload()
}

Turbo.StreamActions.reload_frame = function () {
  reloadFrame(document.getElementById(this.target), this.getAttribute("src"))
}
