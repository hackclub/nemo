import { Controller } from "@hotwired/stimulus"

const clamp = (v, lo, hi) => Math.min(Math.max(v, lo), hi)

const esc = (s) =>
  String(s).replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;")

export default class extends Controller {
  static targets = ["mark"]

  connect() {
    this.element.classList.add("tipped")
    this.tip = document.createElement("div")
    this.tip.className = "tip"
    this.element.appendChild(this.tip)
  }

  disconnect() {
    this.tip?.remove()
  }

  show(event) {
    const mark = event.target.closest("[data-tip]")
    if (!mark) return this.clear()

    let said
    try {
      said = JSON.parse(mark.dataset.tip)
    } catch {
      return this.clear()
    }

    const rows = (said.rows || []).map((r) =>
      `<div class="row"><i${r.tone ? ` style="background:${esc(r.tone)}"` : ""}></i>${
        esc(r.label)}<b>${esc(r.value)}${
        r.of == null ? "" : ` <u>${esc(r.of)}</u>`}</b></div>`).join("")
    const note = said.note ? `<div class="row row-note"><i></i>${esc(said.note)}</div>` : ""

    this.tip.innerHTML = `<div class="t">${esc(said.title)}</div>${rows}${note}`
    this.tip.classList.add("on")
    this.place(mark)
  }

  place(mark) {
    const host = this.element.getBoundingClientRect()
    const at = mark.getBoundingClientRect()
    const wide = this.tip.offsetWidth || 190
    const high = this.tip.offsetHeight || 60

    let left = at.left - host.left + at.width + 12
    if (left + wide > host.width) left = at.left - host.left - wide - 12
    this.tip.style.left = `${clamp(left, 0, Math.max(0, host.width - wide))}px`
    this.tip.style.top = `${clamp(at.top - host.top + at.height / 2 - high / 2, 0,
      Math.max(0, host.height - high))}px`
  }

  clear() {
    this.tip?.classList.remove("on")
  }
}
