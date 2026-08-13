import { Controller } from "@hotwired/stimulus"

const TOKEN = /@([\w.\-]*)$/

export default class extends Controller {
  static targets = ["field", "results"]
  static values = { url: String }

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
      row.dataset.action = "click->mention#choose"
      row.dataset.id = member.id
      row.innerHTML = `<span class="avatar">${member.initial}</span>
        <span class="pick-name">${member.name}</span>
        <span class="pick-id mono">${member.id}</span>`
      this.resultsTarget.append(row)
    }
    this.resultsTarget.hidden = false
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
    if (this.resultsTarget.hidden) return

    if (event.key === "Escape") {
      event.preventDefault()
      return this.close()
    }

    if (event.key === "Enter" || event.key === "Tab") {
      const first = this.resultsTarget.querySelector(".pick-opt")
      if (!first) return

      event.preventDefault()
      this.put(first.dataset.id)
    }
  }

  close() {
    this.resultsTarget.innerHTML = ""
    this.resultsTarget.hidden = true
  }
}
