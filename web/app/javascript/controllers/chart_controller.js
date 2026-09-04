import { Controller } from "@hotwired/stimulus"
import { scaleBand, scaleLinear } from "d3-scale"
import { line as lineOf, area as areaOf, curveMonotoneX } from "d3-shape"

let seq = 0

const INK = [1, 2, 3, 4, 5, 0]

const PAD = { l: 46, r: 8, t: 12, b: 28 }

const BAR_CAP = 72
const BAR_R = 3
const LABEL_ROOM = 64

const F = (n) => (n == null ? "n/a" : Number(n).toLocaleString("en-US"))

const axl = (v) =>
  Math.abs(v) >= 1000 ? `${+(v / 1000).toFixed(v % 1000 ? 1 : 0)}k` : `${Math.round(v)}`

const esc = (s) =>
  String(s).replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;")

const clamp = (v, lo, hi) => Math.min(Math.max(v, lo), hi)

function topBar(x, y, w, h, r) {
  if (!(h > 0) || !(w > 0)) return ""

  const k = Math.min(r, w / 2, h)
  return `M${x},${y + h}V${y + k}a${k},${k} 0 0 1 ${k},${-k}h${w - 2 * k}a${k},${k} 0 0 1 ${k},${k}V${y + h}Z`
}

export default class extends Controller {
  static values = { kind: String, data: Object, height: Number, pct: Boolean, switchable: Boolean }

  connect() {
    this.gid = `cg${++seq}`
    this.shown = this.kindValue || "bars"
    this.at = null
    this.wide = 0
    this.build()

    const chart = this.element.querySelector(".chart")
    if (!chart) return

    this.watcher = new ResizeObserver(() => this.measure())
    this.watcher.observe(chart)
  }

  disconnect() {
    this.watcher?.disconnect()
  }

  get rows() {
    const { labels = [], datasets = [] } = this.dataValue
    return labels.map((label, i) => {
      const row = { label: Array.isArray(label) ? label[0] : label }
      datasets.forEach((set, s) => { row[`s${s}`] = set.data[i] })
      return row
    })
  }

  get series() {
    return (this.dataValue.datasets || []).map((set, i) => ({
      k: `s${i}`, n: set.label, ink: INK[i % INK.length], own: set.color
    }))
  }

  get height() {
    return this.hasHeightValue && this.heightValue > 0 ? this.heightValue : 214
  }

  get line() {
    return this.shown === "line"
  }

  build() {
    const series = this.series
    if (!this.rows.length || !series.length) return

    this.element.innerHTML = `${this.head(series)}<div class="chart" tabindex="0"
      data-action="mousemove->chart#track mouseleave->chart#clear keydown->chart#key"
      ><div class="tip"></div><span class="chart-say" aria-live="polite"></span></div>`
    this.wide = 0
    this.measure()
  }

  measure() {
    const chart = this.element.querySelector(".chart")
    const wide = chart ? chart.clientWidth : 0
    if (!wide || wide === this.wide) return

    this.wide = wide
    this.draw(chart, wide)
  }

  head(series) {
    const swatch = (s) =>
      `<span><i class="${this.paint(s)}"${this.tint(s)}></i>${esc(s.n)}</span>`
    const legend = series.length > 1
      ? `<div class="chart-legend">${series.map(swatch).join("")}</div>`
      : ""
    if (!this.switchableValue) return legend

    const pick = (kind, label) =>
      `<button type="button" data-kind="${kind}" data-action="click->chart#pick"
        aria-pressed="${this.shown === kind}">${label}</button>`

    return `<div class="chart-head">${legend}<span class="segmented chart-pick">${
      pick("bars", "Bar")}${pick("line", "Line")}</span></div>`
  }

  paint(s) {
    return `ser-${s.ink}`
  }

  tint(s) {
    return s.own ? ` style="color:${esc(s.own)}"` : ""
  }

  tick(v) {
    return this.pctValue ? `${Math.round(v)}%` : axl(v)
  }

  said(v) {
    if (v == null) return "n/a"
    return this.pctValue ? `${Number(v).toFixed(1)}%` : F(v)
  }

  scales(rows, series, wide) {
    const high = this.height
    const line = this.line

    const x = scaleBand()
      .domain(rows.map((_, i) => i))
      .range([PAD.l, wide - PAD.r])
      .padding(line ? 0 : 0.26)

    const seen = rows.flatMap((r) => series.map((s) => r[s.k])).filter((v) => v != null)
    let lo = 0
    let hi = seen.length ? Math.max(...seen) : 0

    if (this.pctValue) {
      lo = 0
      hi = 100
    } else if (line && seen.length) {
      const least = Math.min(...seen)
      if (least > 0 && hi > 0 && (hi - least) / hi < 0.6) lo = least
    }
    if (hi <= lo) hi = lo + 1

    const y = scaleLinear().domain([lo, hi]).range([high - PAD.b, PAD.t])
    if (!this.pctValue) y.nice(4)

    return { x, y, lo: y.domain()[0], line, high }
  }

