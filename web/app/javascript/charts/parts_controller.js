import { Controller } from "@hotwired/stimulus"
import { squarify } from "charts/squarify"

const GAP = 2
const RULER = typeof document === "undefined"
  ? null
  : document.createElement("canvas").getContext("2d")

const SANS = '"Inter Tight", ui-sans-serif, system-ui, sans-serif'
const MONO = '"Geist Mono", ui-monospace, monospace'

function fit(text, size, mono) {
  if (!RULER) return text.length * size * 0.6

  RULER.font = `${mono ? 500 : 600} ${size}px ${mono ? MONO : SANS}`
  return RULER.measureText(text).width
}

function clip(text, size, room, mono) {
  if (room <= 0) return null
  if (fit(text, size, mono) <= room) return text

  for (let n = text.length - 1; n >= 2; n--) {
    const cut = `${text.slice(0, n)}…`
    if (fit(cut, size, mono) <= room) return cut
  }
  return null
}

const esc = (s) =>
  String(s).replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;")

const N = (v) => v == null ? "n/a" : Number(v).toLocaleString("en-US")
const PC = (v, d = 1) => v == null ? "n/a" : `${Number(v).toFixed(d)}%`

export default class extends Controller {
  static values = { tiles: Array, height: Number, said: String }

  connect() {
    this.at = null
    this.element.innerHTML = `<div class="tree parts tipped" tabindex="0"
      data-action="mousemove->parts#track mouseleave->parts#clear keydown->parts#key"
      ><div class="tip"></div><span class="chart-say" aria-live="polite"></span></div>`
    const box = this.element.querySelector(".tree")
    this.watcher = new ResizeObserver(() => this.measure())
    this.watcher.observe(box)
    this.wide = 0
    this.measure()
  }

  disconnect() {
    this.watcher?.disconnect()
  }

  get high() {
    return this.hasHeightValue && this.heightValue > 0 ? this.heightValue : 200
  }

  get parts() {
    return this.tilesValue
      .filter((t) => Number(t.value) > 0)
      .slice()
      .sort((a, b) => b.value - a.value)
  }

  get total() {
    return this.tilesValue.reduce((at, t) => at + Number(t.value || 0), 0)
  }

  measure() {
    const box = this.element.querySelector(".tree")
    const wide = box ? box.clientWidth : 0
    if (!wide || wide === this.wide) return

    this.wide = wide
    this.draw(box, wide)
  }

  draw(box, wide) {
    const rows = this.parts
    if (!rows.length) return

    const high = this.high
    const total = this.total
    const laid = squarify(rows.map((r) => ({ ...r, v: Number(r.value) })), 0, 0, wide, high, [])

    let cells = ""
    this.zones = []

    laid.forEach((r, i) => {
      const w = Math.max(0, r.w - GAP)
      const h = Math.max(0, r.h - GAP)
      if (!(w > 1 && h > 1)) return

      const x = r.x + GAP / 2
      const y = r.y + GAP / 2
      const share = PC(r.v / total * 100)
      const room = w - 10
      const cx = x + w / 2

      let pcSize = Math.max(10, Math.min(16, Math.round(Math.min(w / 4.2, h / 3.6))))
      while (pcSize > 10 && fit(share, pcSize, true) > room) pcSize -= 1
      const shownPc = clip(share, pcSize, room, true)

      let nameSize = Math.max(9, Math.round(pcSize * 0.9))
      while (nameSize > 9 && fit(r.label, nameSize) > room) nameSize -= 1
      let shownName = clip(r.label, nameSize, room)
      const pair = nameSize + pcSize + 4
      if (pair > h - 8) shownName = null

      let text = ""
      if (shownName && shownPc) {
        const first = y + h / 2 - pair / 2 + nameSize
        text += `<text class="t-n" x="${cx.toFixed(1)}" y="${first.toFixed(1)}"
          text-anchor="middle" font-size="${nameSize}"
          style="fill: var(--parts-ink)">${esc(shownName)}</text>`
        text += `<text class="t-v" x="${cx.toFixed(1)}" y="${
          (first + pcSize + 4).toFixed(1)}" text-anchor="middle" font-size="${pcSize}"
          style="fill: var(--parts-ink)">${esc(shownPc)}</text>`
      } else if (shownPc) {
        text += `<text class="t-v" x="${cx.toFixed(1)}" y="${
          (y + h / 2 + pcSize / 3).toFixed(1)}" text-anchor="middle" font-size="${pcSize}"
          style="fill: var(--parts-ink)">${esc(shownPc)}</text>`
      }

      const tone = `part-${r.tone == null ? i : r.tone}`
      cells += `<g class="cell" data-i="${i}"><rect class="${tone}"
        x="${x.toFixed(1)}" y="${y.toFixed(1)}"
        width="${w.toFixed(1)}" height="${h.toFixed(1)}"/>${text}</g>`

      this.zones.push({ i, row: r, tone, share,
        cx: r.x + r.w / 2, cy: r.y + r.h / 2,
        x0: r.x, y0: r.y, x1: r.x + r.w, y1: r.y + r.h })
    })

    box.querySelector("svg")?.remove()
    box.insertAdjacentHTML("afterbegin",
      `<svg width="${wide}" height="${high}" viewBox="0 0 ${wide} ${high}" role="img"
        aria-label="${esc(this.summary(rows, total))}">${cells}</svg>`)

    this.geom = { wide, high }
    if (this.at != null) this.show(Math.min(this.at, this.zones.length - 1))
  }

