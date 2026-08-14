import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["host", "input", "results", "scope"]
  static values = { url: String }

  static kinds = {
    member: "members", members: "members",
    case: "cases", cases: "cases",
    decision: "decisions", decisions: "decisions",
    note: "notes", notes: "notes",
    report: "reports", reports: "reports",
  }

  connect() {
    this.timer = null
    this.rows = []
    this.at = 0
    this.scope = null
  }

  disconnect() {
    clearTimeout(this.timer)
  }

  key(event) {
    if (event.key === "k" && (event.metaKey || event.ctrlKey)) {
      event.preventDefault()
      return this.open()
    }
    if (this.hostTarget.hidden) return

    if (event.key === "Escape") return this.close()
    if (event.key === "ArrowDown") return this.move(event, 1)
    if (event.key === "ArrowUp") return this.move(event, -1)
    if (event.key === "Enter") return this.go(event)
    if (event.key === "Tab") return this.scoping(event)
    if (event.key === "Backspace") return this.unscope(event)
  }

  scoping(event) {
    const word = this.inputTarget.value.trim().split(/\s+/)[0] ?? ""
    const kind = this.constructor.kinds[word.toLowerCase()]
    if (!kind) return

    event.preventDefault()
    this.scope = word.toLowerCase().replace(/s$/, "")
    this.scopeTarget.textContent = kind
    this.scopeTarget.hidden = false
    this.inputTarget.value = this.inputTarget.value.trim().slice(word.length).trim()
    this.look()
  }

  unscope(event) {
    if (!this.scope || this.inputTarget.value.length > 0) return

    event.preventDefault()
    this.scope = null
    this.scopeTarget.hidden = true
    this.look()
  }

  open() {
    this.hostTarget.hidden = false
    this.inputTarget.focus()
    this.inputTarget.select()
    this.look()
  }

  close() {
    this.hostTarget.hidden = true
    this.inputTarget.blur()
  }

  type() {
    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.look(), 120)
  }

  async look() {
    const term = this.inputTarget.value.trim()
    const asked = new URLSearchParams({ q: term })
    if (this.scope) asked.set("scope", this.scope)

    const response = await fetch(`${this.urlValue}?${asked}`, {
      headers: { Accept: "application/json" },
    })
    if (!response.ok) return

    const { groups } = await response.json()
    this.draw(groups, term)
  }

  draw(groups, term) {
    this.resultsTarget.innerHTML = ""
    this.rows = []
    this.at = 0

    for (const group of groups) {
      const head = document.createElement("div")
      head.className = "palette-group"
      head.textContent = group.label
      if (group.total > group.rows.length) {
        const more = document.createElement("span")
        more.className = "more"
        more.textContent = `${group.rows.length} of ${group.total}`
        head.append(more)
      }
      this.resultsTarget.append(head)

      for (const row of group.rows) {
        this.resultsTarget.append(this.line(row, term))
      }
    }

    if (this.rows.length === 0 && term.length > 0) {
      const none = document.createElement("div")
      none.className = "palette-group"
      none.textContent = "Nothing found"
      this.resultsTarget.append(none)
    }

    this.mark()
  }

  line(row, term) {
    const line = document.createElement("a")
    line.className = "palette-row"
    line.href = row.url
    line.dataset.action = "mouseenter->palette#hover"
    line.dataset.at = this.rows.length

    const icon = document.createElement("span")
    icon.textContent = row.icon

    const what = document.createElement("span")
    const title = document.createElement("b")
    title.textContent = row.title
    what.append(title)

    if (row.sub) {
      const sub = document.createElement("span")
      sub.className = "sub"
      sub.textContent = ` ${row.sub}`
      what.append(sub)
    }

    if (row.said) {
      const said = document.createElement("span")
      said.className = "line2"
      said.append(...this.lit(row.said, term))
      what.append(said)
    }

    line.append(icon, what, document.createElement("span"))
    this.rows.push(line)
    return line
  }

  lit(text, term) {
    const word = term.split(/\s+/)[0]
    const at = word ? text.toLowerCase().indexOf(word.toLowerCase()) : -1
    if (at < 0) return [document.createTextNode(text)]

    const hit = document.createElement("span")
    hit.className = "hl"
    hit.textContent = text.slice(at, at + word.length)
    return [
      document.createTextNode(text.slice(0, at)),
      hit,
      document.createTextNode(text.slice(at + word.length)),
    ]
  }

  hover(event) {
    this.at = Number(event.currentTarget.dataset.at)
    this.mark()
  }

  move(event, step) {
    event.preventDefault()
    if (this.rows.length === 0) return

    this.at = (this.at + step + this.rows.length) % this.rows.length
    this.mark()
  }

  mark() {
    this.rows.forEach((row, index) => row.classList.toggle("sel", index === this.at))
    this.rows[this.at]?.scrollIntoView({ block: "nearest" })
  }

  go(event) {
    const row = this.rows[this.at]
    if (!row) return

    event.preventDefault()
    this.close()
    window.location = row.href
  }
}
