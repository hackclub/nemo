import { Controller } from "@hotwired/stimulus"
import { Listbox, askingFor } from "lib/listbox"

const TOKEN = /@([\w.\-]*)$/

export default class extends Controller {
  static targets = ["field", "pop", "list"]
  static values = { url: String }

  connect() {
    this.timer = null
    this.box = new Listbox({
      pop: this.popTarget,
      list: this.listTarget,
      anchor: this.fieldTarget,
      input: this.fieldTarget,
      kind: "member",
      empty: "No members found",
      pick: ({ id }) => this.put(id)
    })
    this.away = (event) => {
      if (!this.element.contains(event.target)) this.close()
    }
    document.addEventListener("pointerdown", this.away)
  }

  disconnect() {
    clearTimeout(this.timer)
    this.asking?.abort()
    document.removeEventListener("pointerdown", this.away)
    this.box.hide()
  }

  type() {
    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.look(), 150)
  }

  token() {
    const upto = this.fieldTarget.value.slice(0, this.fieldTarget.selectionStart)
    return upto.match(TOKEN)
  }

  async look() {
    const found = this.token()
    this.asking?.abort()
    if (!found || found[1].length < 2) return this.close()

    const asking = new AbortController()
    this.asking = asking
    let members
    try {
      const response = await fetch(askingFor(this.urlValue, found[1]), {
        headers: { Accept: "application/json" },
        signal: asking.signal
      })
      if (!response.ok) throw new Error(`search failed with ${response.status}`)
      ;({ members } = await response.json())
    } catch {
      if (!asking.signal.aborted) this.close()
      return
    }
    if (asking.signal.aborted) return
    if (members.length === 0) return this.close()

    this.box.show(members)
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
    this.box.keys(event, { tab: true })
  }

  close() {
    clearTimeout(this.timer)
    this.asking?.abort()
    this.box.hide()
  }
}
