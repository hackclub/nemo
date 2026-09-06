import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["query", "row", "empty", "list"]
  static values = { wait: { type: Number, default: 400 }, min: { type: Number, default: 2 }, url: String }

  connect() {
    this.onKey = (event) => {
      if (event.key !== "/" || event.metaKey || event.ctrlKey || event.altKey) return
      if (event.target.matches("input, textarea, select, [contenteditable='true']")) return

      event.preventDefault()
      this.queryTarget.focus()
    }
    document.addEventListener("keydown", this.onKey)
  }

  disconnect() {
    document.removeEventListener("keydown", this.onKey)
    clearTimeout(this.timer)
    this.request?.abort()
  }

  filter() {
    const term = this.queryTarget.value.trim().toLocaleLowerCase()
    let shown = 0

    this.rowTargets.forEach((row) => {
      const matches = !term || row.textContent.toLocaleLowerCase().includes(term)
      row.hidden = !matches
      if (matches) shown += 1
    })

    if (this.hasEmptyTarget) this.emptyTarget.hidden = shown > 0

    clearTimeout(this.timer)
    if (!this.hasUrlValue) return
    if (shown === 0 && term.length >= this.minValue) {
      this.timer = setTimeout(() => this.search(term), this.waitValue)
    } else if (!term && this.replaced) {
      this.timer = setTimeout(() => this.search(""), this.waitValue)
    }
  }

  async search(term) {
    this.request?.abort()
    this.request = new AbortController()
    const params = new URLSearchParams(new FormData(this.queryTarget.form))
    params.set("q", term)

    let html
    try {
      const response = await fetch(`${this.urlValue}?${params}`, {
        headers: { Accept: "text/html" }, signal: this.request.signal,
      })
      if (!response.ok) return
      html = await response.text()
    } catch {
      return
    }
    if (this.queryTarget.value.trim().toLocaleLowerCase() !== term) return

    this.replace(html)
    this.replaced = term.length > 0
  }

  replace(html) {
    const holder = document.createElement("div")
    holder.innerHTML = html
    const next = holder.querySelector("template[data-more-next]")
    next?.remove()

    let listbox = this.listTarget.querySelector("#member-listbox")
    if (!listbox) {
      this.listTarget.querySelectorAll(".empty:not(.pane-filter-empty)").forEach((el) => el.remove())
      listbox = document.createElement("div")
      listbox.id = "member-listbox"
      listbox.setAttribute("role", "listbox")
      listbox.setAttribute("aria-label", "Members")
      this.listTarget.prepend(listbox)
    }
    listbox.replaceChildren(...holder.children)

    this.listTarget.querySelector(".pane-more")?.remove()
    if (next) {
      const more = document.createElement("div")
      more.className = "pane-more"
      more.setAttribute("aria-hidden", "true")
      more.dataset.controller = "more"
      more.dataset.moreIntoValue = "member-listbox"
      more.dataset.moreUrlValue = next.dataset.moreNext
      more.innerHTML = '<i class="dot run"></i>'
      listbox.after(more)
    }

    if (this.hasEmptyTarget) this.emptyTarget.hidden = this.rowTargets.length > 0
  }
}
