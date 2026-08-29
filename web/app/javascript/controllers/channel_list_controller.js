import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input", "rows", "moreWrap"]
  static values = { url: String, sort: String, direction: String, view: String, filters: Array }

  connect() {
    this.page = 0
    this.timer = null
  }

  search() {
    clearTimeout(this.timer)
    this.timer = setTimeout(() => {
      this.page = 0
      this.fetchPage(true)
    }, 200)
  }

  loadMore() {
    this.page += 1
    this.fetchPage(false)
  }

  async fetchPage(replace) {
    const params = new URLSearchParams({
      q: this.inputTarget.value.trim(),
      sort: this.sortValue,
      direction: this.directionValue,
      view: this.viewValue,
      page: this.page
    })
    this.filtersValue.forEach((f) => params.append("f[]", f))
    const resp = await fetch(`${this.urlValue}?${params}`, {
      headers: { "X-Requested-With": "channel-list", Accept: "text/html" }
    })
    const html = await resp.text()
    if (replace) {
      this.rowsTarget.innerHTML = html
    } else {
      this.rowsTarget.insertAdjacentHTML("beforeend", html)
    }
    const hasMore = resp.headers.get("X-Has-More") === "true"
    this.moreWrapTarget.classList.toggle("hidden", !hasMore)
  }
}
