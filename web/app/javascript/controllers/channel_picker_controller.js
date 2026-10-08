import { Controller } from "@hotwired/stimulus"

function span(className, text) {
  const el = document.createElement("span")
  el.className = className
  el.textContent = text
  return el
}

export default class extends Controller {
  static targets = ["input", "results", "store", "chosen", "count"]
  static values = { name: String, url: String, submit: Boolean }

  connect() {
    this.blank = this.inputTarget.placeholder
    this.timer = null
    this.asked = 0
    this.picked = null
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

  opened() {
    requestAnimationFrame(() => {
      this.inputTarget.focus()
      this.look()
    })
  }

  async look() {
    const term = this.inputTarget.value.trim()
    const mine = ++this.asked
    const response = await fetch(`${this.urlValue}?q=${encodeURIComponent(term)}`, {
      headers: { Accept: "application/json" },
    })
    if (mine !== this.asked) return
    if (!response.ok) return this.clearResults()

    const { channels, total } = await response.json()
    if (mine !== this.asked) return
    this.show(channels)
    if (this.hasCountTarget) {
      this.countTarget.textContent = total > channels.length
        ? `${channels.length} of ${total} channels`
        : `${total} channel${total === 1 ? "" : "s"}`
    }
  }

  show(channels) {
    this.resultsTarget.hidden = false
    this.resultsTarget.innerHTML = ""
    if (channels.length === 0) {
      this.resultsTarget.append(span("pick-none", "No channel matches"))
      return
    }

    for (const channel of channels) {
      const row = document.createElement("button")
      row.type = "button"
      row.className = "pick-opt"
      row.dataset.action = "click->channel-picker#choose mouseenter->channel-picker#hover"
      row.dataset.id = channel.id
      row.dataset.name = channel.name
      row.append(
        span("pick-name", `#${channel.name}`),
        span("pick-id mono", channel.id)
      )
      this.resultsTarget.append(row)
    }
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
    const { id, name } = event.currentTarget.dataset
    this.take(id, name)
  }

  take(id, name) {
    this.picked = { id, name }
    this.inputTarget.value = ""
    this.render()
    this.clearResults()
    const flip = this.element.querySelector(".modal-flip")
    if (flip) {
      flip.checked = false
      flip.dispatchEvent(new Event("change", { bubbles: true }))
    }
    if (this.submitValue) this.element.closest("form")?.requestSubmit()
  }

  drop() {
    this.picked = null
    this.inputTarget.value = ""
    this.render()
    this.inputTarget.focus()
  }

  render() {
    this.storeTarget.innerHTML = ""
    this.chosenTarget.innerHTML = ""
    if (!this.picked) {
      this.inputTarget.placeholder = this.blank
      return
    }

    const shown = document.createElement("span")
    shown.className = "token token-plain"
    const label = document.createElement("span")
    label.textContent = `#${this.picked.name}`
    shown.append(label)

    const remove = document.createElement("button")
    remove.type = "button"
    remove.className = "token-x"
    remove.dataset.action = "click->channel-picker#drop"
    remove.setAttribute("aria-label", `remove #${this.picked.name}`)
    remove.textContent = "×"
    shown.append(remove)

    this.chosenTarget.append(shown)
    this.inputTarget.placeholder = ""

    const field = document.createElement("input")
    field.type = "hidden"
    field.name = this.nameValue
    field.value = this.picked.id
    this.storeTarget.append(field)
  }

  keys(event) {
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault()
      return this.move(event.key === "ArrowDown" ? 1 : -1)
    }
    if (event.key === "Enter") {
      const row = this.rows()[this.at < 0 ? 0 : this.at]
      if (row) {
        event.preventDefault()
        this.take(row.dataset.id, row.dataset.name)
      }
      return
    }
    if (event.key === "Escape") this.clearResults()
  }

  clearResults() {
    this.resultsTarget.innerHTML = ""
    this.resultsTarget.hidden = true
    this.at = -1
  }
}
