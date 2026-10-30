import { Turbo } from "@hotwired/turbo-rails"

function fullReload(frame, targetSrc) {
  if (targetSrc && frame.getAttribute("src") !== targetSrc) {
    frame.setAttribute("src", targetSrc)
    return
  }

  if (frame.getAttribute("src")) frame.reload()
}

async function fetchChanges(frame, targetSrc, currentVersion) {
  const url = new URL(targetSrc, window.location.href)
  url.searchParams.set("since", currentVersion)

  try {
    const response = await fetch(url, {
      headers: { Accept: "text/vnd.turbo-stream.html" },
      credentials: "same-origin"
    })
    if (response.status === 204) return
    if (!response.ok) return fullReload(frame, targetSrc)

    Turbo.renderStreamMessage(await response.text())
  } catch {
    fullReload(frame, targetSrc)
  } finally {
    delete frame.dataset.pendingVersion
  }
}

export function reloadFrame(frame, src = null, version = null) {
  if (!frame) return

  const targetSrc = src || frame.dataset.src

  if (version) {
    const currentVersion = frame.querySelector("[data-version]")?.dataset.version
    if (currentVersion === version || frame.dataset.pendingVersion === version) return

    frame.dataset.pendingVersion = version
    if (currentVersion && targetSrc) return fetchChanges(frame, targetSrc, currentVersion)

    frame.addEventListener("turbo:frame-load", () => delete frame.dataset.pendingVersion,
      { once: true })
  }

  fullReload(frame, targetSrc)
}

export function syncFrame(frame) {
  if (!frame || frame.dataset.pendingVersion) return

  const targetSrc = frame.dataset.src
  const currentVersion = frame.querySelector("[data-version]")?.dataset.version
  if (!targetSrc) return
  if (!currentVersion) return fullReload(frame, targetSrc)

  frame.dataset.pendingVersion = currentVersion
  fetchChanges(frame, targetSrc, currentVersion)
}

const SCROLL_PRESERVING_LINKS = {
  ".views a, .segmented a, .member-record-tabs a":
    [".scrollarea", ".pane-list", ".member-record-content", ".case-tab-body"],
  ".queue-row, .thread-tabs a, .thread-pop a": [".pane-list"]
}
let savedScrollTops = null

document.addEventListener("click", (event) => {
  const [links, scrollers] = Object.entries(SCROLL_PRESERVING_LINKS)
    .find(([selector]) => event.target.closest(selector)) || []
  const link = links && event.target.closest(links)
  if (!link || link.target === "_blank" || link.dataset.turboFrame) return

  savedScrollTops = scrollers.map((selector) => [selector, document.querySelector(selector)?.scrollTop ?? null])
})

document.addEventListener("turbo:render", () => {
  if (!savedScrollTops) return

  const savedTops = savedScrollTops
  if (!document.documentElement.hasAttribute("data-turbo-preview")) savedScrollTops = null
  savedTops.forEach(([selector, top]) => {
    const box = document.querySelector(selector)
    if (box && top !== null) box.scrollTop = top
  })
})

document.addEventListener("turbo:visit", (event) => {
  if (savedScrollTops && event.detail?.action === "restore") savedScrollTops = null
})

Turbo.StreamActions.reload_frame = function () {
  reloadFrame(document.getElementById(this.target), this.getAttribute("src"),
    this.getAttribute("version"))
}

Turbo.StreamActions.audit_event = function () {
  try {
    const detail = JSON.parse(this.getAttribute("payload") || "{}")
    document.dispatchEvent(new CustomEvent("audit:event", { detail }))
  } catch {
    document.dispatchEvent(new CustomEvent("audit:event", { detail: { truncated: true } }))
  }
}

Turbo.StreamActions.refresh_frame = function () {
  const frame = document.getElementById(this.target)
  if (frame?.hasAttribute("complete")) frame.reload()
}

Turbo.StreamActions.upsert = function () {
  const version = this.getAttribute("version")
  const rows = Array.from(this.templateContent.children)

  this.targetElements.forEach((target) => {
    if (version) target.dataset.version = version
    rows.forEach((row) => {
      const existing = row.id && document.getElementById(row.id)
      if (existing) existing.replaceWith(row)
      else target.appendChild(row)
    })
    target.dispatchEvent(new CustomEvent("chat:changed", { bubbles: true }))
  })
}
