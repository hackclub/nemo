import { Controller } from "@hotwired/stimulus"

const GAP = 2
const CLAMP = 100
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

function clip(text, size, room) {
  if (room <= 0) return null
  if (fit(text, size) <= room) return text

  for (let n = text.length - 1; n >= 2; n--) {
    const cut = `${text.slice(0, n)}…`
    if (fit(cut, size) <= room) return cut
  }
  return null
}

const esc = (s) =>
  String(s).replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;")

const N = (v) => v == null ? "n/a" : Number(v).toLocaleString("en-US")
const PC = (v, d = 1) => v == null ? "n/a" : `${Number(v).toFixed(d)}%`
const signed = (v) => `${v >= 0 ? "+" : ""}${Number(v).toFixed(0)}%`

function squarify(items, x, y, w, h, out) {
  if (!items.length) return out
  if (items.length === 1) {
    out.push({ ...items[0], x, y, w, h })
    return out
  }

  const total = items.reduce((at, i) => at + i.v, 0)
  let take = 1
  let bestRatio = Infinity
  for (let n = 1; n <= items.length; n++) {
    const part = items.slice(0, n).reduce((at, i) => at + i.v, 0)
    const frac = part / total
    const rw = w >= h ? w * frac : w
    const rh = w >= h ? h : h * frac
    const worst = items.slice(0, n).reduce((mx, i) => {
      const share = i.v / part
      const iw = w >= h ? rw : rw * share
      const ih = w >= h ? rh * share : rh
      return Math.max(mx, Math.max(iw / ih, ih / iw))
    }, 0)
    if (worst < bestRatio) {
      bestRatio = worst
      take = n
    } else break
  }

  const head = items.slice(0, take)
  const tail = items.slice(take)
  const part = head.reduce((at, i) => at + i.v, 0)
  const frac = part / total

  if (w >= h) {
    const rw = w * frac
    let cy = y
    head.forEach((i) => {
      const ih = h * (i.v / part)
      out.push({ ...i, x, y: cy, w: rw, h: ih })
      cy += ih
    })
    return squarify(tail, x + rw, y, w - rw, h, out)
  }

  const rh = h * frac
  let cx = x
  head.forEach((i) => {
    const iw = w * (i.v / part)
    out.push({ ...i, x: cx, y, w: iw, h: rh })
    cx += iw
  })
  return squarify(tail, x, y + rh, w, h - rh, out)
}

export default class extends Controller {
  static values = { tiles: Array, height: Number, total: Number, floor: Number }

