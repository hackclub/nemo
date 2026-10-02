import { Controller } from "@hotwired/stimulus"
import { scaleLinear, scaleSqrt } from "d3-scale"

const PAD = { l: 48, r: 16, t: 16, b: 42 }
const DOT = [4, 15]
const CORNERS = ["tl", "tr", "bl", "br"]

const esc = (s) =>
  String(s).replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;")

const F = (n) => (n == null ? "n/a" : Number(n).toLocaleString("en-US"))

const axl = (v) =>
  Math.abs(v) >= 1000 ? `${+(v / 1000).toFixed(v % 1000 ? 1 : 0)}k` : `${Math.round(v)}`

export default class extends Controller {
  static values = {
    points: Array, height: Number,
    xLabel: String, yLabel: String, nLabel: String,
    yPct: Boolean,
    xMid: Number, yMid: Number, xMidLabel: String, yMidLabel: String,
    corners: Object
  }

  connect() {
    this.at = null
    this.element.innerHTML = `<div class="chart tipped" tabindex="0"
      data-action="mousemove->scatter#track mouseleave->scatter#clear keydown->scatter#key"
      ><div class="tip"></div><span class="chart-say" aria-live="polite"></span></div>`
    const chart = this.element.querySelector(".chart")
    this.watcher = new ResizeObserver(() => this.measure())
    this.watcher.observe(chart)
    this.wide = 0
    this.measure()
  }

  disconnect() {
    this.watcher?.disconnect()
  }

  get high() {
    return this.hasHeightValue && this.heightValue > 0 ? this.heightValue : 268
  }

  measure() {
    const chart = this.element.querySelector(".chart")
    const wide = chart ? chart.clientWidth : 0
    if (!wide || wide === this.wide) return

    this.wide = wide
    this.draw(chart, wide)
  }

  span(values, mid, share = 0.08) {
    const seen = values.filter((v) => v != null).map(Number)
    if (!seen.length) return [0, 1]

    let lo = Math.min(...seen)
    let hi = Math.max(...seen)
    if (mid != null) {
      lo = Math.min(lo, mid)
      hi = Math.max(hi, mid)
    }
    if (hi === lo) {
      hi += 1
      lo -= 1
    }
    const room = (hi - lo) * share
    return [lo < 0 ? lo - room : Math.max(0, lo - room), hi + room]
  }

  yTick(v) {
    return this.yPctValue ? `${Math.round(v)}%` : axl(v)
  }

  said(v, pct) {
    if (v == null) return "n/a"
    return pct ? `${Number(v).toFixed(1)}%` : F(v)
  }

  draw(chart, wide) {
    const pts = this.pointsValue
    if (!pts.length) return

    const high = this.high
    const xMid = this.hasXMidValue ? this.xMidValue : null
    const yMid = this.hasYMidValue ? this.yMidValue : null

    const x = scaleLinear().domain(this.span(pts.map((p) => p.x), xMid))
      .range([PAD.l, wide - PAD.r])
    const y = scaleLinear().domain(this.span(pts.map((p) => p.y), yMid, 0.16))
      .range([high - PAD.b, PAD.t])
    const r = scaleSqrt().domain([0, Math.max(1, ...pts.map((p) => Number(p.n) || 0))])
      .range(DOT)

    const grid = y.ticks(4).map((v) =>
      `<line class="grid" x1="${PAD.l}" y1="${y(v).toFixed(1)}" x2="${
        wide - PAD.r}" y2="${y(v).toFixed(1)}"/>` +
      `<text class="ax" x="${PAD.l - 7}" y="${(y(v) + 3.5).toFixed(1)}" text-anchor="end">${
        this.yTick(v)}</text>`).join("")

    const rungs = x.ticks(Math.max(2, Math.floor((wide - PAD.l - PAD.r) / 76))).map((v) =>
      `<text class="ax" x="${x(v).toFixed(1)}" y="${high - PAD.b + 16}" text-anchor="middle">${
        axl(v)}</text>`).join("")

    const cuts = [
      xMid == null ? "" : `<line class="mark-rule" x1="${x(xMid).toFixed(1)}" y1="${
        PAD.t}" x2="${x(xMid).toFixed(1)}" y2="${(high - PAD.b).toFixed(1)}"/>`,
      yMid == null ? "" : `<line class="mark-rule" x1="${PAD.l}" y1="${
        y(yMid).toFixed(1)}" x2="${wide - PAD.r}" y2="${y(yMid).toFixed(1)}"/>`
    ].join("")

    const said = this.hasCornersValue ? this.cornersValue : {}
    const corners = CORNERS.map((at) => {
      const label = said[at]
      if (!label) return ""

      const left = at[1] === "l"
      const top = at[0] === "t"
      return `<text class="ax quad-say" x="${
        (left ? PAD.l + 6 : wide - PAD.r - 6).toFixed(1)}" y="${
        (top ? PAD.t + 11 : high - PAD.b - 6).toFixed(1)}" text-anchor="${
        left ? "start" : "end"}">${esc(label)}</text>`
    }).join("")

    const dots = pts.map((p, i) =>
      `<circle class="spot ser-${p.ink == null ? 1 : p.ink}" data-i="${i}" cx="${
        x(p.x).toFixed(1)}" cy="${y(p.y).toFixed(1)}" r="${
        r(Number(p.n) || 0).toFixed(1)}"/>`).join("")

    const caption = this.xLabelValue
      ? `<text class="ax cap-say" x="${((PAD.l + wide - PAD.r) / 2).toFixed(1)}" y="${
        high - 6}" text-anchor="middle">${esc(this.xLabelValue)}</text>`
      : ""

    const stood = this.yLabelValue
      ? `<text class="ax cap-say" transform="translate(11,${
        ((PAD.t + high - PAD.b) / 2).toFixed(1)}) rotate(-90)" text-anchor="middle">${
        esc(this.yLabelValue)}</text>`
      : ""

    chart.querySelector("svg")?.remove()
    chart.insertAdjacentHTML("afterbegin",
      `<svg width="${wide}" height="${high}" viewBox="0 0 ${wide} ${high}" role="img"
        aria-label="${esc(this.summary())}">${grid}${cuts}${corners}` +
      `<line class="base" x1="${PAD.l}" y1="${(high - PAD.b).toFixed(1)}" x2="${
        wide - PAD.r}" y2="${(high - PAD.b).toFixed(1)}"/>` +
      `${dots}${rungs}${caption}${stood}</svg>`)

    this.geom = { x, y, r, wide, high }
    if (this.at != null) this.show(this.at)
  }

