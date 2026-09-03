import { Turbo } from "@hotwired/turbo-rails"

function fullReload(frame, want) {
  if (want && frame.getAttribute("src") !== want) {
    frame.setAttribute("src", want)
    return
  }

  if (frame.getAttribute("src")) frame.reload()
}

async function fetchChanges(frame, want, held) {
  const url = new URL(want, window.location.href)
  url.searchParams.set("since", held)

  try {
    const response = await fetch(url, {
      headers: { Accept: "text/vnd.turbo-stream.html" },
      credentials: "same-origin"
    })
    if (response.status === 204) return
    if (!response.ok) return fullReload(frame, want)

    Turbo.renderStreamMessage(await response.text())
  } catch {
    fullReload(frame, want)
  } finally {
    delete frame.dataset.pendingVersion
  }
}

export function reloadFrame(frame, src = null, version = null) {
  if (!frame) return

  const want = src || frame.dataset.src

  if (version) {
    const held = frame.querySelector("[data-version]")?.dataset.version
    if (held === version || frame.dataset.pendingVersion === version) return

    frame.dataset.pendingVersion = version
    if (held && want) return fetchChanges(frame, want, held)

    frame.addEventListener("turbo:frame-load", () => delete frame.dataset.pendingVersion,
      { once: true })
  }

  fullReload(frame, want)
}

export function catchUp(frame) {
  if (!frame || frame.dataset.pendingVersion) return

  const want = frame.dataset.src
  const held = frame.querySelector("[data-version]")?.dataset.version
  if (!want) return
  if (!held) return fullReload(frame, want)

  frame.dataset.pendingVersion = held
  fetchChanges(frame, want, held)
}

Turbo.StreamActions.reload_frame = function () {
  reloadFrame(document.getElementById(this.target), this.getAttribute("src"),
    this.getAttribute("version"))
}

Turbo.StreamActions.upsert = function () {
  const version = this.getAttribute("version")
  const rows = Array.from(this.templateContent.children)

  this.targetElements.forEach((target) => {
    if (version) target.dataset.version = version
    rows.forEach((row) => {
      const had = row.id && document.getElementById(row.id)
      if (had) had.replaceWith(row)
      else target.appendChild(row)
    })
    target.dispatchEvent(new CustomEvent("chat:changed", { bubbles: true }))
  })
}