  shownLabels(rows, wide) {
    const room = Math.max(2, Math.floor((wide - PAD.l - PAD.r) / LABEL_ROOM))
    const every = Math.max(1, Math.ceil(rows.length / room))
    const last = rows.length - 1
    if (every === 1) return new Set(rows.map((_, i) => i))

    const show = new Set()
    for (let i = 0; i <= last; i += every) show.add(i)
    const top = Math.max(...show)
    if (last - top < Math.ceil(every / 2)) show.delete(top)
    show.add(last)
    return show
  }

  draw(chart, wide) {
    const rows = this.rows
    const series = this.series
    const { x, y, lo, line, high } = this.scales(rows, series, wide)
    const mid = (i) => x(i) + x.bandwidth() / 2
    const ticks = this.pctValue ? [0, 50, 100] : y.ticks(high < 160 ? 3 : 4)
    const right = wide - PAD.r
    const floor = y(lo)

    const grid = ticks.map((v) => {
      const at = y(v).toFixed(1)
      return `<line class="grid" x1="${PAD.l}" y1="${at}" x2="${right}" y2="${at}"/>` +
        `<text class="ax" x="${PAD.l - 8}" y="${(y(v) + 3.5).toFixed(1)}" text-anchor="end">${
          this.tick(v)}</text>`
    }).join("")

    const shown = this.shownLabels(rows, wide)
    const names = rows.map((r, i) => shown.has(i)
      ? `<text class="ax" x="${mid(i).toFixed(1)}" y="${high - PAD.b + 16}" text-anchor="middle">${
        esc(r.label)}</text>`
      : "").join("")

    const body = line
      ? this.drawLine(rows, series, { x, y, mid, lo, floor })
      : this.drawBars(rows, series, { x, y, floor })

    const defs = line && series.length === 1 && lo === 0
      ? `<linearGradient id="${this.gid}" class="${this.paint(series[0])}"${this.tint(series[0])} x1="0" y1="0" x2="0" y2="1">
          <stop class="top" offset="0"/><stop class="bot" offset="1"/></linearGradient>`
      : ""

    const cursor = line
      ? `<line class="cur" x1="0" y1="${PAD.t}" x2="0" y2="${floor}" opacity="0"/>` +
        series.map((s) => `<circle class="dot ${this.paint(s)}"${this.tint(s)} data-s="${s.k}" r="4.5"
          fill="currentColor" opacity="0"/>`).join("")
      : ""

    chart.querySelector("svg")?.remove()
    chart.insertAdjacentHTML("afterbegin",
      `<svg width="${wide}" height="${high}" viewBox="0 0 ${wide} ${high}" role="img"
        aria-label="${esc(this.summary(rows, series))}"><defs>${defs}</defs>${grid}` +
      `<line class="base" x1="${PAD.l}" y1="${floor}" x2="${right}" y2="${floor}"/>` +
      `${body}${cursor}${names}</svg>`)

    this.geom = {
      x, y, mid, lo, line, wide, high, rows, series, floor,
      tops: rows.map((r) => Math.min(...series.map((s) => r[s.k] == null ? high : y(r[s.k]))))
    }
    if (this.at != null) this.show(clamp(this.at, 0, rows.length - 1))
  }

  drawBars(rows, series, { x, y, floor }) {
    const sub = scaleBand()
      .domain(series.map((s) => s.k))
      .range([0, x.bandwidth()])
      .padding(series.length > 1 ? 0.16 : 0)

    return rows.map((r, i) => {
      const bars = series.map((s) => {
        const v = r[s.k]
        if (v == null) return ""

        let wide = sub.bandwidth()
        let at = x(i) + sub(s.k)
        if (wide > BAR_CAP) {
          at += (wide - BAR_CAP) / 2
          wide = BAR_CAP
        }
        const top = y(v)
        return `<path class="${this.paint(s)}"${this.tint(s)} fill="currentColor" d="${
          topBar(at, top, wide, floor - top, BAR_R)}"/>`
      }).join("")

      return `<g class="mark" data-i="${i}">${bars}</g>`
    }).join("")
  }