  summary(rows, total) {
    const said = this.hasSaidValue && this.saidValue ? this.saidValue : "parts of the whole"
    const bits = [`Treemap of ${said}, area is each part's share of ${N(total)}`]
    rows.forEach((r) => {
      bits.push(`${r.label} ${N(r.value)}, ${PC(r.value / total * 100)}`)
    })
    return bits.join(". ")
  }

  track(event) {
    if (!this.zones) return

    const box = this.element.querySelector(".tree").getBoundingClientRect()
    const mx = (event.clientX - box.left) / box.width * this.geom.wide
    const my = (event.clientY - box.top) / box.height * this.geom.high
    const hit = this.zones.findIndex((z) =>
      mx >= z.x0 && mx <= z.x1 && my >= z.y0 && my <= z.y1)
    if (hit < 0) return this.clear()

    this.show(hit)
  }

  key(event) {
    if (!this.zones) return

    const last = this.zones.length - 1
    const step = { ArrowRight: 1, ArrowDown: 1, ArrowLeft: -1, ArrowUp: -1 }[event.key]
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

    const box = this.element.querySelector(".tree")
    const r = zone.row
    const total = this.total
    this.at = i

    const tip = box.querySelector(".tip")
    tip.innerHTML = `<div class="t">${esc(r.label)}</div>` +
      `<div class="row"><i class="${zone.tone}"></i>members<b>${N(r.value)}</b></div>` +
      `<div class="row"><i></i>share<b>${zone.share}</b></div>` +
      `<div class="row"><i></i>of<b>${N(total)}</b></div>`
    tip.classList.add("on")

    const tipWide = tip.offsetWidth || 186
    const tipHigh = tip.offsetHeight || 84
    const scale = box.clientWidth / this.geom.wide
    let left = zone.x1 * scale + 10
    if (left + tipWide > box.clientWidth) left = zone.x0 * scale - 10 - tipWide
    if (left < 0) left = Math.max(0, Math.min(zone.cx * scale - tipWide / 2,
      box.clientWidth - tipWide))
    let top = zone.cy * scale - tipHigh / 2
    top = Math.max(0, Math.min(top, box.clientHeight - tipHigh))

    tip.style.left = `${left}px`
    tip.style.top = `${top}px`

    box.classList.add("lit")
    box.querySelectorAll(".cell").forEach((cell) =>
      cell.classList.toggle("on", +cell.dataset.i === i))
    box.querySelector(".chart-say").textContent =
      `${r.label}, ${N(r.value)}, ${zone.share}`
  }

  clear() {
    const box = this.element.querySelector(".tree")
    if (!box) return

    this.at = null
    box.querySelector(".tip")?.classList.remove("on")
    box.classList.remove("lit")
    box.querySelectorAll(".cell").forEach((cell) => cell.classList.remove("on"))
    const say = box.querySelector(".chart-say")
    if (say) say.textContent = ""
  }
}
