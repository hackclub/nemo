import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["host", "input", "results", "scope"]
  static values = { url: String, on: String }

  static kinds = {
    member: "members", members: "members",
    case: "cases", cases: "cases",
    note: "notes", notes: "notes",
    report: "reports", reports: "reports",
  }

  connect() {
    this.timer = null
    this.rows = []
    this.at = 0
    this.only = null
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
    this.only = word.toLowerCase().replace(/s$/, "")
    this.scopeTarget.textContent = kind
    this.scopeTarget.hidden = false
    this.inputTarget.value = this.inputTarget.value.trim().slice(word.length).trim()
    this.look()
  }

  unscope(event) {
    if (!this.only || this.inputTarget.value.length > 0) return

    event.preventDefault()
    this.only = null
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
    if (this.only) asked.set("scope", this.only)
    if (this.hasOnValue && this.onValue) {
      const [, id] = this.onValue.split(":")
      asked.set("on_case", id)
    }

    let payload
    try {
      const response = await fetch(`${this.urlValue}?${asked}`, {
        headers: { Accept: "application/json" },
      })
      if (!response.ok) throw new Error(response.status)
      payload = await response.json()
    } catch {
      return this.failed()
    }

    this.adopt(payload.scope)
    this.draw(payload.groups, term)
  }

  failed() {
    this.resultsTarget.innerHTML = ""
    this.rows = []
    this.at = 0
    const row = document.createElement("div")
    row.className = "palette-group"
    row.textContent = "Search did not answer. Type again to retry."
    this.resultsTarget.append(row)
  }

  adopt(scope) {
    if (!scope || scope === this.only || scope === "command") return

    const marks = { "@": "member", "#": "case", "n:": "note", "r:": "report" }
    const typed = this.inputTarget.value.toLowerCase()
    const mark = Object.keys(marks).find((one) => typed.startsWith(one) && marks[one] === scope)
    if (!mark) return

    this.only = scope
    this.scopeTarget.textContent = `${scope}s`
    this.scopeTarget.hidden = false
    this.inputTarget.value = this.inputTarget.value.slice(mark.length).trim()
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

    const held = groups.reduce((sum, group) => sum + group.rows.length, 0)
    const all = groups.reduce((sum, group) => sum + group.total, 0)
    if (term.length > 0 && all > held) {
      this.resultsTarget.append(this.line({
        icon: "arrow", title: `See all ${all}`, sub: null, said: null,
        url: `/fd/search?q=${encodeURIComponent(term)}${this.only ? `&scope=${this.only}` : ""}`,
      }, term))
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
    line.className = row.why ? "palette-row off" : "palette-row"
    if (!row.why) line.href = row.url
    line.dataset.action = "mouseenter->palette#hover"
    line.dataset.at = this.rows.length

    const icon = document.createElement("span")
    icon.className = "palette-icon"
    if (row.kind === "member" && row.id) {
      const img = document.createElement("img")
      img.className = "avatar"
      img.src = `https://cachet.hackclub.com/users/${encodeURIComponent(row.id)}/r`
      img.alt = ""
      img.dataset.cachetFace = row.id
      img.dataset.cachetInitial = row.initial || "?"
      icon.append(img)
    } else {
      icon.innerHTML = this.icon(row.icon)
    }

    const what = document.createElement("span")
    what.className = "pal-what"
    const title = document.createElement("b")
    title.className = "pal-t"
    title.textContent = row.title
    if (row.kind === "member" && row.id && row.title === `@${row.id}`) title.dataset.cachetName = row.id
    what.append(title)

    if (row.why || row.sub) {
      const sub = document.createElement("span")
      sub.className = "sub"
      sub.textContent = row.why || row.sub
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
    this.rows.forEach((row, index) => {
      row.setAttribute("aria-selected", index === this.at ? "true" : "false")
    })
    this.rows[this.at]?.scrollIntoView({ block: "nearest" })
  }

  icon(name) {
    const paths = {
      person: '<circle cx="9" cy="8" r="3"/><path d="M3.5 19a5.5 5.5 0 0 1 11 0M16 8h5M18.5 5.5v5"/>',
      case: '<path d="M12 3 4 6v6c0 4 3.4 7.4 8 8 4.6-.6 8-4 8-8V6z"/>',
      note: '<path d="M5 4h14v12H8l-3 3z"/>',
      report: '<path d="M4 5h16v14H4zM4 7l8 6 8-6"/>',
      plus: '<path d="M12 5v14M5 12h14"/>',
      resolve: '<circle cx="12" cy="12" r="9"/><path d="m8.2 12.2 2.6 2.6 5-5.4"/>',
      action: '<path d="M20 14a8 8 0 1 0-16 0M15 10l-3.4 3.4"/>',
      thread: '<path d="M4 6h16M4 11h10M4 16h13"/>',
      waiting: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
      arrow: '<path d="M5 12h14m-5-5 5 5-5 5"/>'
    }
    const body = paths[name] || '<circle cx="12" cy="12" r="3"/>'
    return `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${body}</svg>`
  }

  go(event) {
    const row = this.rows[this.at]
    if (!row) return

    event.preventDefault()
    if (!row.href) return

    this.close()
    window.location = row.href
  }
}
