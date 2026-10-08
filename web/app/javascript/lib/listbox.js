import { placePop, clearPop } from "lib/place_pop"

const CACHET = "https://cachet.hackclub.com"
const SVG = "http://www.w3.org/2000/svg"
let made = 0

export function askingFor(where, term) {
  const url = new URL(where, window.location.origin)
  url.searchParams.set("q", term)
  return url
}

export function span(className, text) {
  const el = document.createElement("span")
  el.className = className
  el.textContent = text
  return el
}

export function face(id, initial) {
  const img = document.createElement("img")
  img.className = "avatar"
  img.src = `${CACHET}/users/${encodeURIComponent(id)}/r`
  img.alt = ""
  img.dataset.cachetFace = id
  img.dataset.cachetInitial = initial || "?"
  return img
}

export function named(id, name) {
  const el = span("combo-name", name)
  if (name === `@${id}`) el.dataset.cachetName = id
  return el
}

function hash() {
  const svg = document.createElementNS(SVG, "svg")
  svg.setAttribute("viewBox", "0 0 24 24")
  svg.setAttribute("fill", "none")
  svg.setAttribute("stroke", "currentColor")
  svg.setAttribute("stroke-width", "2")
  svg.setAttribute("stroke-linecap", "round")
  svg.setAttribute("aria-hidden", "true")
  svg.setAttribute("class", "combo-icon")
  const path = document.createElementNS(SVG, "path")
  path.setAttribute("d", "M4 9h16M4 15h16M10 3 8 21M16 3l-2 18")
  svg.append(path)
  return svg
}

function option(id) {
  const row = document.createElement("div")
  row.className = "combo-opt"
  row.id = `combo-opt-${++made}`
  row.setAttribute("role", "option")
  row.setAttribute("aria-selected", "false")
  row.dataset.id = id
  return row
}

export function personOption(member) {
  const row = option(member.id)
  row.dataset.name = member.name
  row.dataset.initial = member.initial || ""

  const bare = member.name.replace(/^@/, "")
  row.append(face(member.id, member.initial), named(member.id, member.name))
  if (member.handle && member.handle !== bare) row.append(span("combo-sub", `@${member.handle}`))
  if (member.deleted) row.append(span("combo-end", "Deactivated"))
  return row
}

export function channelOption(channel) {
  const row = option(channel.id)
  row.dataset.name = channel.name
  row.append(hash(), span("combo-name", channel.name), span("combo-end mono", channel.id))
  return row
}

const OPTIONS = { member: personOption, channel: channelOption }

export class Listbox {
  constructor({ pop, list, anchor, kind, empty, input, pick }) {
    this.pop = pop
    this.list = list || pop
    this.anchor = anchor
    this.input = input
    this.build = OPTIONS[kind] || personOption
    this.empty = empty || "No results"
    this.onPick = pick
    this.at = -1
    this.onMove = () => { if (this.open) this.place() }
    this.list.setAttribute("role", "listbox")
    this.list.id ||= `combo-list-${++made}`
    this.input?.setAttribute("aria-controls", this.list.id)
    this.list.addEventListener("pointerdown", (event) => event.preventDefault())
    this.list.addEventListener("click", (event) => this.clicked(event))
    this.list.addEventListener("pointermove", (event) => this.hovered(event))
  }

  get open() {
    return this.pop.matches(":popover-open")
  }

  rows() {
    return [...this.list.querySelectorAll(".combo-opt")]
  }

  show(items) {
    this.list.replaceChildren()
    if (items.length === 0) {
      this.list.append(span("combo-none", this.empty))
    } else {
      for (const item of items) this.list.append(this.build(item))
    }
    this.at = items.length > 0 ? 0 : -1
    this.mark()
    this.reveal()
  }

  reveal() {
    if (!this.open) this.pop.showPopover()
    this.input?.setAttribute("aria-expanded", "true")
    this.anchor.setAttribute("aria-expanded", "true")
    this.place()
    window.addEventListener("resize", this.onMove)
    document.addEventListener("scroll", this.onMove, true)
  }

  hide() {
    if (this.open) this.pop.hidePopover()
    this.input?.setAttribute("aria-expanded", "false")
    this.anchor.setAttribute("aria-expanded", "false")
    this.input?.removeAttribute("aria-activedescendant")
    this.at = -1
    clearPop(this.pop)
    window.removeEventListener("resize", this.onMove)
    document.removeEventListener("scroll", this.onMove, true)
  }

  place() {
    if (this.pop.classList.contains("combo-pop-fit")) {
      this.pop.style.width = `${this.anchor.getBoundingClientRect().width}px`
    }
    placePop(this.pop, this.anchor)
  }

  mark() {
    this.rows().forEach((row, spot) => {
      const on = spot === this.at
      row.setAttribute("aria-selected", on ? "true" : "false")
      if (on) {
        row.scrollIntoView({ block: "nearest" })
        this.input?.setAttribute("aria-activedescendant", row.id)
      }
    })
    if (this.at < 0) this.input?.removeAttribute("aria-activedescendant")
  }

  move(step) {
    const all = this.rows()
    if (all.length === 0) return

    this.at = this.at < 0
      ? (step > 0 ? 0 : all.length - 1)
      : (this.at + step + all.length) % all.length
    this.mark()
  }

  current() {
    return this.rows()[this.at] || null
  }

  hovered(event) {
    const row = event.target.closest(".combo-opt")
    const spot = this.rows().indexOf(row)
    if (spot < 0 || spot === this.at) return

    this.at = spot
    this.mark()
  }

  clicked(event) {
    const row = event.target.closest(".combo-opt")
    if (row) this.onPick(row.dataset)
  }

  keys(event, { tab = false } = {}) {
    if (!this.open) return false

    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault()
      this.move(event.key === "ArrowDown" ? 1 : -1)
      return true
    }

    if (event.key === "Home" || event.key === "End") {
      const all = this.rows()
      if (all.length === 0) return false
      event.preventDefault()
      this.at = event.key === "Home" ? 0 : all.length - 1
      this.mark()
      return true
    }

    if (event.key === "Escape") {
      event.preventDefault()
      event.stopPropagation()
      this.hide()
      return true
    }

    if (event.key === "Enter" || (tab && event.key === "Tab")) {
      const row = this.current()
      if (!row) return false
      event.preventDefault()
      this.onPick(row.dataset)
      return true
    }

    return false
  }
}
