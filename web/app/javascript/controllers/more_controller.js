import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { url: String, into: String }

  connect() {
    this.loading = false
    this.watcher = new IntersectionObserver((entries) => {
      if (entries.some((entry) => entry.isIntersecting)) this.load()
    }, { root: this.element.closest(".pane-list"), rootMargin: "320px 0px" })
    this.watcher.observe(this.element)
  }

  disconnect() {
    this.watcher?.disconnect()
  }

  async load() {
    if (this.loading || !this.urlValue) return
    this.loading = true

    try {
      const response = await fetch(this.urlValue, { headers: { Accept: "text/html" } })
      if (!response.ok) throw new Error(response.status)

      const holder = document.createElement("div")
      holder.innerHTML = await response.text()
      const next = holder.querySelector("template[data-more-next]")
      next?.remove()

      const into = document.getElementById(this.intoValue)
      if (into) into.append(...holder.children)

      if (next) {
        this.urlValue = next.dataset.moreNext
        this.loading = false
        this.watcher.unobserve(this.element)
        this.watcher.observe(this.element)
      } else {
        this.element.remove()
      }
    } catch {
      this.loading = false
    }
  }
}