  summary() {
    const pts = this.pointsValue
    const best = pts.reduce((at, p) => (p.y > at.y ? p : at), pts[0])
    const worst = pts.reduce((at, p) => (p.y < at.y ? p : at), pts[0])
    return `${pts.length} channels by ${this.xLabelValue || "x"} against ${
      this.yLabelValue || "y"}, from ${worst.name} at ${
      this.said(worst.y, this.yPctValue)} to ${best.name} at ${this.said(best.y, this.yPctValue)}`
  }

  track(event) {
    const g = this.geom
    if (!g) return

    const box = this.element.querySelector(".chart").getBoundingClientRect()
    const mx = event.clientX - box.left
    const my = event.clientY - box.top
    const pts = this.pointsValue

    let best = null
    let near = Infinity
    pts.forEach((p, i) => {
      const dx = g.x(p.x) - mx
      const dy = g.y(p.y) - my
      const gap = Math.sqrt(dx * dx + dy * dy) - g.r(Number(p.n) || 0)
      if (gap < near) {
        near = gap
        best = i
      }
    })
    if (best == null || near > 26) return this.clear()

    this.show(best)
  }

  key(event) {
    const pts = this.pointsValue
    const last = pts.length - 1
    const step = { ArrowRight: 1, ArrowLeft: -1 }[event.key]
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
    const g = this.geom
    const chart = this.element.querySelector(".chart")
    const p = this.pointsValue[i]
    if (!g || !p) return

    this.at = i
    chart.querySelectorAll(".spot").forEach((dot) =>
      dot.classList.toggle("lit", Number(dot.dataset.i) === i))

    const rows = [
      [this.xLabelValue, this.said(p.x, false), p.ink],
      [this.yLabelValue, this.said(p.y, this.yPctValue), p.ink],
      [this.nLabelValue, F(p.n), 0]
    ].filter(([label]) => label)

    const tip = chart.querySelector(".tip")
    tip.innerHTML = `<div class="t">#${esc(p.name)}${
      p.phase ? ` <span class="t-say">${esc(p.phase)}</span>` : ""}</div>` +
      rows.map(([label, value, ink]) =>
        `<div class="row"><i class="ser-${ink == null ? 1 : ink}"></i>${
          esc(label)}<b>${value}</b></div>`).join("")
    tip.classList.add("on")

    const tipWide = tip.offsetWidth || 190
    let left = g.x(p.x) + 16
    if (left + tipWide > g.wide) left = g.x(p.x) - 16 - tipWide
    tip.style.left = `${Math.max(0, left)}px`
    tip.style.top = `${Math.max(PAD.t, Math.min(g.y(p.y) - 12, g.high - 110))}px`

    chart.querySelector(".chart-say").textContent =
      `${p.name}, ${this.xLabelValue} ${this.said(p.x, false)}, ${
        this.yLabelValue} ${this.said(p.y, this.yPctValue)}`
  }

  clear() {
    const chart = this.element.querySelector(".chart")
    if (!chart) return

    this.at = null
    chart.querySelectorAll(".spot.lit").forEach((dot) => dot.classList.remove("lit"))
    chart.querySelector(".tip")?.classList.remove("on")
    const say = chart.querySelector(".chart-say")
    if (say) say.textContent = ""
  }
}
