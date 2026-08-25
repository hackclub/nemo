import { Controller } from "@hotwired/stimulus"

const TOKEN = /@([\w.\-]*)$/

function said(className, text) {
  const span = document.createElement("span")
  span.className = className
  span.textContent = text
  return span
}

export default class extends Controller {
  static targets = ["field", "results"]
  static values = { url: String, send: Boolean }

  connect() {
    this.timer = null
    this.away = this.away.bind(this)
    document.addEventListener("click", this.away)
  }

  disconnect() {
    clearTimeout(this.timer)
    document.removeEventListener("click", this.away)
  }

  away(event) {
    if (!this.element.contains(event.target)) this.close()
  }

  type() {
    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.look(), 160)
  }

  token() {
    const upto = this.fieldTarget.value.slice(0, this.fieldTarget.selectionStart)
    return upto.match(TOKEN)
  }

  async look() {
    const found = this.token()
    if (!found || found[1].length < 2) return this.close()

    const response = await fetch(`${this.urlValue}?q=${encodeURIComponent(found[1])}`, {
      headers: { Accept: "application/json" },
    })
    if (!response.ok) return this.close()

    const { members } = await response.json()
    this.show(members)
  }

  show(members) {
    this.resultsTarget.innerHTML = ""
    if (members.length === 0) return this.close()

    for (const member of members) {
      const row = document.createElement("button")
      row.type = "button"
      row.className = "pick-opt"
      row.dataset.action = "click->mention#choose mouseenter->mention#hover"
      row.dataset.id = member.id
      row.append(
        said("avatar", member.initial),
        said("pick-name", member.name),
        said("pick-id mono", member.id)
      )
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
    this.put(event.currentTarget.dataset.id)
  }

  put(id) {
    const field = this.fieldTarget
    const at = field.selectionStart
    const found = this.token()
    if (!found) return

    const start = at - found[0].length
    field.value = `${field.value.slice(0, start)}@${id} ${field.value.slice(at)}`
    const caret = start + id.length + 2
    field.setSelectionRange(caret, caret)
    this.close()
    field.focus()
  }

  keys(event) {
    if (this.resultsTarget.hidden) {
      if (this.sendValue && event.key === "Enter" && !event.shiftKey) {
        event.preventDefault()
        if (this.fieldTarget.value.trim()) this.element.closest("form")?.requestSubmit()
      }
      return
    }

    if (event.key === "ArrowDown") {
      event.preventDefault()
      return this.move(1)
    }

    if (event.key === "ArrowUp") {
      event.preventDefault()
      return this.move(-1)
    }

    if (event.key === "Escape") {
      event.preventDefault()
      return this.close()
    }

    if (event.key === "Enter" || event.key === "Tab") {
      const row = this.rows()[this.at] || this.rows()[0]
      if (!row) return

      event.preventDefault()
      this.put(row.dataset.id)
    }
  }

  close() {
    this.resultsTarget.innerHTML = ""
    this.resultsTarget.hidden = true
  }
}
