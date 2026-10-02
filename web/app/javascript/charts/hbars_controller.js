import { Controller } from "@hotwired/stimulus"

const GUTTER_MAX = 0.42
const ROW = 26
const PAD = { t: 8, r: 52, b: 22 }
const MIN_BAR = 2

const RULER = typeof document === "undefined"
  ? null
  : document.createElement("canvas").getContext("2d")

function wideAs(text, size) {
  if (!RULER) return String(text).length * size * 0.6

  RULER.font = `${size}px "Geist Mono", ui-monospace, monospace`
  return RULER.measureText(String(text)).width
}

function clip(text, size, room) {
  if (room <= 0) return ""
  if (wideAs(text, size) <= room) return text

  for (let n = text.length - 1; n >= 2; n--) {
    const cut = `${text.slice(0, n)}…`
    if (wideAs(cut, size) <= room) return cut
  }
  return ""
}

const esc = (s) =>
  String(s).replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;")

const F = (n) => (n == null ? "n/a" : Number(n).toLocaleString("en-US"))

const axl = (v) =>
  Math.abs(v) >= 1000 ? `${+(v / 1000).toFixed(v % 1000 ? 1 : 0)}k` : `${Math.round(v)}`

export default class extends Controller {
  static values = { rows: Array, said: String, tone: String }

  connect() {
    this.at = null
    this.element.innerHTML = `<div class="hbars tipped" tabindex="0"
      data-action="mousemove->hbars#track mouseleave->hbars#clear keydown->hbars#key"
      ><div class="tip"></div><span class="chart-say" aria-live="polite"></span></div>`
    const box = this.element.querySelector(".hbars")
    this.watcher = new ResizeObserver(() => this.measure())
    this.watcher.observe(box)
    this.wide = 0
    this.measure()
  }

  disconnect() {
    this.watcher?.disconnect()
  }

  get rows() {
    return this.rowsValue || []
  }

  get said() {
    return this.hasSaidValue && this.saidValue ? this.saidValue : "rows"
  }

  measure() {
    const box = this.element.querySelector(".hbars")
    const wide = box ? box.clientWidth : 0
    if (!wide || wide === this.wide) return

    this.wide = wide
    this.draw(box, wide)
  }

  draw(box, wide) {
    const rows = this.rows
    if (!rows.length) return

    const high = PAD.t + rows.length * ROW + PAD.b
    const room = wide * GUTTER_MAX
    const gutter = Math.min(room,
      rows.reduce((mx, r) => Math.max(mx, wideAs(r.label, 10)), 0) + 12)
    const x0 = Math.round(gutter)
    const x1 = wide - PAD.r
    const max = Math.max(...rows.map((r) => Number(r.value) || 0), 1)
    const span = x1 - x0

    const ticks = [0, 0.5, 1].map((f) => {
      const at = x0 + f * span
      return `<line class="${f === 0 ? "base" : "grid"}" x1="${at.toFixed(1)}" y1="${PAD.t}"
        x2="${at.toFixed(1)}" y2="${high - PAD.b}"/>` +
        `<text class="ax" x="${at.toFixed(1)}" y="${high - PAD.b + 14}" text-anchor="middle">${
          axl(max * f)}</text>`
    }).join("")

    this.zones = []
    const bars = rows.map((r, i) => {
      const y = PAD.t + i * ROW
      const v = Number(r.value) || 0
      const full = (v / max) * span
      const w = v > 0 ? Math.max(full, MIN_BAR) : 0
      const name = clip(r.label, 10, x0 - 10)
      const tone = r.tone ? ` ${r.tone}` : ""

      const mark = v > 0
        ? `<rect class="bar${tone}" x="${x0.toFixed(1)}" y="${(y + 5).toFixed(1)}"
            width="${w.toFixed(1)}" height="${ROW - 13}" rx="3"/>`
        : `<rect class="zero" x="${x0.toFixed(1)}" y="${(y + 5).toFixed(1)}"
            width="2" height="${ROW - 13}" rx="1"/>`

      this.zones.push({ i, row: r, y0: y, y1: y + ROW })

      return `<g class="hrow" data-i="${i}">${mark}` +
        `<text class="ax" x="${(x0 - 8).toFixed(1)}" y="${(y + ROW / 2 + 3.4).toFixed(1)}"
          text-anchor="end">${esc(name)}</text>` +
        `<text class="val" x="${(x1 + 6).toFixed(1)}" y="${(y + ROW / 2 + 3.4).toFixed(1)}">${
          F(v)}</text></g>`
    }).join("")

    box.querySelector("svg")?.remove()
    box.insertAdjacentHTML("afterbegin",
      `<svg width="${wide}" height="${high}" viewBox="0 0 ${wide} ${high}" role="img"
        aria-label="${esc(this.summary(rows))}">${ticks}${bars}</svg>`)

    this.geom = { wide, high, x0, x1 }
    if (this.at != null) this.show(Math.min(this.at, rows.length - 1))
  }

