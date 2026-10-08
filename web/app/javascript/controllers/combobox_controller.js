import { Controller } from "@hotwired/stimulus"
import { Listbox, askingFor, face, span } from "lib/listbox"

const SLACK_ID = /^[UW][A-Z0-9]{2,}$/

export default class extends Controller {
  static targets = ["field", "trigger", "input", "pop", "list", "store"]
  static values = {
    url: String,
    kind: { type: String, default: "member" },
    name: String,
    single: Boolean,
    submit: Boolean,
    preset: Array,
    least: Number,
    empty: String
  }

  connect() {
    this.chosen = new Map()
    for (const { id, name, initial } of this.presetValue) this.chosen.set(id, { name, initial })
    this.blank = this.inputTarget.placeholder
    this.box = new Listbox({
      pop: this.popTarget,
      list: this.listTarget,
      anchor: this.hasFieldTarget ? this.fieldTarget : this.triggerTarget,
      input: this.inputTarget,
      kind: this.kindValue,
      empty: this.emptyValue,
      pick: (picked) => this.take(picked)
    })
    this.away = (event) => {
      if (!this.element.contains(event.target)) this.close()
    }
    document.addEventListener("pointerdown", this.away)
    this.render()
  }

  disconnect() {
    clearTimeout(this.timer)
    this.asking?.abort()
    document.removeEventListener("pointerdown", this.away)
    this.box.hide()
  }

  get inline() {
    return this.hasFieldTarget
  }

  focus(event) {
    if (event.target === this.fieldTarget) this.inputTarget.focus()
  }

  wake() {
    if (!this.hush && this.leastValue === 0 && !this.box.open) this.look()
  }

  toggle() {
    if (this.box.open) return this.close()

    this.inputTarget.value = ""
    this.box.reveal()
    this.inputTarget.focus()
    this.look()
  }

  type() {
    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.look(), 150)
  }

  leave(event) {
    if (!this.element.contains(event.relatedTarget)) this.close()
  }

  async look() {
    const term = this.inputTarget.value.trim()
    this.asking?.abort()
    if (term.length < this.leastValue) {
      if (this.inline) this.box.hide()
      return
    }

    const asking = new AbortController()
    this.asking = asking
    let found
    try {
      const response = await fetch(askingFor(this.urlValue, term), {
        headers: { Accept: "application/json" },
        signal: asking.signal
      })
      if (!response.ok) throw new Error(`search failed with ${response.status}`)
      found = await response.json()
    } catch {
      if (!asking.signal.aborted) this.close()
      return
    }
    if (asking.signal.aborted) return
    if (this.inline ? document.activeElement !== this.inputTarget : !this.box.open) return

    const items = found.members || found.channels || []
    this.box.show(items.filter((item) => !this.chosen.has(item.id)))
  }

  take({ id, name, initial }) {
    if (this.singleValue) this.chosen.clear()
    this.chosen.set(id, { name, initial })
    this.inputTarget.value = ""
    this.close()
    this.render()
    if (this.submitValue) return this.element.closest("form")?.requestSubmit()

    this.hush = true
    ;(this.inline ? this.inputTarget : this.triggerTarget).focus()
    this.hush = false
  }

  drop(event) {
    this.chosen.delete(event.currentTarget.dataset.id)
    this.render()
    this.inputTarget.focus()
  }

  keys(event) {
    if (this.box.keys(event)) {
      if (event.key === "Escape" && !this.inline) this.triggerTarget.focus()
      return
    }

    if (event.key === "Enter") {
      event.preventDefault()
      const typed = this.inputTarget.value.trim().toUpperCase()
      if (this.kindValue === "member" && SLACK_ID.test(typed)) {
        this.take({ id: typed, name: `@${typed}`, initial: typed[1] })
      }
      return
    }

    if (event.key === "ArrowDown" && this.inline) {
      event.preventDefault()
      return this.look()
    }

    if (event.key === "Backspace" && this.inline && this.inputTarget.value === "" && this.chosen.size > 0) {
      this.chosen.delete([...this.chosen.keys()].pop())
      this.render()
    }
  }

  close() {
    clearTimeout(this.timer)
    this.asking?.abort()
    this.box.hide()
  }

  render() {
    if (this.inline) {
      for (const token of this.fieldTarget.querySelectorAll(".token")) token.remove()
      for (const [id, chosen] of this.chosen) {
        this.fieldTarget.insertBefore(this.token(id, chosen), this.inputTarget)
      }
      this.inputTarget.placeholder = this.chosen.size > 0 ? "" : this.blank
    }

    this.storeTarget.replaceChildren(...[...this.chosen.keys()].map((id) => {
      const held = document.createElement("input")
      held.type = "hidden"
      held.name = this.nameValue
      held.value = id
      return held
    }))
    this.dispatch("picked", { detail: { chosen: [...this.chosen.keys()] } })
  }

  token(id, { name, initial }) {
    const token = document.createElement("span")
    token.className = "token"
    const shown = this.kindValue === "channel" ? `#${name}` : name
    const label = span("token-label", shown)

    if (this.kindValue === "channel") {
      token.classList.add("token-plain")
    } else {
      token.append(face(id, initial))
      if (name === `@${id}`) label.dataset.cachetName = id
    }

    const remove = document.createElement("button")
    remove.type = "button"
    remove.className = "token-x"
    remove.dataset.id = id
    remove.dataset.action = "combobox#drop"
    remove.setAttribute("aria-label", `Remove ${shown}`)
    remove.innerHTML = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><path d="M18 6 6 18M6 6l12 12"/></svg>'

    token.append(label, remove)
    return token
  }
}