  connect() {
    this.at = null
    this.element.innerHTML = `<div class="tree" tabindex="0"
      data-action="mousemove->treemap#track mouseleave->treemap#clear keydown->treemap#key"
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
    return this.hasHeightValue && this.heightValue > 0 ? this.heightValue : 400
  }

  measure() {
    const box = this.element.querySelector(".tree")
    const wide = box ? box.clientWidth : 0
    if (!wide || wide === this.wide) return

    this.wide = wide
    this.draw(box, wide)
  }

  step(row) {
    if (row.thin || row.pct == null) return "na"

    const v = Math.max(-CLAMP, Math.min(CLAMP, row.pct))
    if (v <= -45) return "d3"
    if (v <= -18) return "d2"
    if (v <= -4) return "d1"
    if (v < 4) return "z"
    if (v < 18) return "u1"
    if (v < 45) return "u2"
    return "u3"
  }

  draw(box, wide) {
    const rows = this.tilesValue
    if (!rows.length) return

    const high = this.high
    const laid = squarify(rows.map((r) => ({ ...r, v: r.messages })), 0, 0, wide, high, [])

    let cells = ""
    this.zones = []

    laid.forEach((r, i) => {
      const w = Math.max(0, r.w - GAP)
      const h = Math.max(0, r.h - GAP)
      if (!(w > 1 && h > 1)) return

      const tone = this.step(r)
      const x = r.x + GAP / 2
      const y = r.y + GAP / 2

      let text = ""
      const label = `#${r.name}`
      const value = r.thin || r.pct == null ? "new" : signed(r.pct)
      const cx = x + w / 2

      // both lines always; shrink toward the floor until the pair fits the tile
      let nameSize = Math.max(8, Math.min(20, Math.round(Math.min(w, h) / 3.4)))
      let valSize = Math.max(8, Math.round(nameSize * 0.82))
      while (nameSize > 8 && nameSize + valSize + 4 > h - 6) {
        nameSize -= 1
        valSize = Math.max(8, Math.round(nameSize * 0.82))
      }

      const pair = nameSize + valSize + 4
      const first = y + h / 2 - pair / 2 + nameSize
      const room = w - 8
      const shownName = clip(label, nameSize, room)
      const shownValue = clip(value, valSize, room)

      if (shownName) {
        text += `<text class="t-n" x="${cx.toFixed(1)}" y="${first.toFixed(1)}"
          text-anchor="middle" font-size="${nameSize}">${esc(shownName)}</text>`
      }
      if (shownValue) {
        text += `<text class="t-v" x="${cx.toFixed(1)}" y="${
          (first + valSize + 4).toFixed(1)}" text-anchor="middle"
          font-size="${valSize}">${esc(shownValue)}</text>`
      }

      cells += `<g class="cell ${tone}" data-i="${i}"><rect class="${tone}"
        x="${x.toFixed(1)}" y="${y.toFixed(1)}"
        width="${w.toFixed(1)}" height="${h.toFixed(1)}"/>${text}</g>`

      this.zones.push({ i, cx: r.x + r.w / 2, cy: r.y + r.h / 2, row: r, tone,
        x0: r.x, y0: r.y, x1: r.x + r.w, y1: r.y + r.h })
    })

    box.querySelector("svg")?.remove()
    box.insertAdjacentHTML("afterbegin",
      `<svg width="${wide}" height="${high}" viewBox="0 0 ${wide} ${high}" role="img"
        aria-label="${esc(this.summary(rows))}">${cells}</svg>`)

    this.geom = { wide, high }
    if (this.at != null) this.show(Math.min(this.at, this.zones.length - 1))
  }

  summary(rows) {
    const named = rows
    const top = named[0]
    const total = this.hasTotalValue ? this.totalValue : 0
    const bits = [`Treemap of ${rows.length} tiles, area is member messages, colour is change against the previous window`]
    if (top && total) {
      bits.push(`largest ${top.name} at ${N(top.messages)} messages, ${
        PC(top.messages / total * 100)} of ${N(total)}`)
    }
    const grew = named.filter((r) => r.pct != null && r.pct > 0).length
    const shrank = named.filter((r) => r.pct != null && r.pct < 0).length
    bits.push(`${grew} grew, ${shrank} shrank`)
    return bits.join(", ")
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
    this.at = i

    const floor = this.hasFloorValue ? this.floorValue : 0
    const total = this.hasTotalValue ? this.totalValue : 0
    const swatch = (t) => `<i style="background: var(--dv-${t})"></i>`
    const rows = [
      `<div class="row">${swatch(zone.tone)}member messages<b>${N(r.messages)}</b></div>`
    ]
    if (r.prior != null) {
      rows.push(`<div class="row">${swatch("na")}window before<b>${N(r.prior)}</b></div>`)
    }
    if (r.pct != null && !r.thin) {
      rows.push(`<div class="row">${swatch(zone.tone)}change<b>${signed(r.pct)}</b></div>`)
    } else {
      rows.push(`<div class="row">${swatch("na")}change<b>n/a</b></div>`)
      rows.push(`<div class="row row-note"><i></i>base under ${N(floor)} messages</div>`)
    }
    if (total) {
      rows.push(`<div class="row"><i></i>share of all channels<b>${
        PC(r.messages / total * 100, 2)}</b></div>`)
    }

    const tip = box.querySelector(".tip")
    tip.innerHTML = `<div class="t">#${esc(r.name)}</div>${rows.join("")}`
    tip.classList.add("on")

    const tipWide = tip.offsetWidth || 190
    const tipHigh = tip.offsetHeight || 90
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

    box.querySelector(".chart-say").textContent = `${r.name}, ${N(r.messages)} messages${
      r.pct != null && !r.thin ? `, ${signed(r.pct)}` : ""}`
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
