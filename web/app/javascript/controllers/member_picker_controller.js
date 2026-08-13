import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["field", "input", "results", "store"]
  static values = { name: String, url: String, single: Boolean, preset: Array }

  connect() {
    this.chosen = new Map()
    this.timer = null
    for (const { id, name, initial } of this.presetValue) {
      this.chosen.set(id, { name, initial })
    }
    this.render()
  }

  disconnect() {
    clearTimeout(this.timer)
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
      row.dataset.action = "click->member-picker#choose"
      row.dataset.id = member.id
      row.dataset.name = member.name
      row.dataset.initial = member.initial
      row.innerHTML = `<span class="avatar">${member.initial}</span>
        <span class="pick-name">${member.name}</span>
        <span class="pick-id mono">${member.id}</span>`
      this.resultsTarget.append(row)
    }
    this.resultsTarget.hidden = false
  }

  choose(event) {
    const { id, name, initial } = event.currentTarget.dataset
    this.add(id, name, initial)
  }

  add(id, name, initial) {
    if (this.singleValue) this.chosen.clear()
    this.chosen.set(id, { name, initial })
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
    if (event.key === "Enter") {
      event.preventDefault()
      const first = this.resultsTarget.querySelector(".pick-opt")
      if (first) return first.click()

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

    for (const [id, { name, initial }] of this.chosen) {
      const token = document.createElement("span")
      token.className = "token"
      token.innerHTML = `<span class="avatar">${initial}</span>${name}`

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