  drawLine(rows, series, { mid, y, lo, floor }) {
    const pts = (s) => rows.map((r, i) => ({ i, v: r[s.k] }))
    const path = lineOf().defined((d) => d.v != null).x((d) => mid(d.i)).y((d) => y(d.v))
      .curve(curveMonotoneX)
    const under = areaOf().defined((d) => d.v != null).x((d) => mid(d.i)).y0(floor)
      .y1((d) => y(d.v)).curve(curveMonotoneX)
    const wash = series.length === 1 && lo === 0

    return series.map((s) => {
      const seen = pts(s)
      const fill = wash ? `<path class="wash" fill="url(#${this.gid})" d="${under(seen)}"/>` : ""
      return `${fill}<path class="${this.paint(s)}"${this.tint(s)} fill="none" stroke="currentColor"
        stroke-width="2" stroke-linejoin="round" stroke-linecap="round" d="${path(seen)}"/>`
    }).join("")
  }

  summary(rows, series) {
    const title = this.element.closest(".card")?.querySelector(".card-title")?.textContent?.trim()
    const what = series.map((s) => s.n).join(" and ")
    const shape = this.line ? "line chart" : "bar chart"
    return `${title || what} ${shape}, ${rows.length} points, ${rows[0].label} to ${
      rows[rows.length - 1].label}`
  }

  pick(event) {
    const button = event.target.closest("[data-kind]")
    if (!button || button.dataset.kind === this.shown) return

    this.shown = button.dataset.kind
    this.element.querySelectorAll(".chart-pick [data-kind]").forEach((one) =>
      one.setAttribute("aria-pressed", String(one.dataset.kind === this.shown)))

    this.clear()
    this.wide = 0
    this.measure()
  }

  track(event) {
    const g = this.geom
    if (!g) return

    const box = this.element.querySelector(".chart").getBoundingClientRect()
    const mx = event.clientX - box.left
    const my = event.clientY - box.top
    if (mx < PAD.l || mx > g.wide - PAD.r || my > g.high - PAD.b) return this.clear()

    const i = clamp(Math.floor((mx - PAD.l) / g.x.step()), 0, g.rows.length - 1)
    this.show(i)
  }

  key(event) {
    const g = this.geom
    if (!g) return

    const last = g.rows.length - 1
    const step = { ArrowRight: 1, ArrowLeft: -1 }[event.key]
    let next = this.at

    if (step) next = this.at == null ? (step > 0 ? 0 : last) : clamp(this.at + step, 0, last)
    else if (event.key === "Home") next = 0
    else if (event.key === "End") next = last
    else if (event.key === "Escape") return this.clear()
    else return

    event.preventDefault()
    this.show(next)
  }

  show(i) {
    const g = this.geom
    const chart = this.element.querySelector(".chart")
    const row = g.rows[i]
    this.at = i

    const lines = g.series.map((s) => row[s.k] == null ? "" :
      `<div class="row"><i class="${this.paint(s)}"${this.tint(s)}></i>${esc(s.n)}<b>${
        this.said(row[s.k])}</b></div>`).join("")

    const tip = chart.querySelector(".tip")
    tip.innerHTML = `<div class="t">${esc(row.label)}</div>${lines}`
    tip.classList.add("on")

    const at = g.mid(i)
    const tipWide = tip.offsetWidth || 190
    const bandL = g.line ? at : g.x(i)
    const bandR = g.line ? at : g.x(i) + g.x.bandwidth()

    let left = bandR + 12
    if (left + tipWide > g.wide) left = bandL - 12 - tipWide
    if (left < 0) left = clamp(at - tipWide / 2, 0, Math.max(0, g.wide - tipWide))

    tip.style.left = `${left}px`
    tip.style.top = `${PAD.t}px`

    chart.querySelectorAll(".mark").forEach((mark) =>
      mark.classList.toggle("fade", +mark.dataset.i !== i))

    const cur = chart.querySelector(".cur")
    if (cur) {
      cur.setAttribute("x1", at)
      cur.setAttribute("x2", at)
      cur.setAttribute("opacity", "0.6")
      chart.querySelectorAll(".dot").forEach((dot) => {
        const v = row[dot.dataset.s]
        if (v == null) return dot.setAttribute("opacity", "0")

        dot.setAttribute("cx", at)
        dot.setAttribute("cy", g.y(v))
        dot.setAttribute("opacity", "1")
      })
    }

    chart.querySelector(".chart-say").textContent = `${row.label}, ${
      g.series.map((s) => `${s.n} ${this.said(row[s.k])}`).join(", ")}`
  }

  clear() {
    const chart = this.element.querySelector(".chart")
    if (!chart) return

    this.at = null
    chart.querySelector(".tip")?.classList.remove("on")
    chart.querySelector(".cur")?.setAttribute("opacity", "0")
    chart.querySelectorAll(".dot").forEach((dot) => dot.setAttribute("opacity", "0"))
    chart.querySelectorAll(".mark").forEach((mark) => mark.classList.remove("fade"))
    const say = chart.querySelector(".chart-say")
    if (say) say.textContent = ""
  }
}