  summary(rows) {
    const total = rows.reduce((at, r) => at + (Number(r.value) || 0), 0)
    return [`${this.said}, ${rows.length} rows, ${F(total)} in all`]
      .concat(rows.map((r) => `${r.label} ${F(r.value)}`)).join(". ")
  }

  track(event) {
    if (!this.zones) return

    const box = this.element.querySelector(".hbars").getBoundingClientRect()
    const my = (event.clientY - box.top) / box.height * this.geom.high
    const hit = this.zones.findIndex((z) => my >= z.y0 && my <= z.y1)
    if (hit < 0) return this.clear()

    this.show(hit)
  }

  key(event) {
    if (!this.zones) return

    const last = this.zones.length - 1
    const step = { ArrowDown: 1, ArrowRight: 1, ArrowUp: -1, ArrowLeft: -1 }[event.key]
    let next = this.at

    if (step) {
      next = this.at == null ? (step > 0 ? 0 : last) : Math.min(last, Math.max(0, this.at + step))
    } else if (event.key === "Home") next = 0
    else if (event.key === "End") next = last
    else if (event.key === "Escape") return this.clear()
    else return

    event.preventDefault()
    this.show(next)
  }

  show(i) {
    const zone = this.zones[i]
    if (!zone) return

    const box = this.element.querySelector(".hbars")
    const r = zone.row
    this.at = i

    const tip = box.querySelector(".tip")
    tip.innerHTML = `<div class="t">${esc(r.label)}</div>` +
      `<div class="row"><i></i>${esc(this.said)}<b>${F(r.value)}</b></div>` +
      (r.note ? `<div class="row"><i></i>share<b>${esc(r.note)}</b></div>` : "")
    tip.classList.add("on")

    const scale = box.clientWidth / this.geom.wide
    const tipHigh = tip.offsetHeight || 60
    const tipWide = tip.offsetWidth || 170
    tip.style.left = `${Math.max(0, Math.min(this.geom.x0 * scale + 12,
      box.clientWidth - tipWide))}px`
    tip.style.top = `${Math.max(0, Math.min((zone.y0 + ROW / 2) * scale - tipHigh / 2,
      box.clientHeight - tipHigh))}px`

    box.classList.add("lit")
    box.querySelectorAll(".hrow").forEach((row) =>
      row.classList.toggle("on", +row.dataset.i === i))
    box.querySelector(".chart-say").textContent = `${r.label}, ${F(r.value)}`
  }

  clear() {
    const box = this.element.querySelector(".hbars")
    if (!box) return

    this.at = null
    box.querySelector(".tip")?.classList.remove("on")
    box.classList.remove("lit")
    box.querySelectorAll(".hrow").forEach((row) => row.classList.remove("on"))
    const say = box.querySelector(".chart-say")
    if (say) say.textContent = ""
  }
}
