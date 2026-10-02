import { Controller } from "@hotwired/stimulus"

const HOST = "https://cachet.hackclub.com"
const TTL = 12 * 60 * 60 * 1000
const LANES = 8
const NAME = "[data-cachet-name]"
const FACE = "img[data-cachet-face]"

const held = new Map()
const flying = new Map()
const queue = []
let busy = 0

function remembered(id) {
  if (held.has(id)) return held.get(id)
  try {
    const raw = sessionStorage.getItem(`cachet:${id}`)
    if (!raw) return null
    const row = JSON.parse(raw)
    if (Date.now() - row.at > TTL) return null
    held.set(id, row.profile)
    return row.profile
  } catch {
    return null
  }
}

function remember(id, profile) {
  held.set(id, profile)
  try {
    sessionStorage.setItem(`cachet:${id}`, JSON.stringify({ at: Date.now(), profile }))
  } catch {
    return
  }
}

function drain() {
  while (busy < LANES && queue.length > 0) {
    const { id, settle } = queue.shift()
    busy += 1
    fetch(`${HOST}/users/${encodeURIComponent(id)}`, { headers: { Accept: "application/json" } })
      .then((response) => (response.ok ? response.json() : null))
      .then((body) => {
        const known = body && body.displayName && body.displayName !== "Unknown"
        const profile = { name: known ? body.displayName : null, image: known ? body.imageUrl : null }
        if (known || (body && body.displayName === "Unknown")) remember(id, profile)
        settle(profile)
      })
      .catch(() => settle(null))
      .finally(() => {
        busy -= 1
        flying.delete(id)
        drain()
      })
  }
}

export function profile(id) {
  const had = remembered(id)
  if (had) return Promise.resolve(had)
  if (flying.has(id)) return flying.get(id)

  const wait = new Promise((settle) => queue.push({ id, settle }))
  flying.set(id, wait)
  drain()
  return wait
}

function fallback(img) {
  const span = document.createElement("span")
  span.className = `${img.className} ${img.dataset.cachetTone || "av-none"}`.trim()
  span.textContent = img.dataset.cachetInitial || "?"
  span.setAttribute("aria-hidden", "true")
  for (const key of ["user", "name"]) {
    if (img.dataset[key] !== undefined) span.dataset[key] = img.dataset[key]
  }
  img.replaceWith(span)
}

function fill(node) {
  if (node.dataset.cachetDone) return
  node.dataset.cachetDone = "1"

  if (node.matches(FACE)) {
    const id = node.dataset.cachetFace
    node.addEventListener("error", () => fallback(node), { once: true })
    profile(id).then((found) => {
      if (found && found.name === null && node.isConnected) fallback(node)
    })
    return
  }

  const id = node.dataset.cachetName
  profile(id).then((found) => {
    if (found && found.name && node.isConnected) node.textContent = found.name
  })
}

export function hydrate(root) {
  if (!(root instanceof Element)) return
  if (root.matches(`${NAME}, ${FACE}`)) fill(root)
  for (const node of root.querySelectorAll(`${NAME}, ${FACE}`)) fill(node)
}

export default class extends Controller {
  connect() {
    hydrate(this.element)
    this.watcher = new MutationObserver((changes) => {
      for (const change of changes) {
        for (const node of change.addedNodes) hydrate(node)
      }
    })
    this.watcher.observe(this.element, { childList: true, subtree: true })
  }

  disconnect() {
    this.watcher?.disconnect()
  }
}
