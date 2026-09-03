import { Turbo } from "@hotwired/turbo-rails"

export function reloadFrame(frame, src = null, version = null) {
  if (!frame) return

  if (version) {
    const held = frame.querySelector("[data-version]")?.dataset.version
    if (held === version || frame.dataset.pendingVersion === version) return
    frame.dataset.pendingVersion = version
    frame.addEventListener("turbo:frame-load", () => delete frame.dataset.pendingVersion,
      { once: true })
  }

  const want = src || frame.dataset.src
  if (want && frame.getAttribute("src") !== want) {
    frame.setAttribute("src", want)
    return
  }

  if (frame.getAttribute("src")) frame.reload()
}

Turbo.StreamActions.reload_frame = function () {
  reloadFrame(document.getElementById(this.target), this.getAttribute("src"),
    this.getAttribute("version"))
}
