import { Controller } from "@hotwired/stimulus"

function said(className, text) {
  const span = document.createElement("span")
  span.className = className
  span.textContent = text
  return span
}

function face(id, initial) {
  const img = document.createElement("img")
  img.className = "avatar"
  img.src = `https://cachet.hackclub.com/users/${encodeURIComponent(id)}/r`
  img.alt = ""
  img.dataset.cachetFace = id
  img.dataset.cachetInitial = initial || "?"
  return img
}

function named(id, name) {
  const span = said("pick-name", name)
  if (name === `@${id}`) span.dataset.cachetName = id
  return span
}

export default class extends Controller {
  static targets = ["field", "input", "results", "store"]
  static values = { name: String, url: String, single: Boolean, preset: Array }

  connect() {
    this.chosen = new Map()
    this.timer = null
    for (const { id, name, initial, image } of this.presetValue) {
      this.chosen.set(id, { name, initial, image })
    }
    this.render()
    this.away = this.away.bind(this)
    document.addEventListener("click", this.away)
  }

  disconnect() {
    clearTimeout(this.timer)
    document.removeEventListener("click", this.away)
  }

  away(event) {
    if (!this.element.contains(event.target)) this.clearResults()
  }

  type() {
    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.look(), 180)
  }

  async look() {
    const term = this.inputTarget.value.trim()
    if (term.length < 2) return this.clearResults()

    const response = await fetch(`${this.urlValue}?q=${encodeURIComponent(term)}`, {
      headers: { Accept: "application/json" },
    })
    if (!response.ok) return this.clearResults()

    const { members } = await response.json()
    this.show(members.filter((member) => !this.chosen.has(member.id)))
  }

  show(members) {
    this.resultsTarget.innerHTML = ""
    if (members.length === 0) {
      this.resultsTarget.hidden = true
      return
    }

    for (const member of members) {
      const row = document.createElement("button")
      row.type = "button"
      row.className = "pick-opt"
      row.dataset.action = "click->member-picker#choose mouseenter->member-picker#hover"
      row.dataset.id = member.id
      row.dataset.name = member.name
      row.dataset.initial = member.initial
      row.dataset.image = member.image || ""
      const bare = member.name.replace(/^@/, "")
      const sub = [
        member.handle && member.handle !== bare ? `@${member.handle}` : null,
        member.id !== bare ? member.id : null
      ].filter(Boolean).join(" · ")
      const body = said("pick-body-text", "")
      body.append(named(member.id, member.name), said("pick-id mono", sub))
      row.append(face(member.id, member.initial), body)
      this.resultsTarget.append(row)
    }
    this.resultsTarget.hidden = false
    this.at = -1
    this.mark()
  }

  rows() {
    return [...this.resultsTarget.querySelectorAll(".pick-opt")]
  }

  mark() {
    this.rows().forEach((row, spot) => {
      const on = spot === this.at
      row.setAttribute("aria-selected", on ? "true" : "false")
      if (on) row.scrollIntoView({ block: "nearest" })
    })
  }

  move(step) {
    const all = this.rows()
    if (all.length === 0) return

    this.at = this.at < 0
      ? (step > 0 ? 0 : all.length - 1)
      : (this.at + step + all.length) % all.length
    this.mark()
  }

  hover(event) {
    this.at = this.rows().indexOf(event.currentTarget)
    this.mark()
  }

  choose(event) {
    const { id, name, initial, image } = event.currentTarget.dataset
    this.add(id, name, initial, image)
  }

  add(id, name, initial, image = "") {
    if (this.singleValue) this.chosen.clear()
    this.chosen.set(id, { name, initial, image })
    this.inputTarget.value = ""
    this.clearResults()
    this.render()
    this.inputTarget.focus()
  }

  drop(event) {
    this.chosen.delete(event.currentTarget.dataset.id)
    this.render()
  }

  keys(event) {
    if (!this.resultsTarget.hidden && (event.key === "ArrowDown" || event.key === "ArrowUp")) {
      event.preventDefault()
      return this.move(event.key === "ArrowDown" ? 1 : -1)
    }

    if (event.key === "Enter") {
      event.preventDefault()
      const row = this.rows()[this.at] || this.rows()[0]
      if (row) return row.click()

      const typed = this.inputTarget.value.trim().toUpperCase()
      if (/^[UW][A-Z0-9]{2,}$/.test(typed)) this.add(typed, `@${typed}`, typed[1] || "?")
      return
    }

    if (event.key === "Backspace" && this.inputTarget.value === "" && this.chosen.size > 0) {
      const last = [...this.chosen.keys()].pop()
      this.chosen.delete(last)
      this.render()
    }

    if (event.key === "Escape") this.clearResults()
  }

  clearResults() {
    this.resultsTarget.innerHTML = ""
    this.resultsTarget.hidden = true
  }

  render() {
    for (const token of this.fieldTarget.querySelectorAll(".token")) token.remove()

    for (const [id, { name, initial, image }] of this.chosen) {
      const token = document.createElement("span")
      token.className = "token"
      const label = document.createElement("span")
      label.textContent = name
      if (name === `@${id}`) label.dataset.cachetName = id
      token.append(face(id, initial), label)

      const remove = document.createElement("button")
      remove.type = "button"
      remove.className = "token-x"
      remove.dataset.id = id
      remove.dataset.action = "click->member-picker#drop"
      remove.setAttribute("aria-label", `remove ${name}`)
      remove.textContent = "×"
      token.append(remove)

      this.fieldTarget.insertBefore(token, this.inputTarget)
    }

    this.storeTarget.innerHTML = ""
    for (const id of this.chosen.keys()) {
      const held = document.createElement("input")
      held.type = "hidden"
      held.name = this.nameValue
      held.value = id
      this.storeTarget.append(held)
    }

    this.inputTarget.placeholder = this.chosen.size > 0 ? "" : "search by name or paste a user id"
  }
}
