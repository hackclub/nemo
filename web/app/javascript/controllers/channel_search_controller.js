import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input", "row"]

  connect() {
    this.filter()
  }

  filter() {
    const q = this.inputTarget.value.trim().toLowerCase()
    const matched = []
    this.rowTargets.forEach((row, i) => {
      const name = row.dataset.name
      let rank
      if (q === "") rank = 0
      else if (name === q) rank = 0
      else if (name.startsWith(q)) rank = 1
      else if (name.includes(q)) rank = 2
      else rank = -1
      row.style.display = rank === -1 ? "none" : ""
      if (rank !== -1) matched.push({ row, rank, i })
    })
    matched
      .sort((a, b) => a.rank - b.rank || a.i - b.i)
      .forEach(({ row }) => row.parentNode.appendChild(row))
  }
}
